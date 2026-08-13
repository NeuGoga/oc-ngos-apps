-- mplayer.player -- queue and transport logic on top of a tape drive.
--
-- The tape holds a fixed set of physical tracks; the "queue" here is the play
-- order over them, which shuffle reorders and repeat loops. Nothing blocks:
-- call update() from your event loop and it advances tracks as they end.

local tape = require("mplayer.tape")
local download = require("mplayer.download")

local player = {}

local Player = {}
Player.__index = Player

local CONFIG_DIR = "/etc/mplayer"
local CONFIG_FILE = CONFIG_DIR .. "/config.txt"

--- Create a player bound to the tape drive.
function player.new(opts)
  opts = opts or {}
  local deck, err = tape.new(opts.address)
  if not deck then return nil, err end

  local self = setmetatable({
    tape = deck,
    order = {},
    cursor = 0,          -- index into self.order, 0 when stopped
    state = "stopped",   -- "stopped" | "playing" | "paused"
    shuffle = false,
    repeatMode = "off",  -- "off" | "all" | "one"
    volume = 1.0,
    speed = 1.0,
    history = {},
    message = nil,
    job = nil,           -- in-flight download
  }, Player)

  self:loadConfig()
  deck:setVolume(self.volume)
  deck:setSpeed(self.speed)
  self:rebuildOrder()
  return self
end

-- Queue ------------------------------------------------------------------

function Player:tracks()
  return self.tape.tracks
end

function Player:trackCount()
  return #self.tape.tracks
end

--- Rebuild the play order from the tape's track list.
function Player:rebuildOrder()
  local playingTrack = self:currentTrackIndex()
  self.order = {}
  for i = 1, #self.tape.tracks do
    self.order[i] = i
  end
  if self.shuffle then
    -- Fisher-Yates
    for i = #self.order, 2, -1 do
      local j = math.random(i)
      self.order[i], self.order[j] = self.order[j], self.order[i]
    end
  end
  -- Keep pointing at whatever is currently playing.
  self.cursor = 0
  if playingTrack then
    for i, t in ipairs(self.order) do
      if t == playingTrack then self.cursor = i break end
    end
  end
end

--- Physical track index currently loaded, or nil.
function Player:currentTrackIndex()
  return self.order[self.cursor]
end

function Player:currentTrack()
  local i = self:currentTrackIndex()
  return i and self.tape.tracks[i] or nil
end

--- Re-read the tape (after a swap) and rebuild the order.
function Player:refresh()
  self:stop()
  self.tape:refresh()
  self:rebuildOrder()
  return self.tape.ready
end

-- Transport --------------------------------------------------------------

--- Play the Nth entry of the play order.
function Player:playOrderIndex(n)
  if n < 1 or n > #self.order then return false end
  local trackIndex = self.order[n]
  local ok, err = self.tape:playTrack(trackIndex)
  if not ok then
    self.message = err
    self.state = "stopped"
    return false
  end
  self.cursor = n
  self.state = "playing"
  self.message = nil
  return true
end

--- Play a physical track (what the list UI clicks on).
function Player:playTrack(trackIndex)
  for n, t in ipairs(self.order) do
    if t == trackIndex then return self:playOrderIndex(n) end
  end
  return false
end

--- Play/pause. Starts at the top of the order when stopped.
function Player:toggle()
  if self.state == "playing" then
    self.tape:pause()
    self.state = "paused"
  elseif self.state == "paused" then
    self.tape:resume()
    self.state = "playing"
  else
    if #self.order == 0 then
      self.message = "no tracks on this tape"
      return self.state
    end
    self:playOrderIndex(self.cursor > 0 and self.cursor or 1)
  end
  return self.state
end

function Player:stop()
  self.tape:stop()
  self.state = "stopped"
end

