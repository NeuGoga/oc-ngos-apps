-- mplayer.rt -- runtime abstraction.
--
-- The player has to run in two very different environments:
--
--   * plain OpenOS, where `event.pull` gives us real timers, and
--   * NgOS (github.com/NeuGoga/oc-ngos), whose kernel runs each app as a
--     coroutine and resumes it with whatever `computer.pullSignal` returned.
--
-- The NgOS kernel never forwards timeouts (it only resumes an app when a real
-- signal arrived), so an app that simply yields can never wake itself up to
-- push the next chunk of audio.  Instead we keep control and pull signals
-- ourselves -- the kernel is blocked inside `coroutine.resume` while we do,
-- so nobody else is competing for the queue.  The one thing we owe the kernel
-- is its title bar: a click on the last two cells of row 1 is pushed back and
-- followed by a yield, letting it minimise or close us as usual.

local computer = require("computer")
local component = require("component")

local rt = {}

local unpack = table.unpack or _G.unpack

rt.ngos = _G.ngos ~= nil

local event
if not rt.ngos then
  event = require("event")
end

function rt.uptime()
  return computer.uptime()
end

-- True for clicks that belong to the NgOS window decorations.
local function isOverlayTouch(sig)
  if sig[1] ~= "touch" then return false end
  local w = component.gpu.getResolution()
  return sig[4] == 1 and sig[3] >= w - 1
end

--- Quit, the way the kernel expects.
--
-- NgOS apps are not written to return. The desktop and the store both sit in
-- `while true do coroutine.yield() end` and are closed by the kernel's title
-- bar button. That is not just convention: the kernel's launch path resumes a
-- new app and only checks `if not ok`, never whether the coroutine finished
-- (the event path checks both). Since this app keeps control for its whole
-- life inside that first resume, returning normally leaves the kernel holding
-- a dead coroutine as the active process, and the next key press reports
-- "App Crashed: cannot resume dead coroutine".
--
-- So instead of returning, synthesise the click the close button produces and
-- hand over. The kernel tears us down exactly as it would any other app.
function rt.close()
  if not rt.ngos then return end

  local gpu = component.gpu
  local width = gpu.getResolution()
  computer.pushSignal("touch", gpu.getScreen(), width, 1, 0)

  -- Park. The kernel handles that click itself rather than forwarding it, so
  -- this never resumes; the loop only guards against a stray wake-up.
  while true do
    coroutine.yield()
  end
end

--- Wait for the next signal.
-- @param timeout seconds to wait, or nil to wait forever
-- @return the signal (name, ...), or nil on timeout
function rt.pull(timeout)
  if not rt.ngos then
    return event.pull(timeout)
  end

  local deadline = timeout and (computer.uptime() + timeout) or nil
  while true do
    local remaining = math.huge
    if deadline then
      remaining = deadline - computer.uptime()
      if remaining <= 0 then return nil end
    end

    local sig = table.pack(computer.pullSignal(remaining))
    if sig[1] == nil then
      if deadline then return nil end
    elseif isOverlayTouch(sig) then
      -- Give the click back to the kernel and let it act on it.  If it
      -- minimises us we stay suspended here until the user picks us again,
      -- at which point the kernel resumes with "refresh".
      computer.pushSignal(unpack(sig, 1, sig.n))
      local resumed = table.pack(coroutine.yield())
      if resumed[1] ~= nil then
        return unpack(resumed, 1, resumed.n)
      end
      return "refresh"
    else
      return unpack(sig, 1, sig.n)
    end
  end
end

return rt
