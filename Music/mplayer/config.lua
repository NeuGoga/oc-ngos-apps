-- mplayer.config -- where the stream server lives, and the volume.
--
-- Small enough to be a table on disk. The recorder needs a host and port; the
-- rest is remembered convenience.

local fs = require("filesystem")
local serialization = require("serialization")

local config = {}

local DIR = "/etc/mplayer"
local FILE = DIR .. "/stream.tbl"

config.FILE = FILE

local DEFAULTS = {
  host = "",
  port = 0,
  volume = 1.0,
}

function config.load()
  local cfg = {}
  for k, v in pairs(DEFAULTS) do cfg[k] = v end
  if fs.exists(FILE) then
    local f = io.open(FILE, "r")
    if f then
      local stored = serialization.unserialize(f:read("*a") or "") or {}
      f:close()
      for k, v in pairs(stored) do cfg[k] = v end
    end
  end
  cfg.port = tonumber(cfg.port) or 0
  cfg.volume = tonumber(cfg.volume) or 1.0
  return cfg
end

function config.save(cfg)
  if not fs.exists(DIR) then fs.makeDirectory(DIR) end
  local f, err = io.open(FILE, "w")
  if not f then return nil, err end
  f:write(serialization.serialize({
    host = cfg.host or "",
    port = tonumber(cfg.port) or 0,
    volume = tonumber(cfg.volume) or 1.0,
  }))
  f:close()
  return true
end

function config.configured(cfg)
  return cfg and cfg.host ~= "" and (tonumber(cfg.port) or 0) > 0
end

return config
