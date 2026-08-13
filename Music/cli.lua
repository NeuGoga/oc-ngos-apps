-- music -- Computronics tape player, one song per cassette.
--
--   music                    open the player
--   music play               play the cassette from where it stopped
--   music stop               stop
--   music rewind             back to the start
--   music info               what is on the cassette
--   music label <text>       name the cassette (its song title)
--   music server <host> <p>  where the stream server lives
--   music record             record a song onto the cassette, overwriting it

package.path = package.path .. ";/apps/Music/?.lua;/lib/?.lua;/usr/lib/?.lua"

local component = require("component")
local tapeLib = require("mplayer.tape")
local config = require("mplayer.config")

local args = { ... }
local command = args[1]

local function fail(message)
  io.stderr:write(message .. "\n")
  os.exit(1)
end

local function clock(seconds)
  seconds = math.max(0, math.floor(seconds or 0))
  return ("%d:%02d"):format(math.floor(seconds / 60), seconds % 60)
end

-- Configuration needs no hardware.
if command == "server" then
  local cfg = config.load()
  if not args[2] then
    print(config.configured(cfg)
      and ("Stream server: %s:%d"):format(cfg.host, cfg.port)
      or "No stream server set. Usage: music server <host> <port>")
    os.exit(0)
  end
  cfg.host = args[2]
  cfg.port = tonumber(args[3]) or 0
  local ok, err = config.save(cfg)
  if not ok then fail("Could not save: " .. tostring(err)) end
  print(("Stream server set to %s:%d"):format(cfg.host, cfg.port))
  os.exit(0)
end

if not component.isAvailable("tape_drive") then
  fail("No Computronics tape drive found. Put one against the computer,\n" ..
       "or connect it with cable, and insert a cassette.")
end

local deck, err = tapeLib.new()
if not deck then fail(err) end

if command ~= nil and not deck.ready then
  fail("No cassette in the drive.")
end

if command == nil then
  local ui = require("mplayer.ui")
  local ok, uiErr = pcall(ui.run, deck)
  if not ok then
    component.gpu.setBackground(0x000000)
    component.gpu.setForeground(0xFFFFFF)
    local w, h = component.gpu.getResolution()
    component.gpu.fill(1, 1, w, h, " ")
    fail("Interface error: " .. tostring(uiErr))
  end
  os.exit(0)
end

if command == "info" then
  print(("Label:    %s"):format(deck.label ~= "" and deck.label or "(none)"))
  print(("Capacity: %.1f MB, %s of audio"):format(deck:capacity() / 1048576, clock(deck:duration())))
  print(("Position: %s"):format(clock(deck:elapsed())))
  print(("State:    %s"):format(deck:state()))

elseif command == "play" then
  if deck:atEnd() then deck:rewind() end
  deck:setSpeed(1.0)
  deck:setVolume(config.load().volume)
  deck:play()
  print("Playing " .. (deck.label ~= "" and deck.label or "unlabelled cassette"))

elseif command == "stop" then
  deck:stop()
  print("Stopped at " .. clock(deck:elapsed()))

elseif command == "rewind" then
  deck:rewind()
  print("Rewound.")

elseif command == "label" then
  local label = table.concat(args, " ", 2)
  if label == "" then fail("Usage: music label <text>") end
  deck:setLabel(label)
  print("Labelled: " .. label)

elseif command == "record" then
  local record = require("mplayer.record")
  local cfg = config.load()
  if not config.configured(cfg) then
    fail("No stream server set. Usage: music server <host> <port>")
  end

  io.write(("Recording from %s:%d - this overwrites the cassette. Continue? [y/N] ")
    :format(cfg.host, cfg.port))
  local answer = io.read()
  if not answer or answer:lower():sub(1, 1) ~= "y" then
    print("Cancelled.")
    os.exit(0)
  end

  local job, startErr = record.start(deck, cfg.host, cfg.port)
  if not job then fail("Cannot record: " .. tostring(startErr)) end

  local ticks = 0
  while true do
    local state = job:step()
    if state == "done" then
      print(("\nRecorded %s (%.1f MB)."):format(clock(job:seconds()), job.written / 1048576))
      if job.truncated then print("Note: the cassette ran out before the song ended.") end
      print("Give it a name with: music label <title>")
      break
    elseif state == "error" then
      print("")
      fail("Recording failed: " .. tostring(job.error))
    end
    ticks = ticks + 1
    if ticks % 16 == 0 then io.write("\r" .. job:status() .. "        ") end
  end

else
  print("Usage:")
  print("  music                    open the player")
  print("  music play | stop | rewind")
  print("  music info               what is on the cassette")
  print("  music label <text>       name the cassette")
  print("  music server <host> <p>  where the stream server lives")
  print("  music record             record a song, overwriting the cassette")
end
