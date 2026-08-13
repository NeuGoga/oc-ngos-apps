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
--     costs roughly a game tick, and read is clamped to maxReadBuffer -- 2 KB
--     by default. Reads are therefore batched and committed in one write.
--
-- The card fills its response queue from a background thread and only raises
-- end-of-stream when that thread finishes cleanly. Two consequences shape
-- this module:
--
--   * A connection that drops mid-transfer never sets the flag, so read()
--     returns "" forever and a naive loop hangs at whatever percentage it
--     reached. A transfer that goes quiet is treated as broken and resumed
--     with a Range request.
--   * A keep-alive connection may never close even after sending everything,
--     so end-of-stream cannot be the only completion signal. Content-Length
--     is what actually finishes a transfer.

local component = require("component")
local computer = require("computer")

local download = {}

local Job = {}
Job.__index = Job

-- OpenComputers clamps every read to `maxReadBuffer`, which defaults to 2048
-- bytes, and read() is not a direct call -- so one read costs a game tick and
-- returns at most 2 KB. That puts a hard ceiling of about 40 KB/s on any
-- transfer, and it is only reachable by keeping reads back to back.
--
-- Asking for more than the clamp is harmless, so ask for a comfortable amount
-- in case a pack raises the setting.
local CHUNK = 8192
-- Reads per pass. Writing is also non-direct, so the reads are accumulated in
-- memory and committed in one write: 16 reads plus 1 write moves ~32 KB in 17
-- ticks, where read-then-write per chunk managed 8 KB in 8 ticks.
local READS_PER_STEP = 16
local FLUSH_BYTES = 32768
-- How long a silent connection is given before it is considered dead. Gaps of
-- a few seconds are normal when the card's queue runs dry, so this is
-- generous; a needless reconnect costs more than waiting.
local STALL_SECONDS = 20
-- When the server cannot resume, reconnecting throws away everything already
-- transferred, so it is worth waiting far longer before doing it.
local RESTART_SECONDS = 90
local MAX_ATTEMPTS = 6

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
-- @param expectedBytes optional exact size. The song catalogue records this,
--                and it is more trustworthy than a response header: it is
--                what makes "have we got everything" answerable even if the
--                card hands back headers we cannot read.
function download.start(tapeObj, url, title, headers, expectedBytes, rate)
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
    total = tonumber(expectedBytes),
    expected = tonumber(expectedBytes),
    rate = tonumber(rate),
    state = "connecting",
    error = nil,
    truncated = false,
    attempts = 0,
    resuming = false,
    resumable = nil,   -- set from Accept-Ranges on the first response
    lastByteAt = computer.uptime(),
    startedAt = computer.uptime(),
    sampleAt = computer.uptime(),
    sampleBytes = 0,
    rate = nil,
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
  -- Never reconnect for bytes that do not exist: a Range request past the end
  -- of the file answers 416, which would look like a failure at 100%.
  if self:_complete() then
    return self:_finish()
  end

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
      -- The server ignored the range and is sending the whole file again, so
      -- everything already on the tape is worthless. Remember that, because
      -- restarting on every hiccup would never converge.
      self.resumable = false
      self.written = 0
      self.truncated = false
    elseif code == 416 then
      -- Range Not Satisfiable: there is nothing past what we already hold.
      return self:_finish()
    elseif code ~= 206 then
      return self:_fail(("HTTP %s %s on resume"):format(tostring(code), tostring(message or "")))
    end
  elseif code and code ~= 200 then
    return self:_fail(("HTTP %s %s"):format(tostring(code), tostring(message or "")))
  else
    -- A caller-supplied size wins: it came from our own catalogue.
    local length = tonumber(headerValue(headers, "Content-Length"))
    if not self.expected and length then
      self.total = length
    end
    if self.total and self.total > self.limit then
      self.truncated = true
    end
    local ranges = headerValue(headers, "Accept-Ranges")
    self.resumable = ranges ~= nil and tostring(ranges):lower():find("bytes") ~= nil
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

  -- Gather several reads before touching the tape, so the write tick is paid
  -- once per batch instead of once per 2 KB.
  local parts, pending, failure, atEnd = {}, 0, nil, false

  for _ = 1, READS_PER_STEP do
    local ok, chunk = pcall(self.handle.read, CHUNK)
    if not ok then
      failure = tostring(chunk)
      break
    end
    if chunk == nil then
      atEnd = true
      break
    end
    if #chunk == 0 then
      break -- alive, but nothing available this instant
    end
    parts[#parts + 1] = chunk
    pending = pending + #chunk
    if pending >= FLUSH_BYTES then break end
  end

  -- Commit whatever arrived, even if the connection then failed: those bytes
  -- are good and a resume should not fetch them twice.
  if pending > 0 then
    local data = table.concat(parts)
    local remaining = self.limit - self.written
    if #data >= remaining then
      data = data:sub(1, remaining)
      self.truncated = true
    end
    if #data > 0 then
      self.tape.drive.write(data)
      -- The drive's own position is the source of truth for how much landed.
      self.written = self.tape:position() - self.start
    end
    local now = computer.uptime()
    self.lastByteAt = now
    -- Sample a recent rate. The lifetime average is dragged down by every
    -- stall and reconnect, which makes a healthy transfer look broken.
    if now - self.sampleAt >= 2 then
      self.rate = (self.written - self.sampleBytes) / (now - self.sampleAt)
      self.sampleAt, self.sampleBytes = now, self.written
    end
  end

  if self:_complete() then
    return self:_finish()
  end
  if atEnd then
    return self:_finish()
  end
  if failure then
    return self:_retry(failure)
  end
  local patience = (self.resumable == false) and RESTART_SECONDS or STALL_SECONDS
  if pending == 0 and computer.uptime() - self.lastByteAt > patience then
    return self:_retry(("stalled for %ds"):format(patience))
  end

  return self.state
end

--- Have we got everything we are ever going to get?
--
-- This matters more than it looks. The card only reports end-of-stream when
-- its background reader sees the socket close, and a keep-alive connection
-- may never close -- so waiting for that alone can hang at 100%, then "resume"
-- past the end of the file forever. Content-Length is the reliable signal.
function Job:_complete()
  if self.written >= self.limit then return true end
  local target = self.total and math.min(self.total, self.limit) or nil
  return target ~= nil and self.written >= target
end

function Job:_finish()
  pcall(self.handle.close)
  if self.written <= 0 then
    return self:_fail("the server sent no data")
  end
  local ok, err = self.tape:addTrack(self.title, self.start, self.written, self.rate)
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
  return self.tape:bytesToSeconds(self.written, self.rate)
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
  local rate = self.rate or (elapsed > 1 and (self.written / elapsed) or nil)
  local line = "Recording " .. formatSize(self.written)
  local target = self.total and math.min(self.total, self.limit) or nil
  if target then
    line = line .. " of " .. formatSize(target)
  end
  if rate and rate > 0 then
    line = line .. (" at %s/s"):format(formatSize(rate))
    if target then
      local left = (target - self.written) / rate
      if left > 1 then
        line = line .. (", %d:%02d left"):format(left // 60, math.floor(left % 60))
      end
    end
  end
  local quiet = computer.uptime() - self.lastByteAt
  if quiet > 3 then
    line = line .. (" - quiet for %ds"):format(math.floor(quiet))
  end
  if self.attempts > 0 then
    line = line .. (self.resumable == false and " - RESTARTED %dx" or " - resumed %dx")
      :format(self.attempts)
  end
  return line
end

return download
