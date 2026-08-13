-- NgOS application entry point: /apps/Music/app.lua
--
-- The kernel loads this with loadfile() into a sandbox and runs it as a
-- coroutine. It must not call os.exit(), and it must not simply return --
-- see mplayer.rt for why, and for how quitting is handed back to the kernel.

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
  require("computer").pullSignal(15)

  -- Returning would leave the kernel holding a dead coroutine: its launch
  -- path only checks for an error, never for one that finished.
  local ok, rt = pcall(require, "mplayer.rt")
  if ok then
    rt.close()
  else
    local width = gpu.getResolution()
    require("computer").pushSignal("touch", gpu.getScreen(), width, 1, 0)
    while true do coroutine.yield() end
  end
end

if not component.isAvailable("tape_drive") then
  return abort("No Computronics tape drive is connected.")
end

local ok, tapeLib = pcall(require, "mplayer.tape")
if not ok then
  return abort("Library missing: " .. tostring(tapeLib))
end

local deck, err = tapeLib.new()
if not deck then
  return abort(tostring(err))
end

local ui = require("mplayer.ui")
local success, uiErr = pcall(ui.run, deck)
if not success then
  return abort("Interface error: " .. tostring(uiErr))
end
