# Music — tape player for OpenComputers in GTNH

Records a song onto a Computronics cassette straight off a TCP stream, and
plays it. One song per cassette; the tape's own label is the title.

---

## Why one song per cassette

The earlier version kept a table of contents on the tape so several songs
could share one cassette, plus HTTP download machinery, a hosted catalogue and
a self-updater. Almost every bug came from that: a corrupt field in the
on-tape index was enough to set playback to quarter speed and turn music into
noise, and HTTP keep-alive meant a download could never tell when it had
finished.

One song per cassette removes both problems. There is no index to corrupt, and
the end of the song is the end of the tape — so the drive stops itself and
there is nothing to bookkeep. A socket closing is an unambiguous end of
stream.

---

## What you need

| Thing | Why |
|---|---|
| Computronics **Tape Drive** | plays and records |
| **Cassette Tape** | one per song; pick a length near the song's |
| **Internet Card** | pulls the stream |
| Screen + GPU **Tier 2 or better** | the interface wants ~70 columns |
| A PC running `stream_server.py` | converts and serves the audio |
| **Speaker** + **Audio Cable** (optional) | moves the sound elsewhere |

The tape drive goes against the computer case or on OC cable — it is a native
OpenComputers peripheral, no Adapter needed.

---

## The codec, which is the thing that catches everyone

There are **two incompatible codecs called DFPWM**:

* **DFPWM1a** — ChenThread's revision, used by CC:Tweaked, and what
  `ffmpeg -c:a dfpwm` writes.
* **DFPWM 1.0** — GreaseMonkey's 2013 original. **This** is what Computronics
  decodes, through AsieLib's `pl.asie.lib.audio.DFPWM`.

They differ in charge precision, in how the response strength moves, and 1a
adds an antijerk filter 1.0 knows nothing about. Feeding 1a to a 1.0 decoder
does not sound slightly worse — it sounds like hiss.

Measured by decoding with AsieLib's own maths:

| encoder | SNR | correlation |
|---|---|---|
| DFPWM 1.0 (`tools/dfpwm.py`) | **11.70 dB** | **+0.966** |
| ffmpeg's 1a | 2.88 dB | +0.696 |

So `stream_server.py` uses ffmpeg only to decode and filter, and compresses
with [`tools/dfpwm.py`](tools/dfpwm.py) — a direct port of AsieLib's encoder,
verified byte-identical against the compiled Java.

[LionRay](https://github.com/gamax92/LionRay/releases/) also writes 1.0, which
is why the Computronics manual recommends it.

---

## Setting up

### 1. Install the app

From the NgOS app store: open **Store**, pick **Music**, Install.

The store installs the app files only — it ignores the manifest's `system`
block — so there is no `music` shell command afterwards. That is fine; the
desktop app does everything.

### 2. Start the stream server on your PC

Needs Python 3 and ffmpeg 5.1+ (`winget install Gyan.FFmpeg`, then reopen the
terminal).

```sh
python Music/tools/stream_server.py "Artist - Title.mp3"
```

It listens on port 25999 and serves that one song to whoever connects.

### 3. Expose it to the game

OpenComputers ships `deny private` in its internet filtering rules, so the
game cannot dial `127.0.0.1` or your LAN address. A TCP tunnel is the simplest
way round it:

```sh
ngrok tcp 25999
```

That prints something like `tcp://0.tcp.ngrok.io:12345`. The host is
`0.tcp.ngrok.io` and the port is `12345`.

> While the tunnel is up, anyone who finds the address can pull the stream.
> Stop it when you are done.

### 4. Record

In game, open **Music**:

1. **S** — enter the ngrok host and port. Saved to `/etc/mplayer/stream.tbl`.
2. Put a **blank cassette** in the drive.
3. **R** — records, overwriting the whole cassette.
4. **L** — give it the song's title. That becomes the cassette's label, and it
   is how you will know what is on it later.
5. **SPACE** — play.

---

## Using it

| Key | Action |
|---|---|
| `SPACE` | play / stop |
| `W` | rewind to the start |
| `R` | record, overwriting the cassette |
| `L` | label the cassette |
| `S` | set the stream server |
| `X` | cancel a recording |
| `-` `+` | volume |
| `F5` | re-read after swapping cassettes |
| `Q` | quit |

Everything is clickable too.

ESC is deliberately unused — Minecraft takes it to open the game menu, so it
never reaches the app.

### From the shell

Only if you installed the `music` command (the store does not):

```
music                    open the player
music play | stop | rewind
music info               what is on the cassette
music label <text>       name the cassette
music server <host> <p>  where the stream server lives
music record             record, overwriting the cassette
```

---

## How much fits

Playback consumes exactly **4096 bytes per second** — one 1024-byte packet
every 250 ms, 32768 Hz at one bit per sample. So 240 KB per minute:

| Tape | Audio |
|---|---|
| 2 min | ~2 minutes |
| 8 min | ~8 minutes |
| 32 min | ~32 minutes |

Match the cassette to the song. A recording that outruns the tape stops at the
end and says so rather than failing.

### Better quality, at twice the tape

The drive's sample rate is not fixed: it declares `packetSize * 8 * 4` where
`packetSize` is `round(1024 * speed)`, so at its maximum speed of 2.0 it plays
**65536 Hz**. `stream_server.py --hq` encodes for that — twice the bandwidth
for twice the bytes, with playback set to 2.0. Not wired into the app yet.

---

## Things worth knowing

- **Recording overwrites the whole cassette.** There is nothing to append to.
- **Pause is stop.** The drive has no pause; stopping keeps the position, so
  stop-then-play resumes.
- **Transfers top out near 40 KB/s.** `read` is a non-direct call costing a
  game tick, clamped to `maxReadBuffer` (2 KB by default). Reads are batched
  and committed in one write so the write tick is not paid per chunk.
- **A silent stream fails after 30 s** rather than hanging. There is no
  resuming a socket, so it says so and stops.
- **Under NgOS** the app pulls signals itself instead of yielding after each
  event, because the kernel only resumes an app when a real signal arrives and
  a player needs a clock. Quitting hands back to the kernel rather than
  returning — the kernel's launch path never checks for a coroutine that
  finished, so returning would leave a dead one installed. See
  [`mplayer/rt.lua`](mplayer/rt.lua).

---

## Layout

```
Music/
  app.lua              NgOS entry point
  cli.lua              optional shell command
  manifest.tbl         generated: file list + sha256
  mplayer/
    rt.lua             event loop for both OpenOS and the NgOS kernel
    config.lua         stream server address, volume
    tape.lua           the drive: rewind, play, label, capacity
    record.lua         TCP socket -> cassette
    ui.lua             the screen
  tools/
    stream_server.py   PC side: ffmpeg -> DFPWM 1.0 -> socket
    dfpwm.py           the codec Computronics actually decodes
```

No audio is stored here. Songs stay on your PC and are converted on the fly.

---

## Testing

The deck and recorder are covered by 25 offline checks against a mock drive
reproducing `TapeStorage.java` semantics — the `size - position - 1` write
clamp, clamped relative seeks, empty-read versus end-of-stream, a silent
socket, a refused connection, a song longer than the cassette, and a zero-byte
stream.

The audio path is verified end to end: the streamer's real output, decoded by
the **compiled** Computronics codec, reconstructs the source at **11.02 dB
SNR** and **+0.96 correlation**.

The interface and the NgOS integration are not covered — those need a real
world.
