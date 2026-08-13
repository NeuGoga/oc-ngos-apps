-- mplayer.tape -- Computronics tape drive wrapper.
--
-- Facts this module is built on, taken from the mod source rather than the
-- wiki (TileTapeDrive.java, TapeDriveState.java, TapeStorage.java):
--
--   * A tape is a flat byte array. The drive holds one position; read(),
--     write() and seek() all move it.
--   * seek(n) is RELATIVE and clamped to [0, size-1]; it returns how far it
--     actually moved. seekTo() below builds an absolute seek out of that.
--   * Playback emits one packet of `packetSize` bytes every 250 ms, where
--     packetSize = round(1024 * speed). At speed 1.0 that is exactly
--     4096 bytes per second of audio (32768 Hz, 1 bit per sample DFPWM).
--   * TapeStorage.write clamps to size - position - 1, so the very last byte
--     of a tape is never usable. Capacity below accounts for it.
--   * The drive has no pause. stop() keeps the position, so stop-then-play
--     resumes exactly where it left off -- that is our pause.
--
-- Track layout: audio is packed from byte 0 upwards, and the last
-- INDEX_SIZE bytes hold a plain-text table of contents. Keeping the index at
-- the end rather than the front means a manual play() never plays it as a
-- burst of noise.

local component = require("component")

local tape = {}

local Tape = {}
Tape.__index = Tape

-- Bytes of audio consumed per second at speed 1.0.
local BYTES_PER_SECOND = 4096
tape.BYTES_PER_SECOND = BYTES_PER_SECOND

-- The drive declares its sample rate as packetSize * 8 * 4, where packetSize
-- is round(1024 * speed) -- so the rate is not fixed, it scales with speed.
-- At 1.0 that is 32768 Hz; at the maximum 2.0 it is 65536 Hz.
--
-- Which means a track encoded at 65536 Hz and played back at speed 2.0 comes
-- out at the right pitch with twice the sample rate. On a one-bit format that
-- is the single largest quality gain available. It costs twice the tape, so
-- it is per track: each one records the rate it was encoded at.
local NATIVE_RATE = 32768
tape.NATIVE_RATE = NATIVE_RATE
tape.RATES = { 32768, 65536 }

local INDEX_SIZE = 2048
-- MPTAPE2 adds a per-track sample rate. MPTAPE1 tapes still read fine; they
-- simply have no rate field and are assumed native.
local INDEX_MAGIC = "MPTAPE2"
local LEGACY_MAGIC = "MPTAPE1"

tape.INDEX_SIZE = INDEX_SIZE

--- Is a tape drive attached?
function tape.available()
  return component.isAvailable("tape_drive")
end

--- Bind to a tape drive. `address` is optional.
function tape.new(address)
  if not component.isAvailable("tape_drive") then
    return nil, "no Computronics tape drive found"
  end
  local drive = address and component.proxy(address) or component.tape_drive

  local self = setmetatable({
    drive = drive,
    speed = 1.0,
    volume = 1.0,
    tracks = {},
    playing = nil, -- index into tracks
  }, Tape)

  self:refresh()
  return self
end

-- Basic state ------------------------------------------------------------

--- Re-read tape presence, size and the track index. Call after a tape swap.
function Tape:refresh()
  self.ready = self.drive.isReady()
  if not self.ready then
    self.size, self.tracks, self.label = 0, {}, nil
    return false
  end
  self.size = self.drive.getSize()
  self.label = self.drive.getLabel()
  self:readIndex()
  return true
end

--- Total bytes usable for audio (everything before the index block).
function Tape:capacity()
  if not self.ready then return 0 end
  return math.max(0, self.size - INDEX_SIZE - 1)
end

--- First free byte, i.e. where the next track will be written.
function Tape:used()
  local top = 0
  for _, t in ipairs(self.tracks) do
    local endsAt = t.start + t.length
    if endsAt > top then top = endsAt end
  end
  return top
end

function Tape:free()
  return math.max(0, self:capacity() - self:used())
end

--- Seconds of audio a byte count represents.
-- A track plays at the speed its rate demands, so its own rate decides how
-- fast bytes are consumed: one bit per sample, hence rate/8 bytes a second.
function Tape:bytesToSeconds(bytes, rate)
  return bytes / ((rate or NATIVE_RATE) / 8)
