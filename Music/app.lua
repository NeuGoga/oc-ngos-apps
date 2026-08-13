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
  -- Wait for one interaction so the message can be read, then ask the kernel
  -- to close us. Returning instead would leave it holding a dead coroutine --
  -- its launch path never checks for one -- and the next key press would
  -- report "App Crashed".
  require("computer").pullSignal(15)
  local ok, rt = pcall(require, "mplayer.rt")
  if ok then
    rt.close()
  else
    -- rt is what failed to load; do its job inline.
    local width = gpu.getResolution()
    require("computer").pushSignal("touch", gpu.getScreen(), width, 1, 0)
    while true do coroutine.yield() end
  end
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
