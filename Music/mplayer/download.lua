-- mplayer.download -- stream a .dfpwm file from the internet straight onto a
-- cassette tape.
--
-- Nothing is buffered on disk: bytes go from the internet card's response
-- queue into the tape drive a chunk at a time, so tape length is the only
-- limit and a 3.5 MB song does not need 3.5 MB of free disk.
--
-- Internet card semantics that matter here (InternetCard.scala):
--
--   * component.internet.request(url) returns a handle, or nil plus a reason.
--   * Handle methods take no self: handle.read(n), handle.response(), ...
--   * finishConnect() returns false while still connecting and raises an
--     error if the connection failed outright, so it always needs a pcall.
--   * read(n) returns nil at end of stream, and "" when the connection is
--     alive but no bytes have arrived yet. Those two must not be confused.
--   * read() and the tape's write() are both non-direct calls, so each one
--     costs roughly a game tick. Bigger chunks are dramatically faster.

local component = require("component")

local download = {}

local Job = {}
Job.__index = Job

-- Capped by OC's maxReadBuffer setting anyway; asking for more is harmless.
local CHUNK = 8192

function download.available()
  return component.isAvailable("internet")
end

local function headerValue(headers, name)
  if type(headers) ~= "table" then return nil end
  local wanted = name:lower()
  for key, value in pairs(headers) do
    if type(key) == "string" and key:lower() == wanted then
      if type(value) == "table" then return value[1] end
      return value
    end
  end
  return nil
end

--- Begin a download. The job does no work until you call step().
-- @param tapeObj an mplayer.tape instance with a tape loaded
-- @param url     direct link to a raw .dfpwm file
-- @param title   track title to record in the tape index
-- @param headers optional header table, e.g. the auth headers for a private
--                repository from mplayer.repo
function download.start(tapeObj, url, title, headers)
  if not component.isAvailable("internet") then
    return nil, "no internet card installed"
  end
  if not tapeObj or not tapeObj.ready then
    return nil, "no tape in the drive"
  end

  local start = tapeObj:used()
  local limit = tapeObj:capacity() - start
  if limit <= 0 then
    return nil, "tape is full"
  end

  local handle, reason = component.internet.request(url, nil, headers)
  if not handle then
    return nil, reason or "request rejected"
  end

  return setmetatable({
    tape = tapeObj,
    handle = handle,
    url = url,
    title = title,
    start = start,
    limit = limit,
    written = 0,
    total = nil,
    state = "connecting",
    error = nil,
    truncated = false,
  }, Job)
end

function Job:_fail(message)
  self.state = "error"
  self.error = tostring(message)
  pcall(self.handle.close)
  return self.state
end

--- Advance the transfer. Call repeatedly until state is "done" or "error".
-- @return state: "connecting" | "downloading" | "done" | "error"
function Job:step()
  if self.state == "done" or self.state == "error" then
    return self.state
  end

  if self.state == "connecting" then
    local ok, connected = pcall(self.handle.finishConnect)
    if not ok then
      return self:_fail(connected)
    end
    if not connected then
      return self.state
    end

    local code, message, headers = self.handle.response()
    if code and code ~= 200 then
      return self:_fail(("HTTP %s %s"):format(tostring(code), tostring(message or "")))
    end

    local length = tonumber(headerValue(headers, "Content-Length"))
    if length then
      self.total = length
      if length > self.limit then
        self.truncated = true
      end
    end

    -- Park the head where this track begins; from here writes advance it.
    self.tape:seekTo(self.start)
    self.state = "downloading"
    return self.state
  end

  -- downloading
  local ok, chunk = pcall(self.handle.read, CHUNK)
  if not ok then
    return self:_fail(chunk)
  end

  if chunk == nil then
    return self:_finish()
  end

  if #chunk > 0 then
    local remaining = self.limit - self.written
    if #chunk >= remaining then
      chunk = chunk:sub(1, remaining)
      self.truncated = true
    end
    if #chunk > 0 then
      self.tape.drive.write(chunk)
      -- The drive's own position is the source of truth for how much landed.
      self.written = self.tape:position() - self.start
    end
    if self.written >= self.limit then
      return self:_finish()
    end
  end

  return self.state
end

function Job:_finish()
  pcall(self.handle.close)
  if self.written <= 0 then
    return self:_fail("the server sent no data")
  end
  local ok, err = self.tape:addTrack(self.title, self.start, self.written)
  if not ok then
    return self:_fail(err or "could not update the tape index")
  end
  self.state = "done"
  return self.state
end

--- Abort. The bytes already written stay on the tape but no track is added,
--- so the space is reused by the next download.
function Job:cancel()
  pcall(self.handle.close)
  self.state = "error"
  self.error = "cancelled"
end

--- Fraction complete, or nil when the server sent no Content-Length.
function Job:progress()
  local target = self.total and math.min(self.total, self.limit) or nil
  if not target or target <= 0 then return nil end
  return math.min(1, self.written / target)
end

--- Seconds of audio written so far.
function Job:seconds()
  return self.tape:bytesToSeconds(self.written)
end

return download
