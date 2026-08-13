-- bootstrap -- first-time install of the Music app from the repository.
--
-- The app repository is public, so this is a one-liner:
--
--   wget https://raw.githubusercontent.com/NeuGoga/oc-ngos-apps/main/Music/bootstrap.lua
--   bootstrap
--
-- Press Enter through the first set of questions to accept those defaults.
-- The second set is where your own music lives; that one is worth filling in.
--
-- If you would rather not type any of it, the NgOS app store installs the app
-- too (Music appears in the list) -- this script exists so the shell command
-- and the configuration get set up in one go.
--
-- After this, updates are just `music update`, or U inside the app.

local component = require("component")
local fs = require("filesystem")
local serialization = require("serialization")

local CONFIG_DIR = "/etc/mplayer"
local CONFIG_FILE = CONFIG_DIR .. "/repo.tbl"
local APP_DIR = "/apps/Music"

local function fail(message)
  io.stderr:write(message .. "\n")
  os.exit(1)
end

if not component.isAvailable("internet") then
  fail("This needs an Internet Card to fetch the app.")
end

print("Music app installer")
print("===================")
print("")

-- Configuration ----------------------------------------------------------

local cfg = {
  owner = "NeuGoga", name = "oc-ngos-apps", branch = "main", token = "", app = "Music",
  songsOwner = "", songsName = "", songsBranch = "main", songsToken = "",
}
if fs.exists(CONFIG_FILE) then
  local f = io.open(CONFIG_FILE, "r")
  if f then
    local stored = serialization.unserialize(f:read("*a") or "") or {}
    f:close()
    for k, v in pairs(stored) do cfg[k] = v end
  end
end

local function ask(label, current, secret)
  local shown = secret and (current ~= "" and "set" or "none") or current
  io.write(("%s [%s]: "):format(label, shown))
  local answer = io.read()
  if answer == nil then print("") os.exit(1) end
  answer = answer:match("^%s*(.-)%s*$")
  return answer ~= "" and answer or current
end

print("Press Enter to accept the value in brackets.")
print("")
print("1. Where the app comes from (defaults are fine).")
cfg.owner = ask("  GitHub user", cfg.owner)
if cfg.owner == "" then fail("A GitHub user is required.") end
cfg.name = ask("  Repository", cfg.name)
cfg.branch = ask("  Branch", cfg.branch)
cfg.token = ask("  Access token (only if private)", cfg.token, true)

print("")
print("2. Where your music is hosted -- your own repository with")
print("   songs/catalog.tbl in it. Blank means the same repo as the app.")
cfg.songsOwner = ask("  GitHub user", cfg.songsOwner)
cfg.songsName = ask("  Repository", cfg.songsName)
if cfg.songsOwner ~= "" and cfg.songsName ~= "" then
  cfg.songsBranch = ask("  Branch", cfg.songsBranch)
  print("   A token is needed only if that repository is PRIVATE.")
  print("   Use a fine-grained token with read-only Contents access.")
  cfg.songsToken = ask("  Access token", cfg.songsToken, true)
end

if not fs.exists(CONFIG_DIR) then fs.makeDirectory(CONFIG_DIR) end
local cf = io.open(CONFIG_FILE, "w")
if not cf then fail("Cannot write " .. CONFIG_FILE) end
cf:write(serialization.serialize(cfg))
cf:close()

-- Fetching ---------------------------------------------------------------

local private = cfg.token ~= ""

-- The raw host serves private repositories too, given an Authorization
-- header, and unlike the contents API it is a real file server.
local function url(path)
  -- Spaces and accents are not legal in a URL. Explicit ASCII ranges rather
  -- than %w, whose meaning for bytes above 127 depends on the C locale.
  local encoded = path:gsub("[^A-Za-z0-9%-%._~/]", function(c)
    return ("%%%02X"):format(c:byte())
  end)
  return ("https://raw.githubusercontent.com/%s/%s/%s/%s")
    :format(cfg.owner, cfg.name, cfg.branch, encoded)
end

local function headers()
  if not private then return nil end
  return { ["Authorization"] = "token " .. cfg.token }
end

local function httpGet(path)
  local handle, reason = component.internet.request(url(path), nil, headers())
  if not handle then return nil, reason or "request rejected" end

  local deadline = require("computer").uptime() + 30
  while true do
    local ok, connected = pcall(handle.finishConnect)
    if not ok then pcall(handle.close) return nil, tostring(connected) end
    if connected then break end
    if require("computer").uptime() > deadline then
      pcall(handle.close)
      return nil, "timed out"
    end
  end

  local code, message = handle.response()
  if code and code ~= 200 then
    pcall(handle.close)
    if code == 404 then
      return nil, "404 - check the user, repo, branch, and that the token can see it"
    end
    return nil, ("HTTP %d %s"):format(code, tostring(message or ""))
  end

  local parts = {}
  while true do
    local ok, chunk = pcall(handle.read, 8192)
    if not ok then pcall(handle.close) return nil, tostring(chunk) end
    if chunk == nil then break end
    if #chunk > 0 then parts[#parts + 1] = chunk end
  end
  pcall(handle.close)
  return table.concat(parts)
end

print("")
io.write("Fetching the manifest... ")
local manifestBody, manifestErr = httpGet(cfg.app .. "/manifest.tbl")
if not manifestBody then fail("failed.\n" .. tostring(manifestErr)) end

local manifest = serialization.unserialize(manifestBody)
if type(manifest) ~= "table" or type(manifest.files) ~= "table" then
  fail("failed.\nThe manifest is not a valid table. Has make_manifest.py been run?")
end
print("version " .. tostring(manifest.version))

local jobs = {}
for rel, info in pairs(manifest.files) do
  jobs[#jobs + 1] = { target = APP_DIR .. "/" .. rel, path = info.path or (cfg.app .. "/" .. rel), label = rel }
end
if type(manifest.system) == "table" then
  for target, info in pairs(manifest.system) do
    jobs[#jobs + 1] = { target = target, path = info.path, label = target }
  end
end
table.sort(jobs, function(a, b) return a.label < b.label end)

for i, job in ipairs(jobs) do
  io.write(("[%d/%d] %s ... "):format(i, #jobs, job.label))
  local body, err = httpGet(job.path)
  if not body then fail("failed.\n" .. tostring(err)) end

  local dir = job.target:match("^(.*)/[^/]+$")
  if dir and dir ~= "" and not fs.exists(dir) then fs.makeDirectory(dir) end

  local f, openErr = io.open(job.target, "w")
  if not f then fail("failed.\n" .. tostring(openErr)) end
  f:write(body)
  f:close()
  print("ok")
end

local vf = io.open(APP_DIR .. "/version.txt", "w")
if vf then
  vf:write(tostring(manifest.version or "unknown"))
  vf:close()
end

print("")
print("Installed " .. #jobs .. " files.")
print("Run 'music' from the shell, or open Music on the NgOS desktop.")
if private or cfg.songsToken ~= "" then
  print("")
  print("Your token(s) are stored in plain text in " .. CONFIG_FILE .. ".")
end
