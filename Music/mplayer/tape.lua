-- mplayer.tape -- Computronics tape drive, one song per cassette.
--
-- Facts taken from the mod source rather than the wiki
-- (TileTapeDrive.java, TapeDriveState.java, TapeStorage.java):
--
--   * A tape is a flat byte array. The drive holds one position; read(),
--     write() and seek() all move it.
--   * seek(n) is RELATIVE and clamped to [0, size-1], returning how far it
--     actually moved. Rewinding is therefore just seek(-size).
--   * Playback emits one packet of `packetSize` bytes every 250 ms, where
--     packetSize = round(1024 * speed). At speed 1.0 that is exactly
--     4096 bytes per second (32768 Hz, one bit per sample).
--   * TapeStorage.write clamps to size - position - 1, silently, so the last
--     byte is never writable and an overrun is not reported. Callers must
--     watch getPosition() instead of trusting their own counter.
--   * The drive has no pause. stop() keeps the position, so stop-then-play
--     resumes where it left off.
--
-- Deliberately no table of contents. One cassette holds one song, its title
-- is the tape's own label, and the end of the song is the end of the tape --
-- so the drive stops itself and there is nothing to bookkeep. The previous
-- design kept an index on the tape and a corrupt field in it was enough to
-- make playback unintelligible.

local component = require("component")

local tape = {}

local Deck = {}
Deck.__index = Deck

-- Bytes of audio consumed per second at speed 1.0.
local BYTES_PER_SECOND = 4096
tape.BYTES_PER_SECOND = BYTES_PER_SECOND

function tape.available()
  return component.isAvailable("tape_drive")
end

--- Bind to a tape drive. `address` is optional.
function tape.new(address)
  if not component.isAvailable("tape_drive") then
    return nil, "no Computronics tape drive found"
  end
  local drive = address and component.proxy(address) or component.tape_drive

  local self = setmetatable({ drive = drive }, Deck)
  self:refresh()
  return self
end

--- Re-read presence, size and label. Call after swapping a cassette.
function Deck:refresh()
  self.ready = self.drive.isReady()
  if not self.ready then
    self.size, self.label = 0, nil
    return false
  end
  self.size = self.drive.getSize()
  self.label = self.drive.getLabel() or ""
  return true
end

--- Writable bytes. The last one is unreachable, see TapeStorage.write.
function Deck:capacity()
  if not self.ready then return 0 end
  return math.max(0, self.size - 1)
end

function Deck:position()
  return self.drive.getPosition()
end

function Deck:state()
  return self.drive.getState()
end

function Deck:isPlaying()
  return self:state() == "PLAYING"
end

--- Seconds of audio the whole cassette holds.
function Deck:duration()
  return self:capacity() / BYTES_PER_SECOND
end

--- Seconds played so far.
function Deck:elapsed()
  return self:position() / BYTES_PER_SECOND
end

--- Back to the very start. seek clamps, so overshooting is safe and exact.
function Deck:rewind()
  self.drive.stop()
  self.drive.seek(-self.size)
  return self:position()
end

function Deck:play()
  return self.drive.play()
end

--- The drive has no pause; stopping keeps the position.
function Deck:stop()
  self.drive.stop()
end

function Deck:setLabel(label)
  self.drive.setLabel(label)
  self.label = label
end

function Deck:setSpeed(speed)
  speed = math.max(0.25, math.min(2.0, speed))
  self.drive.setSpeed(speed)
  return speed
end

function Deck:setVolume(volume)
  volume = math.max(0, math.min(1, volume))
  self.drive.setVolume(volume)
  return volume
end

--- Has playback reached the end of the cassette?
-- The drive stops itself there, so "stopped and not at the start" is the
-- signal. isEnd() alone is true for a stopped-anywhere-near-the-end tape.
function Deck:atEnd()
  return self:position() >= self:capacity() - BYTES_PER_SECOND
end

return tape
