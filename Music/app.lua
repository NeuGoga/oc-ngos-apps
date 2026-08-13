-- NgOS application entry point: /apps/Music/app.lua
--
-- The NgOS kernel loads this file with loadfile() into a sandbox and runs it
-- as a coroutine, so it must not call os.exit() and must return normally when
-- the user quits -- the kernel treats a dead coroutine as a closed app.
--
-- mplayer.rt handles the awkward part: the kernel only resumes an app when a
-- real signal arrives, which would leave a media player with no clock. So we
-- keep control and pull signals ourselves, handing back clicks that land on
-- the kernel's own minimise/close buttons.

-- The app is self-contained under /apps/Music/, the way the NgOS store
-- installs things, so its libraries are found relative to that directory.
package.path = package.path .. ";/apps/Music/?.lua;/lib/?.lua;/usr/lib/?.lua"

local component = require("component")
local gpu = component.gpu

local function abort(message)
  local w, h = gpu.getResolution()
  gpu.setBackground(0x0F0F17)
  gpu.setForeground(0xFF6E6E)
  gpu.fill(1, 1, w, h, " ")
  gpu.set(2, 2, "Tape Player cannot start")
  gpu.setForeground(0xDCDCE6)
  gpu.set(2, 4, message)
  gpu.set(2, 6, "Touch anywhere to close.")
  -- Wait for one interaction so the message is actually readable, then let
  -- the coroutine finish, which is how an NgOS app exits.
  require("computer").pullSignal(15)
end

local ok, playerLib = pcall(require, "mplayer.player")
if not ok then
  return abort("Library missing: " .. tostring(playerLib))
end

if not component.isAvailable("tape_drive") then
  return abort("No Computronics tape drive is connected.")
end

local p, err = playerLib.new()
if not p then
  return abort(tostring(err))
end

local ui = require("mplayer.ui")
local success, uiErr = pcall(ui.run, p)

if not success then
  pcall(function() p:close() end)
  return abort("Interface error: " .. tostring(uiErr))
end
