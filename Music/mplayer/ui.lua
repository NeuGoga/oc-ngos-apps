-- mplayer.ui -- terminal UI for the tape player.
--
-- Drives both entry points. Input comes through mplayer.rt, so the exact same
-- screen works under OpenOS (real event timers) and under the NgOS kernel
-- (where we pull signals ourselves and hand the window buttons back).

local component = require("component")
local unicode = require("unicode")
local rt = require("mplayer.rt")
local player = require("mplayer.player")
local download = require("mplayer.download")

local ui = {}

-- Stamped by tools/make_manifest.py at release time. Baked into the source on
-- purpose rather than read from version.txt: that file records what was last
-- downloaded, this records what is actually executing, and when a stale module
-- is still cached those are not the same thing.
local VERSION = "1.1.2" --[[VERSION]]

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
  sel    = 0x2E4A6E,
  black  = 0x000000,
  white  = 0xFFFFFF,
}

-- Drawing helpers --------------------------------------------------------

local w, h

local function refreshSize()
  w, h = gpu.getResolution()
end

local function fill(x, y, width, height, bg)
  gpu.setBackground(bg)
  gpu.fill(x, y, width, height, " ")
end

local function write(x, y, text, fg, bg)
  if y < 1 or y > h or x > w then return end
  gpu.setForeground(fg or T.text)
  gpu.setBackground(bg or T.bg)
  local room = w - x + 1
  if unicode.len(text) > room then
    text = unicode.sub(text, 1, room)
  end
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

local function bar(x, y, width, fraction, fg, bg)
  fraction = math.max(0, math.min(1, fraction or 0))
  local filled = math.floor(width * fraction + 0.5)
  write(x, y, string.rep("=", filled), fg, bg)
  write(x + filled, y, string.rep("-", width - filled), T.dim, bg)
end

-- Screen -----------------------------------------------------------------

-- Rows reserved above and below the list.
local HEADER_ROWS = 5
local FOOTER_ROWS = 2

local State = {}
State.__index = State

local function newState(p)
  return setmetatable({
    p = p,
    view = "queue",             -- "queue" (the tape) | "library" (the repo)
    selected = { queue = 1, library = 1 },
    scroll = { queue = 0, library = 0 },
    library = nil,              -- catalog entries, fetched on first use
    libraryError = nil,
    hits = {},                  -- clickable regions, rebuilt every draw
    needsRedraw = true,
    running = true,
  }, State)
end

--- Entries shown in the current view.
function State:items()
  if self.view == "library" then return self.library or {} end
  return self.p:tracks()
end

function State:sel(value)
  if value ~= nil then self.selected[self.view] = value end
  return self.selected[self.view]
end

function State:scr(value)
  if value ~= nil then self.scroll[self.view] = value end
  return self.scroll[self.view]
end

--- Fetch the repository's song catalog. Blocking, so paint a note first.
function State:loadLibrary(force)
  if self.library and not force then return end
  local repo = require("mplayer.repo")
  local catalog = require("mplayer.catalog")

  local cfg = repo.load()
  local songs = repo.songs(cfg)
  if not repo.configured(songs) then
    self.library, self.libraryError =
      {}, "No song repository set yet. Press C to enter it."
    return
  end

  fill(1, HEADER_ROWS, w, 1, T.bg)
  write(3, HEADER_ROWS,
    "Fetching the song list from " .. catalog.origin(cfg) .. " ...", T.dim)

  local list, err = catalog.fetch(cfg)
  self.library = list or {}
  self.libraryError = err
end

