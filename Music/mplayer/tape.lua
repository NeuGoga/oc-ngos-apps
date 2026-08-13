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

local INDEX_SIZE = 2048
local INDEX_MAGIC = "MPTAPE1"

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

--- Seconds of audio a byte count represents at the current speed.
function Tape:bytesToSeconds(bytes)
  return bytes / (BYTES_PER_SECOND * self.speed)
end

function Tape:secondsToBytes(seconds)
  return math.floor(seconds * BYTES_PER_SECOND * self.speed)
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
--   MPTAPE1
--   <count>
--   <start> <length> <title>
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

  if lines[1] ~= INDEX_MAGIC then return self.tracks end

  local count = tonumber(lines[2]) or 0
  for i = 1, count do
    local line = lines[2 + i]
    if line then
      local start, length, title = line:match("^(%d+)%s+(%d+)%s*(.*)$")
      if start then
        start, length = tonumber(start), tonumber(length)
        if start + length <= self:capacity() + 1 then
          self.tracks[#self.tracks + 1] = {
            start = start,
            length = length,
            title = (title ~= "" and title) or ("Track " .. i),
            duration = self:bytesToSeconds(length),
          }
        end
      end
    end
  end
  return self.tracks
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
    parts[#parts + 1] = ("%d %d %s"):format(t.start, t.length, title)
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
function Tape:addTrack(title, start, length)
  self.tracks[#self.tracks + 1] = {
    start = start,
    length = length,
    title = title,
    duration = self:bytesToSeconds(length),
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
  return self:bytesToSeconds(offset)
end

--- Jump to a point inside the current track, given in seconds.
function Tape:seekWithinTrack(seconds)
  local track = self.tracks[self.playing or 0]
  if not track then return false end
  local offset = math.max(0, math.min(self:secondsToBytes(seconds), track.length))
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
