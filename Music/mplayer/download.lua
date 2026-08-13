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
--     alive but no bytes have arrived yet.
--   * read() and the tape's write() are both non-direct calls, so each one
--     costs roughly a game tick. Several chunks per step amortise that.
--
-- The card fills its response queue from a background thread and only sets
-- its end-of-stream flag when that thread finishes cleanly. If the connection
-- drops mid-transfer, the flag is never set: read() then returns "" forever
-- and the download simply hangs at whatever percentage it reached. So a
-- transfer that goes quiet is treated as broken and resumed with a Range
-- request rather than waited on.

local component = require("component")
local computer = require("computer")

local download = {}

local Job = {}
Job.__index = Job

-- Capped by OC's maxReadBuffer setting anyway; asking for more is harmless.
local CHUNK = 8192
-- Each read and each write costs a tick, so batching cuts the per-chunk
-- overhead. Keep it small enough that the interface stays responsive.
local CHUNKS_PER_STEP = 4
-- How long a silent connection is given before it is considered dead.
local STALL_SECONDS = 12
local MAX_ATTEMPTS = 4

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

local function formatSize(bytes)
  if bytes >= 1048576 then return ("%.1f MB"):format(bytes / 1048576) end
  if bytes >= 1024 then return ("%.0f KB"):format(bytes / 1024) end
  return bytes .. " B"
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
    headers = headers,
    start = start,
    limit = limit,
    written = 0,
    total = nil,
    state = "connecting",
    error = nil,
    truncated = false,
    attempts = 0,
    resuming = false,
    lastByteAt = computer.uptime(),
    startedAt = computer.uptime(),
    note = nil,
  }, Job)
end

function Job:_fail(message)
  self.state = "error"
  self.error = tostring(message)
  pcall(self.handle.close)
  return self.state
end

--- Reopen the connection from where we stopped. GitHub honours Range on both
--- raw.githubusercontent.com and the contents API.
function Job:_retry(reason)
  pcall(self.handle.close)

  if self.attempts >= MAX_ATTEMPTS then
    return self:_fail(("%s - gave up after %d attempts at %s")
      :format(reason, self.attempts + 1, formatSize(self.written)))
  end
  self.attempts = self.attempts + 1
  self.note = ("%s; resuming from %s"):format(reason, formatSize(self.written))

  local headers = {}
  for key, value in pairs(self.headers or {}) do headers[key] = value end
  headers["Range"] = ("bytes=%d-"):format(self.written)

  local handle, err = component.internet.request(self.url, nil, headers)
  if not handle then
    return self:_fail("could not reconnect: " .. tostring(err))
  end

  self.handle = handle
  self.resuming = true
  self.state = "connecting"
  self.lastByteAt = computer.uptime()
  return self.state
end

function Job:_connect()
  local ok, connected = pcall(self.handle.finishConnect)
  if not ok then
    -- A refused reconnect is worth one more try; a refused first connect is not.
    if self.resuming then return self:_retry(tostring(connected)) end
    return self:_fail(connected)
  end
  if not connected then
    if computer.uptime() - self.lastByteAt > STALL_SECONDS * 2 then
      return self:_retry("no response")
    end
    return self.state
  end

  local code, message, headers = self.handle.response()

  if self.resuming then
    if code == 200 then
      -- The server ignored the range and is sending the whole file again.
      self.written = 0
      self.truncated = false
    elseif code ~= 206 then
      return self:_fail(("HTTP %s %s on resume"):format(tostring(code), tostring(message or "")))
    end
  elseif code and code ~= 200 then
    return self:_fail(("HTTP %s %s"):format(tostring(code), tostring(message or "")))
  else
    local length = tonumber(headerValue(headers, "Content-Length"))
    if length then
      self.total = length
      if length > self.limit then self.truncated = true end
    end
  end

  -- Park the head where the next byte belongs; from here writes advance it.
  self.tape:seekTo(self.start + self.written)
  self.state = "downloading"
  self.lastByteAt = computer.uptime()
  return self.state
end

--- Advance the transfer. Call repeatedly until state is "done" or "error".
-- @return state: "connecting" | "downloading" | "done" | "error"
function Job:step()
  if self.state == "done" or self.state == "error" then
    return self.state
  end
  if self.state == "connecting" then
    return self:_connect()
  end

  local moved = false
  for _ = 1, CHUNKS_PER_STEP do
    local ok, chunk = pcall(self.handle.read, CHUNK)
    if not ok then
      return self:_retry(tostring(chunk))
    end
    if chunk == nil then
      return self:_finish()
    end
    if #chunk == 0 then
      break -- alive, but nothing available this instant
    end

    local remaining = self.limit - self.written
    if #chunk >= remaining then
      chunk = chunk:sub(1, remaining)
      self.truncated = true
    end
    if #chunk > 0 then
      self.tape.drive.write(chunk)
      -- The drive's own position is the source of truth for how much landed.
      self.written = self.tape:position() - self.start
      moved = true
    end
    if self.written >= self.limit then
      return self:_finish()
    end
  end

  if moved then
    self.lastByteAt = computer.uptime()
  elseif computer.uptime() - self.lastByteAt > STALL_SECONDS then
    return self:_retry(("stalled for %ds"):format(STALL_SECONDS))
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

--- A line describing what the transfer is doing, for the interface.
function Job:status()
  if self.state == "connecting" then
    if self.attempts > 0 then
      return ("Reconnecting, attempt %d of %d - %s")
        :format(self.attempts + 1, MAX_ATTEMPTS + 1, self.note or "")
    end
    return "Connecting..."
  end

  local elapsed = computer.uptime() - self.startedAt
  local rate = elapsed > 0.5 and (self.written / elapsed) or nil
  local line = "Recording " .. formatSize(self.written)
  if self.total then
    line = line .. " of " .. formatSize(math.min(self.total, self.limit))
  end
  if rate then
    line = line .. (" at %s/s"):format(formatSize(rate))
  end
  local quiet = computer.uptime() - self.lastByteAt
  if quiet > 3 then
    line = line .. (" - quiet for %ds"):format(math.floor(quiet))
  end
  if self.attempts > 0 then
    line = line .. (" - resumed %dx"):format(self.attempts)
  end
  return line
end

return download