end

function Tape:secondsToBytes(seconds, rate)
  return math.floor(seconds * ((rate or NATIVE_RATE) / 8))
end

--- The drive speed a track needs for correct pitch.
function Tape:speedFor(rate)
  return (rate or NATIVE_RATE) / NATIVE_RATE
end

--- Absolute seek, built from the drive's relative seek.
function Tape:seekTo(position)
  local target = math.max(0, math.min(math.floor(position), self.size - 1))
  for _ = 1, 8 do
    local current = self.drive.getPosition()
    if current == target then return target end
    local moved = self.drive.seek(target - current)
    if moved == 0 then break end
  end
  return self.drive.getPosition()
end

function Tape:position()
  return self.drive.getPosition()
end

function Tape:state()
  return self.drive.getState()
end

--- Drive speed. Callers normally go through playTrack, which derives it from
--- the track's rate; `pitch` is the user's own multiplier on top.
function Tape:setSpeed(speed)
  speed = math.max(0.25, math.min(2.0, speed))
  if self.drive.setSpeed(speed) then
    self.speed = speed
  end
  return self.speed
end

function Tape:setVolume(volume)
  self.volume = math.max(0, math.min(1, volume))
  self.drive.setVolume(self.volume)
  return self.volume
end

-- Track index ------------------------------------------------------------
--
-- Text, newline separated, zero padded to INDEX_SIZE:
--
--   MPTAPE2
--   <count>
--   <start> <length> <rate> <title>
--   ...

function Tape:indexOffset()
  return self.size - INDEX_SIZE
end