function State:hit(x1, x2, y, action, arg)
  self.hits[#self.hits + 1] = { x1 = x1, x2 = x2, y = y, action = action, arg = arg }
end

function State:findHit(x, y)
  for _, r in ipairs(self.hits) do
    if y == r.y and x >= r.x1 and x <= r.x2 then return r end
  end
  return nil
end

function State:listHeight()
  return math.max(1, h - HEADER_ROWS - FOOTER_ROWS)
end

function State:draw()
  local p = self.p
  self.hits = {}
  refreshSize()

  fill(1, 1, w, h, T.bg)

  -- Title bar. The last two cells belong to the NgOS window buttons.
  local titleWidth = rt.ngos and (w - 2) or w
  fill(1, 1, titleWidth, 1, T.panel)
  local label = p.tape.ready and (p.tape.label ~= "" and p.tape.label or "unlabelled tape")
      or "no tape"
  write(2, 1, "TAPE", T.accent, T.panel)
  write(7, 1, VERSION, T.dim, T.panel)

  local x = 8 + #VERSION
  for _, tab in ipairs({ { "queue", "Queue" }, { "library", "Library" } }) do
    local active = self.view == tab[1]
    local text = " " .. tab[2] .. " "
    write(x, 1, text, active and T.black or T.dim, active and T.accent or T.panel)
    self:hit(x, x + #text - 1, 1, "view", tab[1])
    x = x + #text
  end

  write(x + 1, 1, "[" .. label .. "]", T.dim, T.panel)

  if p.tape.ready then
    -- A track is only indexed once it finishes, so count what a running
    -- recording has already laid down or the tape looks untouched.
    local free = p.tape:free() - (p.job and p.job.written or 0)
    local usage = ("%s free of %s"):format(
      player.formatSize(math.max(0, free)), player.formatSize(p.tape:capacity()))
    local ux = titleWidth - #usage - 1
    if ux > x + #label + 4 then write(ux, 1, usage, T.dim, T.panel) end
  end

  self:drawNowPlaying()
  self:drawControls()
  self:drawList()
  self:drawFooter()
end

function State:drawNowPlaying()
  local p = self.p
  local track = p:currentTrack()

  local title
  if p.job then
    title = "Recording: " .. p.job.title
  elseif track then
    title = track.title
  else
    title = "-"
  end

  local marker = p.state == "playing" and ">" or p.state == "paused" and "||" or "#"
  write(2, 2, marker .. " " .. pad(title, math.max(1, w - 5)),
    p.state == "stopped" and T.dim or T.text)

  -- Progress line
  local elapsed, total, fraction
  if p.job then
    elapsed = p.job:seconds()
    fraction = p.job:progress()
    total = fraction and (elapsed / math.max(fraction, 0.001)) or nil
  else
    elapsed = p:position()
    total = p:duration()
    fraction = total > 0 and (elapsed / total) or 0
  end

  local left = player.formatTime(elapsed)
  local right = total and player.formatTime(total) or "?:??"
  local barX = 2 + #left + 1
  local barWidth = math.max(4, w - #left - #right - 5)

  write(2, 3, left, T.dim)
  if p.job and not fraction then
    -- No Content-Length: show activity rather than a fake percentage.
    write(barX, 3, pad("downloading...", barWidth), T.warn)
  else
    bar(barX, 3, barWidth, fraction, p.job and T.warn or T.accent)
    if not p.job then
      self:hit(barX, barX + barWidth - 1, 3, "seek", { x = barX, width = barWidth })
    end
  end
  write(barX + barWidth + 1, 3, right, T.dim)
end

local function button(state, x, y, text, action, arg, fg)
  write(x, y, text, fg or T.text, T.panel)
  state:hit(x, x + #text - 1, y, action, arg)
  return x + #text + 1
end

function State:drawControls()
  local p = self.p
  fill(1, 4, w, 1, T.panel)

  local x = 2
  x = button(self, x, 4, "[<<]", "prev")
  x = button(self, x, 4, p.state == "playing" and "[ || ]" or "[ >  ]", "toggle",
    nil, p.state == "playing" and T.warn or T.ok)
  x = button(self, x, 4, "[>>]", "next")
  x = button(self, x, 4, "[#]", "stop")
  x = x + 1

  x = button(self, x, 4, "Shuf:" .. (p.shuffle and "on " or "off"), "shuffle", nil,
    p.shuffle and T.ok or T.dim)
  x = button(self, x, 4, "Rep:" .. pad(p.repeatMode, 3), "repeat", nil,
    p.repeatMode ~= "off" and T.ok or T.dim)

  x = button(self, x, 4, ("Vol:%3d%%"):format(math.floor(p.volume * 100 + 0.5)), "volume")
  x = button(self, x, 4, ("Spd:%.2fx"):format(p.speed), "speed")

  if download.available() then
    local text = "[+ Add from URL]"
    if x + #text < w - 1 then
      button(self, w - #text - 1, 4, text, "add", nil, T.accent)
    else
      button(self, x, 4, "[+URL]", "add", nil, T.accent)
    end
  end
end

function State:clampScroll()
  local count = #self:items()
  local height = self:listHeight()
  local selected, scroll = self:sel(), self:scr()

  if selected < 1 then selected = math.min(1, count) end
  if selected > count then selected = count end
  if selected > 0 then
    if selected <= scroll then
      scroll = selected - 1
    elseif selected > scroll + height then
      scroll = selected - height
    end
  end
  local maxScroll = math.max(0, count - height)
  if scroll > maxScroll then scroll = maxScroll end
  if scroll < 0 then scroll = 0 end

  self:sel(selected)
  self:scr(scroll)
end

function State:drawList()
  local top = HEADER_ROWS
  local height = self:listHeight()
  self:clampScroll()
  fill(1, top, w, height, T.bg)

  if self.view == "library" then
    return self:drawLibrary(top, height)
  end
  return self:drawQueue(top, height)
end

function State:drawQueue(top, height)
  local p = self.p
  local tracks = p:tracks()

  if #tracks == 0 then
    local msg = p.tape.ready
        and "This tape is empty. TAB opens the library, or press A for a URL."
        or "No tape in the drive. Insert one and press F5."
    write(3, top + 1, msg, T.dim)
    return
  end

  local playing = p:currentTrackIndex()
  local scroll, selected = self:scr(), self:sel()

  for row = 1, height do
    local i = row + scroll
    local track = tracks[i]
    if not track then break end
    local y = top + row - 1

    local bg = (i == selected) and T.sel or T.bg
    local fg = (i == playing) and T.accent or T.text
    fill(1, y, w, 1, bg)

    local time = player.formatTime(track.duration)
    local hq = (track.rate or 32768) > 32768
    local titleWidth = math.max(4, w - #time - 15)

    write(2, y, (i == playing) and ">" or " ", T.accent, bg)
    write(4, y, ("%2d."):format(i), T.dim, bg)
    write(8, y, pad(track.title, titleWidth), fg, bg)
    if hq then write(8 + titleWidth + 1, y, "HQ", T.ok, bg) end
    write(8 + titleWidth + 4, y, time, T.dim, bg)
    write(w - 1, y, "x", T.err, bg)

    self:hit(1, w - 3, y, "select", i)
    self:hit(w - 1, w - 1, y, "delete", i)
  end
end

function State:drawLibrary(top, height)
  if self.libraryError then
    write(3, top + 1, pad(self.libraryError, w - 4), T.err)
    write(3, top + 3, "C sets the repository.   R re-fetches the list.", T.dim)
    return
  end
  local items = self.library or {}
  if #items == 0 then
    write(3, top + 1, "No songs in the repository's songs/ folder yet.", T.dim)
    write(3, top + 3, "Add .dfpwm files there, run tools/make_manifest.py, push.", T.dim)
    return
  end

  -- Which titles are already on the tape, so nothing gets recorded twice.
  local onTape = {}
  for _, track in ipairs(self.p:tracks()) do onTape[track.title] = true end

  local scroll, selected = self:scr(), self:sel()
  local free = self.p.tape.ready and self.p.tape:free() or 0

  for row = 1, height do
    local i = row + scroll
    local entry = items[i]
    if not entry then break end
    local y = top + row - 1

    local bg = (i == selected) and T.sel or T.bg
    fill(1, y, w, 1, bg)

    local time = entry.seconds and player.formatTime(entry.seconds) or "  ?  "
    local hq = (entry.rate or 32768) > 32768
    local titleWidth = math.max(4, w - #time - 17)

    local mark, fg
    if onTape[entry.title] then
      mark, fg = "*", T.dim          -- already recorded
    elseif entry.bytes and entry.bytes > free then
      mark, fg = "!", T.warn         -- will not fit on what is left
    else
      mark, fg = " ", T.text
    end

    write(2, y, mark, fg, bg)
    write(4, y, ("%2d."):format(i), T.dim, bg)
    write(8, y, pad(entry.title, titleWidth), fg, bg)
    if hq then write(8 + titleWidth + 1, y, "HQ", T.ok, bg) end
    write(8 + titleWidth + 4, y, time, T.dim, bg)

    self:hit(1, w - 1, y, "select", i)
  end
end

function State:drawFooter()
  local p = self.p
  local y = h - 1

  fill(1, y, w, 1, T.bg)
  if p.message then
    write(2, y, pad(p.message, w - 2), T.warn)
  end

  fill(1, h, w, 1, T.panel)
  local hints
  if p.job then
    hints = "X cancels the recording"
  elseif self.view == "library" then
    hints = "TAB queue  ENTER record  R refresh  C repo  G diagnose  U update  Q quit   (* on tape)"
  else
    hints = "SPACE play/pause  N/P track  ENTER play  TAB library  D delete  A URL  S shuffle  C setup  G diagnose  Q quit"
  end
  write(2, h, pad(hints, w - 2), T.dim, T.panel)
end

-- Modal input ------------------------------------------------------------

--- Draw a centred box and read a line of text. Returns nil if cancelled.
--- Modal line editor. `secret` masks the text, for access tokens.
function State:readLine(title, initial, secret)
  local boxWidth = math.min(w - 6, 70)
  local x = math.floor((w - boxWidth) / 2)
  local y = math.floor(h / 2) - 2

  local text = initial or ""
  local cursor = unicode.len(text) + 1

  while true do
    fill(x, y, boxWidth, 5, T.panel)
    write(x + 2, y + 1, title, T.accent, T.panel)

    local inner = boxWidth - 4
    local shown = secret and string.rep("*", unicode.len(text)) or text
    local view = shown
    local offset = 0
    if unicode.len(view) >= inner then
      offset = unicode.len(view) - inner + 1
      view = unicode.sub(view, offset + 1)
    end
    fill(x + 2, y + 2, inner, 1, T.bg)
    write(x + 2, y + 2, view, T.text, T.bg)

    local cursorX = x + 2 + (cursor - 1 - offset)
    if cursorX >= x + 2 and cursorX < x + 2 + inner then
      local under = unicode.sub(shown, cursor, cursor)
      write(cursorX, y + 2, under ~= "" and under or " ", T.black, T.accent)
    end
    write(x + 2, y + 3, "ENTER confirm    CTRL+C cancel", T.dim, T.panel)

    local event, _, char, code = rt.pull()
    if event == "key_down" then
      if code == 28 then            -- enter
        return text
      elseif code == 1 or char == 3 then   -- escape (rarely arrives) or ctrl+c
        return nil
      elseif code == 14 then        -- backspace
        if cursor > 1 then
          text = unicode.sub(text, 1, cursor - 2) .. unicode.sub(text, cursor)
          cursor = cursor - 1
        end
      elseif code == 211 then       -- delete
        text = unicode.sub(text, 1, cursor - 1) .. unicode.sub(text, cursor + 1)
      elseif code == 203 then       -- left
        cursor = math.max(1, cursor - 1)
      elseif code == 205 then       -- right
        cursor = math.min(unicode.len(text) + 1, cursor + 1)
      elseif code == 199 then       -- home
        cursor = 1
      elseif code == 207 then       -- end
        cursor = unicode.len(text) + 1
      elseif char and char >= 32 then
        text = unicode.sub(text, 1, cursor - 1) .. unicode.char(char) .. unicode.sub(text, cursor)
        cursor = cursor + 1
      end
    elseif event == "clipboard" then
      local paste = tostring(char or ""):gsub("[\r\n].*$", "")
      text = unicode.sub(text, 1, cursor - 1) .. paste .. unicode.sub(text, cursor)
      cursor = cursor + unicode.len(paste)
    elseif event == "refresh" then
      self:draw()
    end
  end
end

--- Yes/no box.
function State:confirm(question)
  local boxWidth = math.min(w - 6, 60)
  local x = math.floor((w - boxWidth) / 2)
  local y = math.floor(h / 2) - 1

  fill(x, y, boxWidth, 4, T.panel)
  write(x + 2, y + 1, pad(question, boxWidth - 4), T.text, T.panel)
  write(x + 2, y + 2, "Y confirm    N cancel", T.dim, T.panel)

  while true do
    local event, _, char, code = rt.pull()
    if event == "key_down" then
      if char == 121 or char == 89 then return true end   -- y / Y
      if char == 110 or char == 78 or code == 1 or char == 3 then return false end
      return false
    end
  end
end

-- Actions ----------------------------------------------------------------

--- Configure the song repository from inside the app.
-- The NgOS store installs the app files only; it ignores the manifest's
-- `system` block, so a store install has no `music` command to run setup
-- with. This is the way in for those installs.
function State:configure()
  local repo = require("mplayer.repo")
  local cfg = repo.load()

  local owner = self:readLine("Songs: GitHub user", cfg.songsOwner ~= "" and cfg.songsOwner or cfg.owner)
  self.needsRedraw = true
  if not owner then return end

  local name = self:readLine("Songs: repository", cfg.songsName ~= "" and cfg.songsName or cfg.name)
  self.needsRedraw = true
  if not name then return end

  local branch = self:readLine("Songs: branch", cfg.songsBranch ~= "" and cfg.songsBranch or "main")
  self.needsRedraw = true
  if not branch then return end

  local token = self:readLine("Songs: access token (blank if public)", cfg.songsToken or "", true)
  self.needsRedraw = true
  if not token then return end

  cfg.songsOwner = owner:match("^%s*(.-)%s*$")
  cfg.songsName = name:match("^%s*(.-)%s*$")
  cfg.songsBranch = branch:match("^%s*(.-)%s*$")
  cfg.songsToken = token:match("^%s*(.-)%s*$")

  local ok, err = repo.save(cfg)
  if not ok then
    self.p.message = "Could not save: " .. tostring(err)
    return
  end

  self.p.message = "Saved to " .. repo.CONFIG_FILE .. " - fetching the song list..."
  self:draw()

  self.view = "library"
  self:loadLibrary(true)
  if self.libraryError then
    self.p.message = "Saved, but: " .. self.libraryError
  else
    self.p.message = ("Saved. %d song(s) available."):format(#(self.library or {}))
  end
end

--- Full screen connection report. NgOS boots straight into the desktop, so
--- there is not necessarily a shell to run `music diag` from.
function State:diagnose()
  fill(1, 1, w, h, T.bg)
  write(2, 1, "Probing the connection...", T.accent)

  local ok, lines = pcall(function()
    return require("mplayer.diag").report(nil, self.view == "library" and self:sel() or 1)
  end)
  if not ok then
    lines = { "Diagnostics failed:", tostring(lines) }
  end

  local top = 0
  while true do
    fill(1, 1, w, h, T.bg)
    fill(1, 1, w, 1, T.panel)
    write(2, 1, "CONNECTION REPORT", T.accent, T.panel)
    write(w - 26, 1, "up/down scroll   Q close", T.dim, T.panel)

    local rows = h - 2
    for row = 1, rows do
      local line = lines[row + top]
      if not line then break end
      local colour = T.text
      if line:match("^%u[%u ]+$") then colour = T.accent
      elseif line:find("NO") or line:find("FAILED") or line:find("failed")
          or line:find("rejected") or line:find("error") then colour = T.err
      elseif line:sub(1, 4) == "    " then colour = T.dim end
      write(2, row + 1, line, colour)
    end

    if #lines > rows then
      write(2, h, ("line %d-%d of %d"):format(top + 1,
        math.min(top + rows, #lines), #lines), T.dim, T.panel)
    end

    local event, _, char, code = rt.pull()
    if event == "key_down" then
      if code == 200 then top = math.max(0, top - 1)
      elseif code == 208 then top = math.min(math.max(0, #lines - (h - 2)), top + 1)
      elseif code == 201 then top = math.max(0, top - (h - 2))
      elseif code == 209 then top = math.min(math.max(0, #lines - (h - 2)), top + (h - 2))
      else return end
    elseif event == "touch" then
      return
    end
  end
end

function State:startDownload()
  local p = self.p
  if not download.available() then
    p.message = "No internet card installed."
    return
  end
  if not p.tape.ready then
    p.message = "No tape in the drive."
    return
  end

  local url = self:readLine("URL of a .dfpwm file:", "http://")
  self.needsRedraw = true
  if not url or url == "" or url == "http://" then return end

  local suggestion = url:match("([^/]+)%.dfpwm$") or url:match("([^/]+)$") or "Track"
  suggestion = suggestion:gsub("%%20", " "):sub(1, 48)
  local title = self:readLine("Track title:", suggestion)
  self.needsRedraw = true
  if not title or title == "" then return end

  local job, err = p:download(url, title)
  if not job then
    p.message = "Cannot start: " .. tostring(err)
  else
    p.message = "Connecting..."
  end
end

function State:deleteTrack(i)
  local p = self.p
  local track = p:tracks()[i]
  if not track then return end
  if self:confirm(("Remove \"%s\" from the index?"):format(track.title)) then
    local ok, err = p:removeTrack(i)
    p.message = ok and "Removed. Space is reused by the next recording."
        or ("Could not remove: " .. tostring(err))
  end
  self.needsRedraw = true
end

function State:doAction(action, arg, clickX)
  local p = self.p

  if action == "toggle" then p:toggle()
  elseif action == "next" then p:next(false)
  elseif action == "prev" then p:prev()
  elseif action == "stop" then p:stop()
  elseif action == "shuffle" then p:toggleShuffle()
  elseif action == "repeat" then p:cycleRepeat()
  elseif action == "volume" then
    -- Clicking cycles up in tenths and wraps round rather than muting.
    p:setVolume(p.volume >= 0.999 and 0.1 or (p.volume + 0.1))
  elseif action == "speed" then
    local next = p.speed + 0.25
    if next > 2.0 then next = 0.25 end
    p:setSpeed(next)
  elseif action == "add" then self:startDownload()
  elseif action == "delete" then self:deleteTrack(arg)
  elseif action == "view" then
    self.view = arg
    if arg == "library" then self:loadLibrary() end
  elseif action == "select" then
    -- First click selects, a second click on the same row acts on it.
    local wasSelected = (self:sel() == arg)
    self:sel(arg)
    if wasSelected then self:activate() end
  elseif action == "seek" then
    local fraction = (clickX - arg.x) / math.max(1, arg.width - 1)
    if p.state ~= "stopped" then
      p.tape:seekWithinTrack(p:duration() * fraction)
    end
  end
  self.needsRedraw = true
end

--- Act on the highlighted row: play it, or record it onto the tape.
function State:activate()
  if self.view == "library" then
    local entry = (self.library or {})[self:sel()]
    if not entry then return end
    local job, err = self.p:downloadFromCatalog(entry)
    if not job then
      self.p.message = "Cannot record: " .. tostring(err)
    else
      self.p.message = "Recording " .. entry.title .. " ..."
      self.view = "queue"
    end
  else
    if self.p:tracks()[self:sel()] then self.p:playTrack(self:sel()) end
  end
end

function State:runUpdate()
  local update = require("mplayer.update")
  local p = self.p
  p.message = "Checking for updates..."
  self:draw()

  local result, detail = update.run(nil, function(done, total, label)
    fill(1, h - 1, w, 1, T.bg)
    write(2, h - 1, pad(("[%d/%d] %s"):format(done, total, label), w - 2), T.dim)
  end)

  if result == "updated" then
    p.message = "Updated to " .. tostring(detail)
      .. " - close and reopen the app. The header shows the running version."
  elseif result == "current" then
    p.message = "Already up to date (" .. tostring(detail) .. ")."
  else
    p.message = "Update failed: " .. tostring(detail)
  end
end

function State:onKey(char, code)
  local p = self.p

  -- View-specific keys first, so they can shadow the global ones.
  if code == 15 then                                   -- tab
    self.view = (self.view == "queue") and "library" or "queue"
    if self.view == "library" then self:loadLibrary() end
    self.needsRedraw = true
    return
  elseif char == 117 or char == 85 then                -- u
    self:runUpdate()
    self.needsRedraw = true
    return
  elseif char == 99 or char == 67 then                 -- c
    self:configure()
    self.needsRedraw = true
    return
  elseif char == 103 or char == 71 then                -- g: diagnostics
    self:diagnose()
    self.needsRedraw = true
    return
  elseif self.view == "library" then
    if char == 114 or char == 82 then                  -- r: refresh the list
      self:loadLibrary(true)
    elseif code == 28 then                             -- enter: record
      self:activate()
    elseif code == 200 then self:sel(self:sel() - 1)
    elseif code == 208 then self:sel(self:sel() + 1)
    elseif code == 201 then self:sel(self:sel() - self:listHeight())
    elseif code == 209 then self:sel(self:sel() + self:listHeight())
    elseif char == 113 or char == 81 then self.running = false
    elseif char == 120 or char == 88 then                -- x: cancel recording
      if p.job then
        p.job:cancel(); p.job = nil
        p.message = "Recording cancelled."
      end
    elseif code == 57 then p:toggle()
    end
    self.needsRedraw = true
    return
  end

  if code == 57 then p:toggle()                       -- space
  elseif char == 110 or char == 78 then p:next(false) -- n
  elseif char == 112 or char == 80 then p:prev()      -- p
  elseif char == 115 or char == 83 then p:toggleShuffle()
  elseif char == 114 or char == 82 then p:cycleRepeat()
  elseif char == 97 or char == 65 then self:startDownload()
  elseif char == 100 or char == 68 then self:deleteTrack(self:sel())
  elseif char == 113 or char == 81 then self.running = false
  elseif char == 43 or char == 61 then p:nudgeVolume(0.05)   -- + / =
  elseif char == 45 then p:nudgeVolume(-0.05)                -- -
  elseif char == 91 then p:setSpeed(p.speed - 0.25)          -- [
  elseif char == 93 then p:setSpeed(p.speed + 0.25)          -- ]
  elseif char == 119 or char == 87 then                      -- w
    if self:confirm("Clear the whole track index on this tape?") then
      p:wipe()
      p.message = "Index cleared."
    end
  elseif code == 200 then self:sel(self:sel() - 1)           -- up
  elseif code == 208 then self:sel(self:sel() + 1)           -- down
  elseif code == 201 then self:sel(self:sel() - self:listHeight()) -- page up
  elseif code == 209 then self:sel(self:sel() + self:listHeight()) -- page down
  elseif code == 28 then self:activate()                     -- enter
  elseif code == 205 then p:skip(5)                          -- right
  elseif code == 203 then p:skip(-5)                         -- left
  elseif code == 63 then                                     -- F5
    p:refresh()
    p.message = p.tape.ready and "Tape re-read." or "No tape in the drive."
  elseif char == 120 or char == 88 then                      -- x
    if p.job then
      p.job:cancel()
      p.job = nil
      p.message = "Recording cancelled."
    end
  end
  self.needsRedraw = true
end

-- Main loop --------------------------------------------------------------

--- Run the interface until the user quits.
function ui.run(p)
  refreshSize()
  local previousBg, previousFg = gpu.getBackground(), gpu.getForeground()
  local state = newState(p)

  if p:trackCount() > 0 then state:sel(1) end
  state:draw()

  local lastTick = 0
  while state.running do
    -- Pump playback / downloads, then repaint if anything moved. A recording
    -- that finishes changes state without any input, so notice that here or
    -- the screen sits on "Recording..." until the user presses something.
    local hadJob = p.job ~= nil
    local wasState = p.state
    p:update()
    if (p.job ~= nil) ~= hadJob or p.state ~= wasState then
      state.needsRedraw = true
    end

    local now = rt.uptime()
    if state.needsRedraw then
      state:draw()
      state.needsRedraw = false
      lastTick = now
    elseif p.state == "playing" or p.job then
      -- Cheap partial refresh of the transport line only.
      if now - lastTick >= 0.25 then
        state:drawNowPlaying()
        lastTick = now
      end
    end

    local timeout = p:timeUntilUpdate()
    if timeout <= 0 then timeout = 0.05 end
    if timeout > 0.25 then timeout = 0.25 end

    -- touch:    name, address, x, y, button
    -- key_down: name, address, char, code
    -- scroll:   name, address, x, y, direction
    local event, _, b, c, d = rt.pull(timeout)
    if event == "key_down" then
      state:onKey(b, c)
    elseif event == "touch" then
      local hit = state:findHit(b, c)
      if hit then state:doAction(hit.action, hit.arg, b) end
    elseif event == "scroll" then
      state:scr(state:scr() - (d or 0) * 2)
      state.needsRedraw = true
    elseif event == "screen_resized" or event == "refresh" then
      refreshSize()
      state.needsRedraw = true
    elseif event == "interrupted" then
      state.running = false
    end
  end

  p:close()
  gpu.setBackground(previousBg)
  gpu.setForeground(previousFg)
  gpu.fill(1, 1, w, h, " ")

  -- Under NgOS this does not return: the kernel closes us. Under OpenOS it is
  -- a no-op and control goes back to the shell.
  rt.close()
end

ui.theme = T
return ui
