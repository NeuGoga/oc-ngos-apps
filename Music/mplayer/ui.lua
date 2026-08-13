-- mplayer.ui -- one screen: what is on the cassette, and the transport.
--
-- Input comes through mplayer.rt, so the same screen works under OpenOS and
-- under the NgOS kernel. ESC is never used as a key: Minecraft takes it to
-- open the game menu, so it never reaches the app.

local component = require("component")
local unicode = require("unicode")
local rt = require("mplayer.rt")
local tapeLib = require("mplayer.tape")
local record = require("mplayer.record")
local config = require("mplayer.config")

local ui = {}

-- Stamped by tools/make_manifest.py at release time. Baked into the source
-- rather than read from a file: this reports what is executing, which is not
-- always what was last downloaded.
local VERSION = "2.0.0" --[[VERSION]]

local gpu = component.gpu

local T = {
  bg     = 0x0F0F17,
  panel  = 0x1E1E2A,
  text   = 0xDCDCE6,
  dim    = 0x8A8A9E,
  accent = 0x66CCFF,
  ok     = 0x66CC66,
  warn   = 0xFFCC33,
  err    = 0xFF6E6E,
  black  = 0x000000,
}

local w, h

local function refreshSize() w, h = gpu.getResolution() end

local function fill(x, y, width, height, bg)
  gpu.setBackground(bg)
  gpu.fill(x, y, width, height, " ")
end

local function write(x, y, text, fg, bg)
  if y < 1 or y > h or x > w then return end
  gpu.setForeground(fg or T.text)
  gpu.setBackground(bg or T.bg)
  local room = w - x + 1
  if unicode.len(text) > room then text = unicode.sub(text, 1, room) end
  gpu.set(x, y, text)
end

local function pad(text, width)
  local len = unicode.len(text)
  if len > width then
    if width <= 1 then return unicode.sub(text, 1, width) end
    return unicode.sub(text, 1, width - 1) .. "."
  end
  return text .. string.rep(" ", width - len)
end

local function clock(seconds)
  seconds = math.max(0, math.floor(seconds or 0))
  return ("%d:%02d"):format(math.floor(seconds / 60), seconds % 60)
end

-- Screen -----------------------------------------------------------------

local State = {}
State.__index = State