--- Read the table of contents from the tape. Missing or foreign index is
--- treated as an empty tape rather than an error.
function Tape:readIndex()
  self.tracks = {}
  if not self.ready or self.size <= INDEX_SIZE then return self.tracks end

  local wasPlaying = self:state() == "PLAYING"
  if wasPlaying then self.drive.stop() end

  self:seekTo(self:indexOffset())
  local raw = self.drive.read(INDEX_SIZE)
  if not raw then return self.tracks end

  -- Trim the zero padding. (%z was removed in Lua 5.2; embed the byte.)
  local text = raw:gsub("\0+$", "")
  local lines = {}
  for line in text:gmatch("[^\n]+") do lines[#lines + 1] = line end

  local legacy = lines[1] == LEGACY_MAGIC
  if lines[1] ~= INDEX_MAGIC and not legacy then return self.tracks end

  local count = tonumber(lines[2]) or 0
  for i = 1, count do
    local line = lines[2 + i]
    if line then
      -- v1: "start length title"   v2: "start length rate title"
      local start, length, rate, title
      if legacy then
        start, length, title = line:match("^(%d+)%s+(%d+)%s*(.*)$")
        rate = NATIVE_RATE
      else
        start, length, rate, title = line:match("^(%d+)%s+(%d+)%s+(%d+)%s*(.*)$")
        rate = tonumber(rate) or NATIVE_RATE
      end
      if start then
        start, length = tonumber(start), tonumber(length)
        -- Only rates the drive can actually play are trusted. A bad value
        -- here would set the speed to something absurd -- 10240 asks for
        -- 0.3125x, which clamps to the drive's 0.25 minimum and turns music
        -- into a slurred mess -- so anything unrecognised falls back.
        if rate ~= 32768 and rate ~= 65536 then rate = NATIVE_RATE end
        local rest = title
        if start + length <= self:capacity() + 1 then
          self.tracks[#self.tracks + 1] = {
            start = start,
            length = length,
            rate = rate,
            title = (rest ~= "" and rest) or ("Track " .. i),
            duration = self:bytesToSeconds(length, rate),
          }
        end
      end
    end
  end
  return self.tracks
end

--- The index exactly as it sits on the tape, for diagnostics.
function Tape:rawIndex()
  if not self.ready or self.size <= INDEX_SIZE then return nil end
  if self:state() == "PLAYING" then self.drive.stop() end
  self:seekTo(self:indexOffset())
  local raw = self.drive.read(INDEX_SIZE)
  if not raw then return nil end
  return (raw:gsub("\0+$", ""))
end

--- Persist the table of contents back onto the tape.
function Tape:writeIndex()
  if not self.ready or self.size <= INDEX_SIZE then
    return nil, "no tape, or tape too small for an index"
  end

  local parts = { INDEX_MAGIC, tostring(#self.tracks) }
  for _, t in ipairs(self.tracks) do
    -- Titles must stay on one line and must not upset the parser.
    local title = t.title:gsub("[\n\r]", " "):sub(1, 64)
    parts[#parts + 1] = ("%d %d %d %s"):format(
      math.floor(t.start), math.floor(t.length),
      math.floor(t.rate or NATIVE_RATE), title)
  end

  local text = table.concat(parts, "\n") .. "\n"
  if #text > INDEX_SIZE then
    return nil, "too many tracks to fit in the tape index"
  end
  text = text .. string.rep("\0", INDEX_SIZE - #text)

  if self:state() == "PLAYING" then self.drive.stop() end
  self:seekTo(self:indexOffset())
  self.drive.write(text)
  return true
end

--- Append a track record. The audio must already have been written.
function Tape:addTrack(title, start, length, rate)
  rate = rate or NATIVE_RATE
  self.tracks[#self.tracks + 1] = {
    start = start,
    length = length,
    rate = rate,
    title = title,
    duration = self:bytesToSeconds(length, rate),
  }
  return self:writeIndex() and #self.tracks
end

--- Forget a track. The bytes stay on the tape; only the last track's space is
--- actually reclaimed, since tracks are packed in order.
function Tape:removeTrack(i)
  if not self.tracks[i] then return false end
  if self.playing == i then self:stop() end
  table.remove(self.tracks, i)
  if self.playing and self.playing > i then self.playing = self.playing - 1 end
  return self:writeIndex()
end

--- Drop every track. Audio bytes are left alone; they get overwritten as new
--- tracks are recorded.
function Tape:wipeIndex()
  self:stop()
  self.tracks = {}
  return self:writeIndex()
end

-- Playback ---------------------------------------------------------------

--- Start (or restart) a track from its beginning.
function Tape:playTrack(i)
  local track = self.tracks[i]
  if not track then return nil, "no such track" end
  self.drive.stop()
  -- A high rate track is only in tune at the speed it was encoded for.
  self:setSpeed(self:speedFor(track.rate) * (self.pitch or 1))
  self:seekTo(track.start)
  self.playing = i
  if not self.drive.play() then
    self.playing = nil
    return nil, "the drive refused to play (no tape?)"
  end
  return true
end

--- Resume from wherever the head currently sits.
function Tape:resume()
  if not self.playing then return false end
  return self.drive.play()
end

function Tape:pause()
  self.drive.stop()
end

function Tape:stop()
  self.drive.stop()
  self.playing = nil
end

--- Seconds elapsed within the current track.
function Tape:trackPosition()
  local track = self.tracks[self.playing or 0]
  if not track then return 0 end
  local offset = self:position() - track.start
  if offset < 0 then offset = 0 end
  if offset > track.length then offset = track.length end
  return self:bytesToSeconds(offset, track.rate)
end

--- Jump to a point inside the current track, given in seconds.
function Tape:seekWithinTrack(seconds)
  local track = self.tracks[self.playing or 0]
  if not track then return false end
  local offset = math.max(0, math.min(self:secondsToBytes(seconds, track.rate), track.length))
  local wasPlaying = self:state() == "PLAYING"
  if wasPlaying then self.drive.stop() end
  self:seekTo(track.start + offset)
  if wasPlaying then self.drive.play() end
  return true
end

--- Poll playback. Returns "playing", "finished" or "stopped".
-- The drive stops itself at the physical end of the tape; we additionally
-- stop at the end of the current track so the next one does not bleed in.
function Tape:update()
  if not self.playing then return "stopped" end
  local track = self.tracks[self.playing]
  if not track then
    self.playing = nil
    return "stopped"
  end

  local pos = self:position()
  if pos >= track.start + track.length then
    self.drive.stop()
    return "finished"
  end

  if self:state() ~= "PLAYING" then
    -- Either paused by us, or the drive hit the end of the tape.
    if pos >= self.size - 1 then return "finished" end
    return "stopped"
  end
  return "playing"
end

return tape
