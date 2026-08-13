-- mplayer.update -- pull a newer version of this app from the repository.
--
-- Reads the same manifest format the NgOS app store uses
-- (/ngos/bin/store.lua), so `Music/manifest.tbl` stays valid for the store if
-- the repo is ever made public:
--
--   {
--     version = "1.1.0",
--     files = {                        -- relative to /apps/Music/
--       ["app.lua"]          = { url = "...", sha256 = "..." },
--       ["mplayer/tape.lua"] = { url = "...", sha256 = "..." },
--     },
--     system = {                       -- our addition; the store ignores it
--       ["/usr/bin/music.lua"] = { url = "...", sha256 = "..." },
--     },
--   }
--
-- The store hashes content after `gsub("\r", ""):gsub("%s+$", "")`, so we
-- normalise identically or the two would disagree about the same file.

local fs = require("filesystem")
local repo = require("mplayer.repo")

local update = {}

local APP_DIR = "/apps/Music"
local VERSION_FILE = APP_DIR .. "/version.txt"

update.APP_DIR = APP_DIR

-- sha256 ships with NgOS; under plain OpenOS it may be absent, in which case
-- we download without verifying rather than refusing to work.
local sha256
do
  local ok, lib = pcall(dofile, "/ngos/lib/sha256.lua")
  if ok and type(lib) == "table" and lib.hex then sha256 = lib end
end

update.canVerify = sha256 ~= nil

local function normalise(content)
  return (content:gsub("\r", ""):gsub("%s+$", ""))
end

function update.localVersion()
  if not fs.exists(VERSION_FILE) then return "unknown" end
  local f = io.open(VERSION_FILE, "r")
  if not f then return "unknown" end
  local v = (f:read("*l") or ""):match("^%s*(.-)%s*$")
  f:close()
  return v ~= "" and v or "unknown"
end

local function writeVersion(version)
  local f = io.open(VERSION_FILE, "w")
  if f then
    f:write(version or "unknown")
    f:close()
  end
end

--- Fetch the remote manifest.
-- @return manifest, err
function update.check(cfg)
  cfg = cfg or repo.load()
  local path = (cfg.app or "Music") .. "/manifest.tbl"
  local manifest, err = repo.getTable(cfg, path)
  if not manifest then return nil, err end
  if type(manifest.files) ~= "table" then
    return nil, "manifest has no file list"
  end
  return manifest
end

--- True when the remote manifest names a different version than the installed
--- one. Version strings are compared literally: any change means update.
function update.isNewer(manifest)
  return tostring(manifest.version or "") ~= update.localVersion()
end

local function writeFile(path, content)
  local dir = path:match("^(.*)/[^/]+$")
  if dir and dir ~= "" and not fs.exists(dir) then
    fs.makeDirectory(dir)
  end
  local f, err = io.open(path, "w")
  if not f then return nil, err end
  f:write(content)
  f:close()
  return true
end

--- Download every file in the manifest.
-- Files are fetched in full and verified before anything is written, so a
-- failure halfway through cannot leave a half-updated app on disk.
-- @param progress optional function(done, total, label)
-- @return true, count  or  nil, err
function update.apply(manifest, cfg, progress)
  cfg = cfg or repo.load()

  local jobs = {}
  for path, info in pairs(manifest.files) do
    jobs[#jobs + 1] = { target = APP_DIR .. "/" .. path, info = info, label = path }
  end
  if type(manifest.system) == "table" then
    for path, info in pairs(manifest.system) do
      jobs[#jobs + 1] = { target = path, info = info, label = path }
    end
  end
  table.sort(jobs, function(a, b) return a.label < b.label end)

  local total = #jobs
  if total == 0 then return nil, "manifest lists no files" end

  -- Pass one: fetch and verify everything in memory.
  for i, job in ipairs(jobs) do
    if progress then progress(i - 1, total, "downloading " .. job.label) end

    -- Every manifest entry carries both a public raw `url` (what the NgOS
    -- store uses) and a repo-relative `path`. Private repos must go through
    -- the authenticated API, so they use `path`.
    local body, err
    if repo.isPrivate(cfg) and job.info.path then
      body, err = repo.get(cfg, job.info.path)
    elseif job.info.url and job.info.url ~= "" then
      body, err = repo.httpGet(job.info.url, nil)
    elseif job.info.path then
      body, err = repo.get(cfg, job.info.path)
    else
      err = "manifest entry has neither url nor path"
    end

    if not body then
      return nil, ("%s: %s"):format(job.label, tostring(err))
    end

    if sha256 and job.info.sha256 and job.info.sha256 ~= "" then
      if sha256.hex(normalise(body)) ~= job.info.sha256 then
        return nil, ("%s: checksum mismatch, refusing to install"):format(job.label)
      end
    end

    job.body = body
  end

  -- Pass two: commit to disk.
  for i, job in ipairs(jobs) do
    if progress then progress(i, total, "writing " .. job.label) end
    local ok, err = writeFile(job.target, job.body)
    if not ok then
      return nil, ("%s: %s"):format(job.target, tostring(err))
    end
  end

  writeVersion(manifest.version)
  return true, total
end

--- Convenience: check and install in one call.
-- @return "updated"|"current", detail
function update.run(cfg, progress)
  cfg = cfg or repo.load()
  local manifest, err = update.check(cfg)
  if not manifest then return nil, err end

  if not update.isNewer(manifest) then
    return "current", update.localVersion()
  end

  local ok, applyErr = update.apply(manifest, cfg, progress)
  if not ok then return nil, applyErr end
  return "updated", manifest.version
end

return update
