-- music -- Computronics tape player for OpenOS.
--
-- Usage:
--   music                       open the player interface
--   music play [n]              play track n (or the first track) and exit
--   music stop                  stop playback and exit
--   music list                  list the tracks on the tape
--   music add <url> [title]     record a .dfpwm URL onto the end of the tape
--   music library               list the songs hosted in the repository
--   music get <n|name>          record song n from the library onto the tape
--   music setup                 configure the repository and access token
--   music update                pull a newer version of this app
--   music wipe                  clear the tape's track index
--
-- The bare `music` form is the interesting one; the subcommands exist so the
-- drive can be driven from other scripts or from a robot.

-- The libraries live with the app, wherever the NgOS store put it.
package.path = package.path .. ";/apps/Music/?.lua;/lib/?.lua;/usr/lib/?.lua"

local component = require("component")
local player = require("mplayer.player")

local args = { ... }
local command = args[1]

local function fail(message)
  io.stderr:write(message .. "\n")
  os.exit(1)
end

-- Commands that need no hardware ----------------------------------------
-- These run before the tape drive check so the app can be configured and
-- updated on a machine whose drive is not wired up yet.

local repoLib = require("mplayer.repo")

if command == "setup" then
  local cfg = repoLib.load()

  local function ask(label, current, secret)
    local shown = secret and (current ~= "" and "set" or "none") or current
    io.write(("%s [%s]: "):format(label, shown))
    local answer = io.read()
    if answer == nil then print("") os.exit(1) end
    answer = answer:match("^%s*(.-)%s*$")
    return answer ~= "" and answer or current
  end

  print("Leave a field blank to keep the value in brackets.")
  print("")
  print("1. Where the app itself comes from.")
  print("   The defaults point at the public NgOS app repository;")
  print("   you only need to change these if you forked it.")
  cfg.owner = ask("  GitHub user", cfg.owner)
  cfg.name = ask("  Repository", cfg.name)
  cfg.branch = ask("  Branch", cfg.branch)
  cfg.app = ask("  App folder", cfg.app)
  cfg.token = ask("  Access token (only if private)", cfg.token, true)

  print("")
  print("2. Where your music is hosted.")
  print("   Your own repository holding songs/catalog.tbl and .dfpwm files.")
  print("   Leave blank to use the same repository as the app.")
  cfg.songsOwner = ask("  GitHub user", cfg.songsOwner)
  cfg.songsName = ask("  Repository", cfg.songsName)
  if cfg.songsOwner ~= "" and cfg.songsName ~= "" then
    cfg.songsBranch = ask("  Branch", cfg.songsBranch)
    print("   A token is needed if that repository is PRIVATE.")
    print("   Use a fine-grained token with read-only Contents access to it.")
    cfg.songsToken = ask("  Access token", cfg.songsToken, true)
  end

  local ok, saveErr = repoLib.save(cfg)
  if not ok then fail("Could not save: " .. tostring(saveErr)) end
  print("")
  print("Saved to " .. repoLib.CONFIG_FILE)
  if repoLib.isPrivate(cfg) or (cfg.songsToken or "") ~= "" then
    print("Note: that file holds your token(s) in plain text.")
  end

  io.write("Test both now? [Y/n] ")
  local answer = io.read()
  if not answer or answer:lower():sub(1, 1) ~= "n" then
    local manifest, checkErr = require("mplayer.update").check(cfg)
    if manifest then
      print("  app     OK - remote version " .. tostring(manifest.version))
    else
      print("  app     FAILED: " .. tostring(checkErr))
    end

    local catalog = require("mplayer.catalog")
    local list, listErr = catalog.fetch(cfg)
    if list then
      print(("  music   OK - %d song(s) in %s"):format(#list, catalog.origin(cfg)))
    else
      print("  music   FAILED: " .. tostring(listErr))
    end
  end
  os.exit(0)
end

if command == "update" then
  local update = require("mplayer.update")
  print("Installed version: " .. update.localVersion())
  if not update.canVerify then
    print("(sha256 library not found, checksums will not be verified)")
  end
  local result, detail = update.run(nil, function(done, total, label)
    io.write(("\r[%d/%d] %-50s"):format(done, total, label:sub(1, 50)))
  end)
  print("")
  if result == "updated" then
    print("Updated to " .. tostring(detail) .. ".")
  elseif result == "current" then
    print("Already up to date.")
  else
    fail("Update failed: " .. tostring(detail))
  end
  os.exit(0)
end

if command == "diag" then
  local component = require("component")
  local computer = require("computer")
  local cfg = repoLib.load()
  local songs = repoLib.songs(cfg)

  print("components")
  for _, name in ipairs({ "tape_drive", "internet", "gpu" }) do
    print(("  %-12s %s"):format(name, component.isAvailable(name) and "yes" or "NO"))
  end

  print("song repository")
  print(("  %s/%s  branch %s  token %s")
    :format(songs.owner, songs.name, songs.branch,
      repoLib.isPrivate(songs) and "set" or "none"))

  local catalog = require("mplayer.catalog")
  local list, listErr = catalog.fetch(cfg)
  if not list then
    print("  catalogue FAILED: " .. tostring(listErr))
    os.exit(1)
  end
  print(("  catalogue OK, %d song(s)"):format(#list))
  local entry = list[tonumber(args[2]) or 1]
  if not entry then
    print("  nothing to probe")
    os.exit(0)
  end
  print(("  probing: %s (catalogue says %s bytes)")
    :format(entry.title, tostring(entry.bytes)))

  local url, headers = catalog.source(cfg, entry)
  print("  url: " .. url)

  -- What does the card actually hand back? Every hypothesis about stalled
  -- downloads has come down to this.
  local function probe(label, extra)
    local h = {}
    for k, v in pairs(headers or {}) do h[k] = v end
    for k, v in pairs(extra or {}) do h[k] = v end

    local handle, reason = component.internet.request(url, nil, h)
    if not handle then print(("  %s: request rejected: %s"):format(label, tostring(reason))) return end

    local deadline = computer.uptime() + 30
    while true do
      local ok, connected = pcall(handle.finishConnect)
      if not ok then print(("  %s: connect error: %s"):format(label, tostring(connected))) return end
      if connected then break end
      if computer.uptime() > deadline then print("  " .. label .. ": timed out") return end
    end

    local code, message, respHeaders = handle.response()
    print(("  %s: HTTP %s %s"):format(label, tostring(code), tostring(message or "")))
    print(("    headers are a %s"):format(type(respHeaders)))
    if type(respHeaders) == "table" then
      for key, value in pairs(respHeaders) do
        local shown = type(value) == "table" and tostring(value[1]) or tostring(value)
        print(("      [%s] %s = %s"):format(type(key), tostring(key), shown))
      end
    end

    -- How much does one read actually return?
    local ok, chunk = pcall(handle.read, 8192)
    print(("    first read: %s"):format(
      not ok and ("error " .. tostring(chunk))
      or chunk == nil and "nil (end of stream)"
      or (#chunk .. " bytes")))
    pcall(handle.close)
  end

  probe("plain")
  probe("range", { ["Range"] = "bytes=1000-" })

  print("")
  print("Wanted: a Content-Length header, Accept-Ranges: bytes, HTTP 206 on")
  print("the range probe, and a first read of about 2048 bytes.")
  os.exit(0)
end

-- Everything below needs the drive -------------------------------------

if not component.isAvailable("tape_drive") then
  fail("No Computronics tape drive found. Place one next to the computer,\n" ..
       "or connect it with a cable, and put a cassette tape in it.")
end

local p, err = player.new()
if not p then fail(err) end

if not p.tape.ready and command ~= nil then
  fail("No tape in the drive.")
end

-- Interactive interface --------------------------------------------------

if command == nil then
  local ui = require("mplayer.ui")
  local ok, uiErr = pcall(ui.run, p)
  if not ok then
    -- Leave the terminal usable if the interface blew up.
    component.gpu.setBackground(0x000000)
    component.gpu.setForeground(0xFFFFFF)
    local w, h = component.gpu.getResolution()
    component.gpu.fill(1, 1, w, h, " ")
    fail("Interface error: " .. tostring(uiErr))
  end
  os.exit(0)
end

-- Batch subcommands ------------------------------------------------------

if command == "list" then
  local tracks = p:tracks()
  if #tracks == 0 then
    print("This tape has no tracks. Use: music add <url> [title]")
  else
    print(("Tape: %s   %s free of %s"):format(
      p.tape.label ~= "" and p.tape.label or "(unlabelled)",
      player.formatSize(p.tape:free()),
      player.formatSize(p.tape:capacity())))
    for i, track in ipairs(tracks) do
      print(("%2d. %-40s %6s  %s"):format(
        i, track.title, player.formatTime(track.duration),
        player.formatSize(track.length)))
    end
  end

elseif command == "play" then
  local index = tonumber(args[2]) or 1
  if not p:tracks()[index] then fail("No track " .. index .. " on this tape.") end
  p:playTrack(index)
  print(("Playing: %s"):format(p:currentTrack().title))
  p:saveConfig()

elseif command == "stop" then
  p:stop()
  print("Stopped.")

elseif command == "add" then
  local url = args[2]
  if not url then fail("Usage: music add <url> [title]") end
  local title = table.concat(args, " ", 3)
  if title == "" then
    title = url:match("([^/]+)%.dfpwm$") or url:match("([^/]+)$") or "Track"
  end

  local job, startErr = p:download(url, title)
  if not job then fail("Cannot start download: " .. tostring(startErr)) end

  io.write("Recording " .. title .. " ")
  local dots = 0
  while true do
    local state = job:step()
    if state == "done" then
      print(("\nDone: %s of audio written."):format(player.formatTime(job:seconds())))
      if job.truncated then print("Note: truncated, the tape ran out of space.") end
      break
    elseif state == "error" then
      print("")
      fail("Download failed: " .. tostring(job.error))
    end
    dots = dots + 1
    if dots % 20 == 0 then io.write(".") end
  end

elseif command == "library" then
  local catalog = require("mplayer.catalog")
  local list, listErr = catalog.fetch()
  if not list then fail("Cannot read the library: " .. tostring(listErr)) end
  if #list == 0 then
    print("The repository's songs/ folder has no songs yet.")
  else
    local onTape = {}
    for _, track in ipairs(p:tracks()) do onTape[track.title] = true end
    for i, entry in ipairs(list) do
      print(("%2d. %-44s %6s %s"):format(
        i, entry.title,
        entry.seconds and player.formatTime(entry.seconds) or "?",
        onTape[entry.title] and "(on tape)" or ""))
    end
  end

elseif command == "get" then
  local catalog = require("mplayer.catalog")
  local list, listErr = catalog.fetch()
  if not list then fail("Cannot read the library: " .. tostring(listErr)) end

  local wanted = table.concat(args, " ", 2)
  if wanted == "" then fail("Usage: music get <number or part of the title>") end

  local entry = list[tonumber(wanted) or 0]
  if not entry then
    local needle = wanted:lower()
    for _, candidate in ipairs(list) do
      if candidate.title:lower():find(needle, 1, true) then entry = candidate break end
    end
  end
  if not entry then fail("No song in the library matches " .. wanted) end

  local job, startErr = p:downloadFromCatalog(entry)
  if not job then fail("Cannot record: " .. tostring(startErr)) end

  io.write("Recording " .. entry.title .. " ")
  local ticks = 0
  while true do
    local state = job:step()
    if state == "done" then
      print(("\nDone: %s written."):format(player.formatTime(job:seconds())))
      if job.truncated then print("Note: truncated, the tape ran out of space.") end
      break
    elseif state == "error" then
      print("")
      fail("Failed: " .. tostring(job.error))
    end
    ticks = ticks + 1
    if ticks % 20 == 0 then io.write(".") end
  end

elseif command == "wipe" then
  io.write("Clear the track index on this tape? [y/N] ")
  local answer = io.read()
  if answer and answer:lower():sub(1, 1) == "y" then
    p:wipe()
    print("Index cleared. The audio bytes stay until they are overwritten.")
  else
    print("Cancelled.")
  end

else
  print("Usage:")
  print("  music                     open the player interface")
  print("  music play [n]            play track n")
  print("  music stop                stop playback")
  print("  music list                list tracks on the tape")
  print("  music add <url> [title]   record a .dfpwm URL onto the tape")
  print("  music library             list songs hosted in the repository")
  print("  music get <n|name>        record a song from the library")
  print("  music setup               configure the repository and token")
  print("  music update              pull a newer version of this app")
  print("  music diag [n]            probe the connection for song n")
  print("  music wipe                clear the tape's track index")
end

p:saveConfig()