--- Next track. `auto` marks an end-of-track advance, the only case where
--- repeat-one applies and the only case that can stop at the end of the tape.
function Player:next(auto)
  if #self.order == 0 then return false end

  if auto and self.repeatMode == "one" then
    return self:playOrderIndex(self.cursor)
  end

  if self.cursor > 0 then
    self.history[#self.history + 1] = self.cursor
    if #self.history > 32 then table.remove(self.history, 1) end
  end

  local n = self.cursor + 1
  if n > #self.order then
    if auto and self.repeatMode ~= "all" then
      self:stop()
      self.cursor = 0
      return false
    end
    if self.shuffle then self:rebuildOrder() end
    n = 1
  end
  return self:playOrderIndex(n)
end

--- Previous track, or restart the current one if more than 3 seconds in.
function Player:prev()
  if #self.order == 0 then return false end

  if self.state ~= "stopped" and self.tape:trackPosition() > 3 then
    return self:playOrderIndex(self.cursor)
  end

  local n
  if #self.history > 0 then
    n = table.remove(self.history)
  else
    n = self.cursor - 1
    if n < 1 then n = #self.order end
  end
  return self:playOrderIndex(n)
end

--- Skip within the current track, in seconds (negative rewinds).
function Player:skip(seconds)
  if self.state == "stopped" then return false end
  return self.tape:seekWithinTrack(self.tape:trackPosition() + seconds)
end

function Player:position()
  return self.tape:trackPosition()
end

function Player:duration()
  local track = self:currentTrack()
  return track and track.duration or 0
end

function Player:setVolume(v)
  self.volume = self.tape:setVolume(v)
  return self.volume
end

function Player:nudgeVolume(delta)
  return self:setVolume(self.volume + delta)
end

--- Pitch multiplier on top of whatever speed the current track needs. A track
--- recorded at 65536 Hz already plays at 2.0, the drive's maximum, so it
--- cannot be pushed faster -- the clamp handles that quietly.
function Player:setSpeed(v)
  self.speed = math.max(0.25, math.min(2.0, v))
  self.tape.pitch = self.speed
  local track = self:currentTrack()
  if track then
    self.tape:setSpeed(self.tape:speedFor(track.rate) * self.speed)
  end
  return self.speed
end

function Player:toggleShuffle()
  self.shuffle = not self.shuffle
  self.history = {}
  self:rebuildOrder()
  return self.shuffle
end

function Player:cycleRepeat()
  self.repeatMode = self.repeatMode == "off" and "all"
      or self.repeatMode == "all" and "one"
      or "off"
  return self.repeatMode
end

-- Library management -----------------------------------------------------

--- Start downloading a .dfpwm URL onto the end of the tape.
-- @param headers optional auth headers (private repository)
function Player:download(url, title, headers, expectedBytes, rate)
  if self.job then return nil, "a download is already running" end
  -- Recording writes to the tape head, so playback has to get out of the way.
  self:stop()
  local job, err = download.start(self.tape, url, title, headers, expectedBytes, rate)
  if not job then return nil, err end
  self.job = job
  return job
end

--- Record a song straight from the repository's music catalog.
function Player:downloadFromCatalog(entry)
  local catalog = require("mplayer.catalog")
  local repo = require("mplayer.repo")
  local cfg = repo.load()
  -- Songs may live in a different repository than the app, so validate that
  -- one rather than the app's.
  if not repo.configured(repo.songs(cfg)) then
    return nil, "song repository is not configured (run: music setup)"
  end
  local url, headers = catalog.source(cfg, entry)
  return self:download(url, entry.title, headers, entry.bytes, entry.rate)
end

function Player:removeTrack(i)
  local ok, err = self.tape:removeTrack(i)
  if ok then self:rebuildOrder() end
  return ok, err
end

function Player:wipe()
  local ok, err = self.tape:wipeIndex()
  if ok then
    self.cursor = 0
    self:rebuildOrder()
  end
  return ok, err
end

-- Main loop --------------------------------------------------------------

--- Pump playback and any running download. Call this often.
function Player:update()
  if self.job then
    local state = self.job:step()
    if state == "done" then
      self.message = ("Saved \"%s\" (%s)"):format(self.job.title,
        player.formatTime(self.job:seconds()))
      if self.job.truncated then
        self.message = self.message .. " - truncated, tape ran out"
      end
      self.job = nil
      self:rebuildOrder()
    elseif state == "error" then
      self.message = "Download failed: " .. tostring(self.job.error)
      self.job = nil
    else
      -- Show bytes, rate and any resume attempts, so a slow or retrying
      -- transfer is visibly different from a dead one.
      self.message = self.job:status()
    end
    return self.state
  end

  if self.state == "playing" then
    local result = self.tape:update()
    if result == "finished" then
      self:next(true)
    elseif result == "stopped" then
      -- The drive stopped on its own (end of tape).
      self.state = "stopped"
    end
  end
  return self.state
end

--- How long the caller may sleep before update() should run again.
function Player:timeUntilUpdate()
  if self.job then return 0 end
  if self.state == "playing" then return 0.25 end
  return 0.5
end

-- Helpers ----------------------------------------------------------------

function player.formatTime(seconds)
  seconds = math.max(0, math.floor(seconds or 0))
  return ("%d:%02d"):format(math.floor(seconds / 60), seconds % 60)
end

function player.formatSize(bytes)
  if bytes >= 1048576 then return ("%.1f MB"):format(bytes / 1048576) end
  if bytes >= 1024 then return ("%.0f KB"):format(bytes / 1024) end
  return bytes .. " B"
end

-- Settings ---------------------------------------------------------------

function Player:saveConfig()
  local fs = require("filesystem")
  if not fs.exists(CONFIG_DIR) then fs.makeDirectory(CONFIG_DIR) end
  local f = io.open(CONFIG_FILE, "w")
  if not f then return end
  f:write(("volume=%.3f\nspeed=%.3f\nshuffle=%s\nrepeat=%s\n")
    :format(self.volume, self.speed, tostring(self.shuffle), self.repeatMode))
  f:close()
end

function Player:loadConfig()
  local fs = require("filesystem")
  if not fs.exists(CONFIG_FILE) then return end
  local f = io.open(CONFIG_FILE, "r")
  if not f then return end
  for line in f:lines() do
    local key, value = line:match("^(%w+)=(.*)$")
    if key == "volume" then self.volume = tonumber(value) or self.volume
    elseif key == "speed" then self.speed = tonumber(value) or self.speed
    elseif key == "shuffle" then self.shuffle = value == "true"
    elseif key == "repeat" then self.repeatMode = value end
  end
  f:close()
end

function Player:close()
  self:saveConfig()
  if self.job then self.job:cancel() end
  self:stop()
end

return player
