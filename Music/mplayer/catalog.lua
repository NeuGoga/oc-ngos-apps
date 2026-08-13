-- mplayer.catalog -- the library of songs hosted in the repository.
--
-- `songs/catalog.tbl` in the repo lists what is available:
--
--   {
--     { title = "Artist - Song", file = "songs/song.dfpwm", seconds = 212 },
--     ...
--   }
--
-- tools/make_manifest.py regenerates it from whatever .dfpwm files are in
-- songs/, filling in `seconds` from the file size (4096 bytes per second), so
-- adding a song is: drop the file in, run the tool, commit.
--
-- Entries are handed to mplayer.download, which streams them onto the tape
-- without ever staging them on the computer's disk.

local repo = require("mplayer.repo")

local catalog = {}

local CATALOG_PATH = "songs/catalog.tbl"

--- Fetch the catalog listing.
-- Songs come from repo.songs(), which is your own repository unless you host
-- them alongside the app.
-- @return array of { title, file, seconds, bytes }, or nil plus an error
function catalog.fetch(cfg)
  local songs = repo.songs(cfg)
  local list, err = repo.getTable(songs, CATALOG_PATH)
  if not list then return nil, err end

  local out = {}
  for _, entry in ipairs(list) do
    if type(entry) == "table" and entry.file then
      out[#out + 1] = {
        title = entry.title or entry.file:match("([^/]+)%.dfpwm$") or entry.file,
        file = entry.file,
        seconds = tonumber(entry.seconds),
        bytes = tonumber(entry.bytes),
      }
    end
  end
  table.sort(out, function(a, b) return a.title:lower() < b.title:lower() end)
  return out
end

--- Where to download a catalog entry from, and with which headers.
function catalog.source(cfg, entry)
  local songs = repo.songs(cfg)
  return repo.fileUrl(songs, entry.file), repo.headers(songs)
end

--- "owner/name" of the song host, for showing in the interface.
function catalog.origin(cfg)
  local songs = repo.songs(cfg)
  return songs.owner .. "/" .. songs.name
end

return catalog
