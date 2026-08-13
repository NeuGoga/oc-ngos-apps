-- mplayer.record -- pull a song off a TCP socket straight onto a cassette.
--
-- The far end is tools/stream_server.py on a PC: it decodes and filters with
-- ffmpeg, compresses to DFPWM 1.0, and writes the bytes down the socket. When
-- the song ends the server closes the connection.
--
-- A raw socket is used rather than HTTP on purpose. Over HTTP, GitHub answers
-- `Connection: keep-alive` and never closes, so read() returns "" forever and
-- there is no reliable end-of-stream -- which previously meant inventing
-- Content-Length completion, stall detection and Range resume just to know
-- when a download had finished. A socket that closes is unambiguous: read()
-- returns nil, and that means done.
--
-- Internet card semantics that matter (InternetCard.scala):
--
--   * connect(host, port) returns a handle, or nil plus a reason.
--   * Handle methods take no self: handle.read(n), handle.close(), ...
--   * finishConnect() RAISES on failure rather than returning false, so it
--     always needs a pcall.
--   * read(n) returns nil at end of stream, "" when the connection is alive
--     but nothing has arrived yet. Confusing those two hangs the transfer.
--   * read is a non-direct call, so it costs a game tick, and it is clamped
--     to maxReadBuffer -- 2 KB by default. tape.write is non-direct too, so
--     reads are batched and committed in one write.

local component = require("component")
local computer = require("computer")

local record = {}

local Job = {}
Job.__index = Job

-- Asking for more than maxReadBuffer is harmless; it just returns less.
local CHUNK = 8192
-- Reads per pass, then a single write. Each call costs a tick, so writing per
-- chunk would halve throughput for no reason.
local READS_PER_PASS = 16
local FLUSH_BYTES = 32768
-- A socket that says nothing for this long is treated as dead. There is no
-- resuming a stream, so this fails loudly rather than hanging.
local SILENCE_SECONDS = 30
local CONNECT_SECONDS = 20

function record.available()
  return component.isAvailable("internet")
end

local function formatSize(bytes)
  if bytes >= 1048576 then return ("%.1f MB"):format(bytes / 1048576) end
  if bytes >= 1024 then return ("%.0f KB"):format(bytes / 1024) end
  return bytes .. " B"
end

--- Begin recording. Does no work until you call step().
-- @param deck an mplayer.tape deck with a cassette in it
-- @param host stream server hostname (an ngrok TCP endpoint, say)
-- @param port stream server port
function record.start(deck, host, port)
  if not component.isAvailable("internet") then
    return nil, "no internet card installed"
  end
  if not deck or not deck.ready then
    return nil, "no cassette in the drive"
  end
  if not host or host == "" then
    return nil, "no stream server configured"
  end

  local handle, reason = component.internet.connect(host, tonumber(port) or 0)
  if not handle then
    return nil, reason or "connection refused"
  end

  -- Recording always starts at the beginning: one cassette, one song.
  deck:rewind()

  return setmetatable({
    deck = deck,
    handle = handle,
    host = host,
    port = port,
    limit = deck:capacity(),
    written = 0,
    state = "connecting",
    error = nil,
    truncated = false,
    startedAt = computer.uptime(),
    lastByteAt = computer.uptime(),
    sampleAt = computer.uptime(),
    sampleBytes = 0,
    rate = nil,
  }, Job)
end

function Job:_fail(message)
  self.state = "error"
  self.error = tostring(message)
  pcall(self.handle.close)
  return self.state
end

function Job:_connect()
  -- finishConnect raises if the connection failed outright.
  local ok, connected = pcall(self.handle.finishConnect)
  if not ok then
    return self:_fail(connected)
  end
  if not connected then
    if computer.uptime() - self.startedAt > CONNECT_SECONDS then
      return self:_fail(("no answer from %s:%s"):format(self.host, tostring(self.port)))
    end
    return self.state
  end
  self.state = "recording"
  self.lastByteAt = computer.uptime()
  return self.state
end

--- Advance the transfer. Call until state is "done" or "error".
function Job:step()
  if self.state == "done" or self.state == "error" then
    return self.state
  end
  if self.state == "connecting" then
    return self:_connect()
  end

  local parts, pending, atEnd, failure = {}, 0, false, nil

  for _ = 1, READS_PER_PASS do
    local ok, chunk = pcall(self.handle.read, CHUNK)
    if not ok then
      failure = tostring(chunk)
      break
    end
    if chunk == nil then
      atEnd = true          -- server closed: the song is complete
      break
    end
    if #chunk == 0 then
      break                 -- alive, nothing ready this instant
    end
    parts[#parts + 1] = chunk
    pending = pending + #chunk
    if pending >= FLUSH_BYTES then break end
  end

  if pending > 0 then
    local data = table.concat(parts)
    local room = self.limit - self.written
    if #data >= room then
      data = data:sub(1, room)
      self.truncated = true
    end
    if #data > 0 then
      self.deck.drive.write(data)
      -- The drive's position is the truth. TapeStorage.write clamps silently,
      -- so counting what we sent would overstate what actually landed.
      self.written = self.deck:position()
    end

    local now = computer.uptime()
    self.lastByteAt = now
    if now - self.sampleAt >= 2 then
      self.rate = (self.written - self.sampleBytes) / (now - self.sampleAt)
      self.sampleAt, self.sampleBytes = now, self.written
    end
  end

  if self.truncated or self.written >= self.limit then
    return self:_finish()
  end
  if atEnd then
    return self:_finish()
  end
  if failure then
    return self:_fail(failure)
  end
  if pending == 0 and computer.uptime() - self.lastByteAt > SILENCE_SECONDS then
    return self:_fail(("the stream went quiet for %ds"):format(SILENCE_SECONDS))
  end

  return self.state
end

function Job:_finish()
  pcall(self.handle.close)
  if self.written <= 0 then
    return self:_fail("the server sent no data")
  end
  self.state = "done"
  return self.state
end

--- Abort. Whatever landed stays on the tape; re-record to overwrite it.
function Job:cancel()
  pcall(self.handle.close)
  self.state = "error"
  self.error = "cancelled"
end

--- Seconds of audio written so far.
function Job:seconds()
  return self.written / require("mplayer.tape").BYTES_PER_SECOND
end

--- A line describing the transfer, for the interface.
function Job:status()
  if self.state == "connecting" then
    return ("Connecting to %s:%s..."):format(self.host, tostring(self.port))
  end

  local line = "Recording " .. formatSize(self.written)
  local elapsed = computer.uptime() - self.startedAt
  local rate = self.rate or (elapsed > 1 and (self.written / elapsed) or nil)
  if rate and rate > 0 then
    line = line .. (" at %s/s"):format(formatSize(rate))
  end
  local quiet = computer.uptime() - self.lastByteAt
  if quiet > 3 then
    line = line .. (" - quiet for %ds"):format(math.floor(quiet))
  end
  return line
end

return record
