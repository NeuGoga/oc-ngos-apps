-- mplayer.repo -- talking to the GitHub repository this app lives in.
--
-- Holds the repo coordinates plus an optional token, and does blocking HTTP
-- fetches. Two URL shapes are supported:
--
--   public  https://raw.githubusercontent.com/<owner>/<name>/<branch>/<path>
--   private https://api.github.com/repos/<owner>/<name>/contents/<path>?ref=<branch>
--           with  Authorization: token <pat>
--                 Accept: application/vnd.github.raw
--
-- The API form returns the raw bytes for files up to 100 MB, which covers
-- both the Lua sources and the .dfpwm music. Custom headers need
-- `enableHttpHeaders` left on in the OpenComputers config; it is on by
-- default.

local component = require("component")
local computer = require("computer")
local fs = require("filesystem")
local serialization = require("serialization")

local repo = {}

local CONFIG_DIR = "/etc/mplayer"
local CONFIG_FILE = CONFIG_DIR .. "/repo.tbl"

repo.CONFIG_FILE = CONFIG_FILE

-- The app comes from the public NgOS app repository, so the defaults work
-- with no configuration at all. Songs are a separate matter: they are yours,
-- and they do not belong in someone else's app repo, so they get their own
-- coordinates. Leave songsOwner blank to keep them alongside the app.
local DEFAULTS = {
  owner = "NeuGoga",
  name = "oc-ngos-apps",
  branch = "main",
  token = "",
  app = "Music",

  songsOwner = "",
  songsName = "",
  songsBranch = "main",
  songsToken = "",
}

function repo.load()
  local cfg = {}
  for k, v in pairs(DEFAULTS) do cfg[k] = v end
  if fs.exists(CONFIG_FILE) then
    local f = io.open(CONFIG_FILE, "r")
    if f then
      local stored = serialization.unserialize(f:read("*a") or "") or {}
      f:close()
      for k, v in pairs(stored) do cfg[k] = v end
    end
  end
  return cfg
end

function repo.save(cfg)
  if not fs.exists(CONFIG_DIR) then fs.makeDirectory(CONFIG_DIR) end
  local f, err = io.open(CONFIG_FILE, "w")
  if not f then return nil, err end
  f:write(serialization.serialize(cfg))
  f:close()
  return true
end

function repo.configured(cfg)
  return cfg and cfg.owner ~= "" and cfg.name ~= ""
end

function repo.isPrivate(cfg)
  return cfg.token ~= nil and cfg.token ~= ""
end

--- Coordinates for wherever the music is hosted.
-- Falls back to the app repository when no separate one is configured, so a
-- single-repo setup still works.
function repo.songs(cfg)
  cfg = cfg or repo.load()
  if not cfg.songsOwner or cfg.songsOwner == ""
      or not cfg.songsName or cfg.songsName == "" then
    return cfg
  end
  return {
    owner = cfg.songsOwner,
    name = cfg.songsName,
    branch = (cfg.songsBranch and cfg.songsBranch ~= "") and cfg.songsBranch or "main",
    token = cfg.songsToken or "",
    app = cfg.app,
  }
end

--- URL for a path inside the repository (e.g. "Music/manifest.tbl").
function repo.fileUrl(cfg, path)
  if repo.isPrivate(cfg) then
    return ("https://api.github.com/repos/%s/%s/contents/%s?ref=%s")
      :format(cfg.owner, cfg.name, path, cfg.branch)
  end
  return ("https://raw.githubusercontent.com/%s/%s/%s/%s")
    :format(cfg.owner, cfg.name, cfg.branch, path)
end

--- Headers needed for this repo, or nil when it is public.
function repo.headers(cfg)
  if not repo.isPrivate(cfg) then return nil end
  return {
    ["Authorization"] = "token " .. cfg.token,
    ["Accept"] = "application/vnd.github.raw",
  }
end

--- Blocking HTTP GET. Fine for manifests and config; music goes through
--- mplayer.download instead so it can stream straight onto the tape.
function repo.httpGet(url, headers, timeout)
  if not component.isAvailable("internet") then
    return nil, "no internet card installed"
  end

  local handle, reason = component.internet.request(url, nil, headers)
  if not handle then return nil, reason or "request rejected" end

  local deadline = computer.uptime() + (timeout or 30)
  while true do
    local ok, connected = pcall(handle.finishConnect)
    if not ok then
      pcall(handle.close)
      return nil, tostring(connected)
    end
    if connected then break end
    if computer.uptime() > deadline then
      pcall(handle.close)
      return nil, "timed out connecting"
    end
  end

  local code, message = handle.response()
  if code and code ~= 200 then
    pcall(handle.close)
    if code == 404 then
      return nil, "404 not found (wrong path, branch, or the token cannot see this repo)"
    elseif code == 401 or code == 403 then
      return nil, ("%d - the token was rejected or lacks access"):format(code)
    end
    return nil, ("HTTP %d %s"):format(code, tostring(message or ""))
  end

  local parts = {}
  while true do
    local ok, chunk = pcall(handle.read, 8192)
    if not ok then
      pcall(handle.close)
      return nil, tostring(chunk)
    end
    if chunk == nil then break end
    if #chunk > 0 then parts[#parts + 1] = chunk end
    if computer.uptime() > deadline then
      pcall(handle.close)
      return nil, "timed out reading"
    end
  end
  pcall(handle.close)

  return table.concat(parts)
end

--- Fetch a repo file as a string.
function repo.get(cfg, path)
  if not repo.configured(cfg) then
    return nil, "repository is not configured yet"
  end
  return repo.httpGet(repo.fileUrl(cfg, path), repo.headers(cfg))
end

--- Fetch and unserialize one of the .tbl files.
function repo.getTable(cfg, path)
  local body, err = repo.get(cfg, path)
  if not body then return nil, err end
  local value = serialization.unserialize(body)
  if type(value) ~= "table" then
    return nil, path .. " is not a valid table"
  end
  return value
end

return repo