function State:hit(x1, x2, y, action)
  self.hits[#self.hits + 1] = { x1 = x1, x2 = x2, y = y, action = action }
end

function State:findHit(x, y)
  for _, r in ipairs(self.hits) do
    if y == r.y and x >= r.x1 and x <= r.x2 then return r end
  end
end

local function button(state, x, y, text, action, fg)
  write(x, y, text, fg or T.text, T.panel)
  state:hit(x, x + #text - 1, y, action)
  return x + #text + 1
end

function State:draw()
  self.hits = {}
  refreshSize()
  fill(1, 1, w, h, T.bg)

  local deck = self.deck

  -- Title bar. The last two cells belong to the NgOS window buttons.
  local titleWidth = rt.ngos and (w - 2) or w
  fill(1, 1, titleWidth, 1, T.panel)
  write(2, 1, "TAPE", T.accent, T.panel)
  write(7, 1, VERSION, T.dim, T.panel)
  local server = config.configured(self.cfg)
      and (self.cfg.host .. ":" .. self.cfg.port) or "no server set"
  local sx = titleWidth - #server - 1
  if sx > 20 then write(sx, 1, server, T.dim, T.panel) end

  -- What is on the cassette.
  local title, colour
  if self.job then
    title = "Recording..."
    colour = T.warn
  elseif not deck.ready then
    title = "No cassette in the drive"
    colour = T.err
  elseif deck.label == "" then
    title = "Blank cassette (unlabelled)"
    colour = T.dim
  else
    title = deck.label
    colour = deck:isPlaying() and T.accent or T.text
  end
  write(2, 3, pad(title, w - 3), colour)

  -- Progress.
  local elapsed, total
  if self.job then
    elapsed, total = self.job:seconds(), deck:duration()
  else
    elapsed, total = deck:elapsed(), deck:duration()
  end
  local left, right = clock(elapsed), clock(total)
  local barX = 2 + #left + 1
  local barWidth = math.max(4, w - #left - #right - 5)
  local fraction = total > 0 and math.min(1, elapsed / total) or 0
  local filled = math.floor(barWidth * fraction + 0.5)

  write(2, 4, left, T.dim)
  write(barX, 4, string.rep("=", filled), self.job and T.warn or T.accent)
  write(barX + filled, 4, string.rep("-", barWidth - filled), T.dim)
  write(barX + barWidth + 1, 4, right, T.dim)

  -- Transport.
  fill(1, 6, w, 1, T.panel)
  local x = 2
  if self.job then
    x = button(self, x, 6, "[ CANCEL ]", "cancel", T.err)
  else
    x = button(self, x, 6, deck:isPlaying() and "[ STOP ]" or "[ PLAY ]", "toggle",
      deck:isPlaying() and T.warn or T.ok)
    x = button(self, x, 6, "[<< REWIND]", "rewind")
    x = button(self, x, 6, "[ RECORD ]", "record", T.err)
    x = button(self, x, 6, "[ LABEL ]", "label")
    x = button(self, x, 6, "[ SERVER ]", "server")
  end
  local vol = ("Vol:%3d%%"):format(math.floor((self.cfg.volume or 1) * 100 + 0.5))
  if x + #vol < titleWidth then button(self, titleWidth - #vol - 1, 6, vol, "volume", T.dim) end

  -- Message and hints.
  fill(1, h - 1, w, 1, T.bg)
  if self.message then write(2, h - 1, pad(self.message, w - 2), T.warn) end

  fill(1, h, w, 1, T.panel)
  local hints = self.job
      and "X cancels the recording"
      or "SPACE play/stop   W rewind   R record   L label   S server   -/+ volume   Q quit"
  write(2, h, pad(hints, w - 2), T.dim, T.panel)
end

-- Modal input ------------------------------------------------------------

function State:readLine(title, initial)
  local boxWidth = math.min(w - 6, 60)
  local x = math.floor((w - boxWidth) / 2)
  local y = math.floor(h / 2) - 2
  local text = initial or ""

  while true do
    fill(x, y, boxWidth, 5, T.panel)
    write(x + 2, y + 1, title, T.accent, T.panel)
    local inner = boxWidth - 4
    local view = text
    if unicode.len(view) >= inner then view = unicode.sub(view, unicode.len(view) - inner + 2) end
    fill(x + 2, y + 2, inner, 1, T.bg)
    write(x + 2, y + 2, view .. "_", T.text, T.bg)
    write(x + 2, y + 3, "ENTER confirm    CTRL+C cancel", T.dim, T.panel)

    local event, _, char, code = rt.pull()
    if event == "key_down" then
      if code == 28 then return text
      elseif code == 1 or char == 3 then return nil     -- ctrl+c (ESC rarely arrives)
      elseif code == 14 then text = unicode.sub(text, 1, unicode.len(text) - 1)
      elseif char and char >= 32 then text = text .. unicode.char(char) end
    elseif event == "clipboard" then
      text = text .. tostring(char or ""):gsub("[\r\n].*$", "")
    end
  end
end

-- Actions ----------------------------------------------------------------

function State:setServer()
  local host = self:readLine("Stream server host (ngrok TCP address):", self.cfg.host)
  if not host then return end
  local port = self:readLine("Port:", tostring(self.cfg.port ~= 0 and self.cfg.port or ""))
  if not port then return end

  self.cfg.host = host:match("^%s*(.-)%s*$")
  self.cfg.port = tonumber(port) or 0
  config.save(self.cfg)
  self.message = config.configured(self.cfg)
      and ("Server set to " .. self.cfg.host .. ":" .. self.cfg.port)
      or "Host and port are both needed."
end

function State:setLabel()
  if not self.deck.ready then
    self.message = "No cassette in the drive."
    return
  end
  local label = self:readLine("Cassette label (the song title):", self.deck.label)
  if not label then return end
  self.deck:setLabel(label)
  self.message = "Labelled: " .. label
end

function State:startRecording()
  if not record.available() then
    self.message = "No internet card installed."
    return
  end
  if not self.deck.ready then
    self.message = "No cassette in the drive."
    return
  end
  if not config.configured(self.cfg) then
    self.message = "Set the stream server first (S)."
    return
  end

  local job, err = record.start(self.deck, self.cfg.host, self.cfg.port)
  if not job then
    self.message = "Cannot record: " .. tostring(err)
    return
  end
  self.job = job
  self.message = "Recording over everything on this cassette..."
end

function State:doAction(action)
  local deck = self.deck
  if action == "toggle" then
    if deck:isPlaying() then
      deck:stop()
    else
      if deck:atEnd() then deck:rewind() end
      deck:setSpeed(1.0)
      deck:setVolume(self.cfg.volume)
      deck:play()
    end
  elseif action == "rewind" then deck:rewind()
  elseif action == "record" then self:startRecording()
  elseif action == "label" then self:setLabel()
  elseif action == "server" then self:setServer()
  elseif action == "cancel" then
    if self.job then
      self.job:cancel()
      self.job = nil
      self.message = "Recording cancelled."
    end
  elseif action == "volume" then
    self.cfg.volume = self.cfg.volume >= 0.999 and 0.1 or (self.cfg.volume + 0.1)
    deck:setVolume(self.cfg.volume)
    config.save(self.cfg)
  end
  self.needsRedraw = true
end

function State:onKey(char, code)
  if code == 57 then self:doAction("toggle")                 -- space
  elseif char == 119 or char == 87 then self:doAction("rewind")
  elseif char == 114 or char == 82 then self:doAction("record")
  elseif char == 108 or char == 76 then self:doAction("label")
  elseif char == 115 or char == 83 then self:doAction("server")
  elseif char == 120 or char == 88 then self:doAction("cancel")
  elseif char == 43 or char == 61 then                       -- + / =
    self.cfg.volume = math.min(1, self.cfg.volume + 0.05)
    self.deck:setVolume(self.cfg.volume); config.save(self.cfg)
  elseif char == 45 then                                     -- -
    self.cfg.volume = math.max(0, self.cfg.volume - 0.05)
    self.deck:setVolume(self.cfg.volume); config.save(self.cfg)
  elseif code == 63 then                                     -- F5
    self.deck:refresh()
    self.message = self.deck.ready and "Cassette re-read." or "No cassette in the drive."
  elseif char == 113 or char == 81 then self.running = false
  end
  self.needsRedraw = true
end

-- Main loop --------------------------------------------------------------

function ui.run(deck)
  refreshSize()
  local previousBg, previousFg = gpu.getBackground(), gpu.getForeground()

  local state = setmetatable({
    deck = deck,
    cfg = config.load(),
    hits = {},
    job = nil,
    message = nil,
    needsRedraw = true,
    running = true,
  }, State)

  deck:setVolume(state.cfg.volume)
  state:draw()

  local lastTick = 0
  while state.running do
    -- Pump a recording, and notice when it ends: that changes the screen with
    -- no input at all, so without this it would sit on "Recording..." until a
    -- key was pressed.
    if state.job then
      local result = state.job:step()
      if result == "done" then
        state.message = ("Recorded %s. Give it a label with L."):format(clock(state.job:seconds()))
        state.job = nil
        deck:refresh()
        state.needsRedraw = true
      elseif result == "error" then
        state.message = "Recording failed: " .. tostring(state.job.error)
        state.job = nil
        state.needsRedraw = true
      else
        state.message = state.job:status()
      end
    end

    local now = rt.uptime()
    if state.needsRedraw then
      state:draw()
      state.needsRedraw = false
      lastTick = now
    elseif (state.job or deck:isPlaying()) and now - lastTick >= 0.25 then
      state:draw()
      lastTick = now
    end

    local event, _, b, c = rt.pull(state.job and 0.05 or 0.25)
    if event == "key_down" then
      state:onKey(b, c)
    elseif event == "touch" then
      local hit = state:findHit(b, c)
      if hit then state:doAction(hit.action) end
    elseif event == "screen_resized" or event == "refresh" then
      state.needsRedraw = true
    elseif event == "interrupted" then
      state.running = false
    end
  end

  if state.job then state.job:cancel() end
  gpu.setBackground(previousBg)
  gpu.setForeground(previousFg)
  gpu.fill(1, 1, w, h, " ")

  -- Under NgOS this does not return: the kernel closes us.
  rt.close()
end

ui.theme = T
return ui
