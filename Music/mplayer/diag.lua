-- mplayer.diag -- what the internet card actually returns for a song.
--
-- Every stalled-download theory has come down to details that cannot be seen
-- from outside the game: whether Content-Length arrives, what shape the header
-- table is in, whether the far end honours Range, and how many bytes a single
-- read yields. This gathers all of that into plain lines, which both the
-- interface and the shell command render.

local component = require("component")
local computer = require("computer")
local repo = require("mplayer.repo")

local diag = {}

local function add(lines, text)
  lines[#lines + 1] = text or ""
end

--- Open a connection and describe the response.
local function probe(lines, url, headers, label)
  local handle, reason = component.internet.request(url, nil, headers)
  if not handle then
    add(lines, ("  %s: request rejected - %s"):format(label, tostring(reason)))
    return
  end

  local deadline = computer.uptime() + 30
  while true do
    local ok, connected = pcall(handle.finishConnect)
    if not ok then
      add(lines, ("  %s: connect failed - %s"):format(label, tostring(connected)))
      pcall(handle.close)
      return
    end
    if connected then break end
    if computer.uptime() > deadline then
      add(lines, ("  %s: timed out connecting"):format(label))
      pcall(handle.close)
      return
    end
  end

  local code, message, responseHeaders = handle.response()
  add(lines, ("  %s: HTTP %s %s"):format(label, tostring(code), tostring(message or "")))
  add(lines, ("    header table type: %s"):format(type(responseHeaders)))

  if type(responseHeaders) == "table" then
    local count = 0
    for key, value in pairs(responseHeaders) do
      count = count + 1
      local shown = type(value) == "table" and tostring(value[1]) or tostring(value)
      add(lines, ("    [%s] %s = %s"):format(type(key), tostring(key), shown))
    end
    if count == 0 then
      add(lines, "    (empty - no headers reached Lua)")
    end
  end

  local ok, chunk = pcall(handle.read, 8192)
  if not ok then
    add(lines, ("    first read: error %s"):format(tostring(chunk)))
  elseif chunk == nil then
    add(lines, "    first read: nil (end of stream already)")
  else
    add(lines, ("    first read: %d bytes"):format(#chunk))
  end

  pcall(handle.close)
end

--- Build the report. Returns an array of lines.
-- @param index which catalogue entry to probe (default 1)
function diag.report(cfg, index)
  cfg = cfg or repo.load()
  local lines = {}

  add(lines, "COMPONENTS")
  for _, name in ipairs({ "tape_drive", "internet", "gpu" }) do
    add(lines, ("  %-12s %s"):format(name, component.isAvailable(name) and "yes" or "NO"))
  end

  local songs = repo.songs(cfg)
  add(lines)
  add(lines, "SONG REPOSITORY")
  add(lines, ("  %s/%s  branch %s"):format(songs.owner, songs.name, songs.branch))
  add(lines, ("  token: %s"):format(repo.isPrivate(songs) and "set" or "none"))

  local catalog = require("mplayer.catalog")
  local list, err = catalog.fetch(cfg)
  if not list then
    add(lines, ("  catalogue FAILED: %s"):format(tostring(err)))
    return lines
  end
  add(lines, ("  catalogue OK, %d song(s)"):format(#list))

  local entry = list[index or 1]
  if not entry then
    add(lines, "  no song to probe")
    return lines
  end

  add(lines)
  add(lines, "SONG")
  add(lines, ("  %s"):format(entry.title))
  add(lines, ("  catalogue size: %s bytes"):format(tostring(entry.bytes)))

  local url, headers = catalog.source(cfg, entry)
  add(lines, "  " .. url)

  add(lines)
  add(lines, "RESPONSE")
  probe(lines, url, headers, "plain")

  local ranged = {}
  for key, value in pairs(headers or {}) do ranged[key] = value end
  ranged["Range"] = "bytes=1000-"
  probe(lines, url, ranged, "range")

  -- Does the tape actually hold the bytes the server has? This separates a
  -- bad recording from bad playback, which is otherwise guesswork.
  add(lines)
  add(lines, "TAPE CONTENTS")
  local tapeLib = require("mplayer.tape")
  if not tapeLib.available() then
    add(lines, "  no tape drive")
  else
    local deck = tapeLib.new()
    local track
    for _, t in ipairs(deck and deck.tracks or {}) do
      if t.title == entry.title then track = t break end
    end
    if not deck or not deck.ready then
      add(lines, "  no tape in the drive")
    elseif not track then
      add(lines, ("  \"%s\" is not recorded on this tape yet"):format(entry.title))
      add(lines, "  (record it, then run this again)")
    else
      add(lines, "  index as stored on the tape:")
      local rawIndex = deck:rawIndex()
      if rawIndex then
        for line in rawIndex:gmatch("[^\n]+") do
          add(lines, "    |" .. line)
        end
      else
        add(lines, "    (could not read it)")
      end

      local SAMPLE = 4096
      add(lines, ("  track at byte %d, length %d, rate %d")
        :format(track.start, track.length, track.rate or 32768))

      deck:stop()
      deck:seekTo(track.start)
      local onTape = deck.drive.read(SAMPLE)

      local ranged = {}
      for key, value in pairs(headers or {}) do ranged[key] = value end
      ranged["Range"] = ("bytes=0-%d"):format(SAMPLE - 1)
      local fromServer = repo.httpGet(url, ranged)

      if not fromServer then
        add(lines, "  could not fetch the source to compare against")
      elseif not onTape then
        add(lines, "  could not read the tape")
      else
        local n = math.min(#onTape, #fromServer, SAMPLE)
        local firstBad
        for i = 1, n do
          if onTape:byte(i) ~= fromServer:byte(i) then firstBad = i break end
        end
        add(lines, ("  compared %d bytes"):format(n))
        if firstBad then
          add(lines, ("  MISMATCH at byte %d: tape %d, server %d")
            :format(firstBad, onTape:byte(firstBad), fromServer:byte(firstBad)))
          add(lines, "  the recording is wrong, not the playback")
        else
          add(lines, "  identical - the tape holds exactly what the server has")
          add(lines, "  so any wrong sound is playback, not the recording")
        end
      end
    end
  end

  add(lines)
  add(lines, "EXPECTED")
  add(lines, "  Content-Length present, Accept-Ranges: bytes,")
  add(lines, "  HTTP 206 on the range probe, first read ~2048 bytes.")
  return lines
end

return diag
