# Music — tape drive player for OpenComputers in GTNH

A queue-based music player for the **Computronics Tape Drive**, packaged as an
[NgOS](https://github.com/NeuGoga/oc-ngos) app. Install it from the NgOS app
store, point it at a GitHub repository of your own holding `.dfpwm` files, and
records them onto cassette tapes from the **Library** tab in game.

---

## Why the tape drive and not the sound card

The Computronics sound card is an **eight-channel synthesiser** — square,
sine, triangle and sawtooth waves plus white noise, with ADSR envelopes and
FM/AM modulation. There is no sample or PCM input. It plays chiptune; it
cannot play a recording.

The **tape drive** is the only Computronics device that plays real recorded
audio: DFPWM, 1 bit per sample, mono, 32768 Hz. Lo-fi, but unmistakably the
actual song.

A **Speaker** block is a passive transducer. It picks up an audio signal
already travelling down an **Audio Cable** and makes it audible elsewhere —
it relocates sound, it does not upgrade what generates it. Cable from the
drive to speakers is how you get music around a base.

A `.nbs` chiptune player for the sound card sits unused in
[`extras/soundcard/`](extras/soundcard/) if you ever want it.

---

## Repository layout

```
Music/
  app.lua                 NgOS entry point
  cli.lua                 installed as /usr/bin/music.lua
  bootstrap.lua           optional one-shot installer + configurator
  manifest.tbl            generated: file list + sha256
  mplayer/
    rt.lua                event loop abstraction (OpenOS vs NgOS kernel)
    repo.lua              repo coordinates, tokens, authenticated HTTP
    tape.lua              drive wrapper, absolute seek, on-tape track index
    download.lua          internet card -> tape streaming
    catalog.lua           the song list, read from your music repo
    player.lua            queue, transport, shuffle/repeat
    update.lua            self-update from manifest.tbl
    ui.lua                the interface
  extras/soundcard/       unused .nbs chiptune player
tools/
  make_manifest.py        regenerates manifest.tbl and apps.tbl
```

On the computer everything lands under `/apps/Music/`, the way the NgOS store
installs apps, plus `/usr/bin/music.lua` and `/etc/mplayer/repo.tbl`.

**Songs are not in this repository.** They live in one of yours — see
[Hosting your music](#hosting-your-music).

---

## Installing

**From the NgOS app store** — open Store on the desktop, pick **Music**,
Install. Then open Music and press **C** to enter the repository holding your
songs.

The store installs the app files only; it ignores the manifest's `system`
block, so there is no `music` shell command after a store install. Press **U**
inside the app once and it will add that too, since the updater does honour
`system`.

**Or with the shell installer**, which also sets up the `music` command and
the configuration in one go:

```
wget https://raw.githubusercontent.com/NeuGoga/oc-ngos-apps/main/Music/bootstrap.lua
bootstrap
```

Press Enter through the first set of questions (they default to this repo).
The second set is where your music lives — see below. You can redo it any time
with `music setup`.

---

## Hosting your music

Songs live in **your own** GitHub repository, not this one. It needs a
`songs/` folder and a generated index:

```
songs/
  catalog.tbl
  Aphex Twin - Xtal.dfpwm
  Boards of Canada - Roygbiv.dfpwm
```

1. Convert to DFPWM (below) and drop the files in `songs/`. The filename
   becomes the title.
2. Copy [`tools/make_manifest.py`](../tools/make_manifest.py) into that repo
   and run `python tools/make_manifest.py --catalog-only`. It writes
   `songs/catalog.tbl`, filling in each song's length from its file size.
3. Commit and push.
4. In game run `music setup` once and give it that repo. Then **TAB** to the
   Library tab, **R** to refresh, **ENTER** on a song to record it to tape.

The library marks `*` for songs already on the tape and `!` for ones too big
for the space left.

### Private music repository

Perfectly fine — give `music setup` a **fine-grained** access token
(<https://github.com/settings/tokens?type=beta>) scoped to **only** that
repository with **Contents: Read-only**. Nothing else.

It is stored in `/etc/mplayer/repo.tbl` **in plain text**, so anyone who can
reach that computer or read your world save can read it. That is why it should
be read-only and scoped to one repo. Revoke it from the same page if the world
is ever shared.

> Git keeps every version of a binary forever. A music repo will only ever
> grow, so consider it disposable — if it gets unwieldy, start a fresh one.

---

## Updating the app

Change any Lua file here, then from the repository root:

```sh
python tools/make_manifest.py --version 1.1.0 --skip-catalog
git add -A && git commit -m "Music 1.1.0" && git push
```

In game, press **U** inside the app or run `music update`, then **close and
reopen the app**. The header shows the running version — if it has not changed,
the update has not taken effect.

> NgOS runs every app in one Lua state and nothing ever clears
> `package.loaded`. Before 1.0.10 an update wrote the new files, updated
> `version.txt` so it reported success, and then went on running the modules
> already cached — only rebooting the computer picked it up. The updater now
> drops its own cached modules, so reopening the app is enough. It compares the
manifest version against `/apps/Music/version.txt`, and downloads and verifies
everything **before** writing anything, so a failure halfway through cannot
leave a half-updated app on disk.

Checksums are sha256 over the file content after `gsub("
", "")` and
stripping trailing whitespace — byte-identical to what `/ngos/bin/store.lua`
computes, so `manifest.tbl` works for both the store and the in-app updater.

> The store ignores the `system` block that puts `music` on the PATH, but the
> updater does not — so pressing **U** after a store install adds the shell
> command.

---

## Converting audio

**Do not use ffmpeg's dfpwm encoder.** There are two incompatible codecs of
that name, and picking the wrong one is the difference between music and
noise:

* **DFPWM1a** — ChenThread's revision, used by CC:Tweaked, and what
  `ffmpeg -c:a dfpwm` writes.
* **DFPWM 1.0** — GreaseMonkey's 2013 original, which is what Computronics
  decodes through AsieLib's `pl.asie.lib.audio.DFPWM`.

They differ in charge precision, in how the response strength moves, and 1a
adds an antijerk filter 1.0 knows nothing about. Decoding the same excerpt
with AsieLib's own maths, 1.0 reconstructs at **11.70 dB** SNR against 1a's
**2.88 dB**.

Converters that produce the right thing:

* [LionRay](https://github.com/gamax92/LionRay/releases/) — what the
  Computronics manual recommends, and now you know why.
* [music.madefor.cc](https://music.madefor.cc/) — web converter that targets
  Computronics.
* The `tools/` folder of a song repository set up for this app, which uses
  ffmpeg to decode and filter and then compresses with its own 1.0 encoder.

### How much fits

Playback consumes exactly **4096 bytes per second** — one 1024-byte packet
every 250 ms. So `file size / 4096 = seconds`, and a 3:30 song is about
860 KB. Tapes run 2–128 minutes (~0.5 MB to ~31.5 MB); the last 2048 bytes
hold the track index.

If a file is much larger than that formula predicts, the sample rate is wrong
— re-encode with `-ar 32768 -ac 1`.

---

## Hardware

| Thing | Why |
|---|---|
| Computronics **Tape Drive** | plays the audio |
| **Cassette Tape** (2–128 min) | holds the audio |
| **Internet Card** | downloads songs and app updates |
| Screen + GPU **Tier 2 or better** | the interface wants ~70 columns |
| **Speaker** + **Audio Cable** (optional) | moves the sound elsewhere |

Put the tape drive against the computer case or run OC cable to it — it is a
native OpenComputers peripheral, no Adapter needed. Right-click it to insert a
tape. Check both parts are visible with `lua` then:

```lua
for address, kind in require("component").list() do print(kind, address) end
```

You want `tape_drive` and `internet`.

> The internet card needs `enableHttp` on in the OpenComputers config, and
> custom headers (`enableHttpHeaders`, on by default) for a private repo.

---

## Using it

```
 TAPE  Queue  Library  [Mixtape]              28.4 MB free of 31.5 MB
 > Aphex Twin - Xtal
 1:07 ====================------------------------------------ 4:44
 [<<] [ || ] [>>] [#]  Shuf:on  Rep:all  Vol: 80%  Spd:1.00x  [+ Add from URL]

  > 1. Aphex Twin - Xtal                              4:44       x
    2. Boards of Canada - Roygbiv                     2:31       x
```

| Key | Action |
|---|---|
| `TAB` | switch Queue / Library |
| `SPACE` | play / pause |
| `N` / `P` | next / previous track |
| `←` `→` | skip 5 seconds |
| `↑` `↓` `ENTER` | move selection; play it (Queue) or record it (Library) |
| `A` | record from a typed URL |
| `D` | remove the selected track from the tape index |
| `X` | cancel a recording in progress |
| `R` | repeat mode (Queue) / refresh the list (Library) |
| `S` | shuffle |
| `-` `+` | volume |
| `[` `]` | tape speed 0.25×–2× (pitch and tempo together) |
| `C` | set the song repository and access token |
| `G` | connection report, when a recording misbehaves |
| `U` | update the app from the repository |
| `W` | clear the whole track index |
| `F5` | re-read the tape after swapping it |
| `Q` | quit |

Everything is clickable too: tabs, transport buttons, the progress bar, and
rows (click once to select, again to act).

### From the shell

```
music                     open the interface
music list                tracks on the tape
music play 3              play track 3
music stop                stop
music add <url> [title]   record a .dfpwm URL onto the tape
music library             songs hosted in the repository
music get <n|name>        record one of them onto the tape
music setup               reconfigure repository and token
music diag [n]            probe the connection for song n
music update              pull a newer version of the app
music wipe                clear the tape's track index
```

---

## How the tape is laid out

Audio packs from byte 0 upwards; each recording starts where the last ended.
The **last 2048 bytes** hold a plain-text table of contents:

```
MPTAPE1
2
0 8683520 Aphex Twin - Xtal
8683520 11640832 Boards of Canada - Roygbiv
```

The index sits at the *end* on purpose: DFPWM has no framing, so non-audio
bytes at the start would play as a burst of noise if someone hit play
manually. Because it lives on the tape, a tape carries its playlist to any
other computer running this app. A blank or foreign tape reads as having no
tracks.

**Deleting** a track only removes its index entry. The bytes stay until
overwritten, and only space above the last remaining track is reused — so
removing a middle track does not free that space. Use `W` and re-record when
a tape gets patchy.

---

## Things worth knowing

- **Pause is stop.** The drive has no pause; stopping keeps the head position,
  so stop-then-play resumes exactly where it was.
- **Recording stops playback** — both use the single tape head.
- **Transfers top out near 40 KB/s**, and that is a hard ceiling. `read` is a
  non-direct call, so it costs a game tick, and OpenComputers clamps it to
  `maxReadBuffer` — 2 KB by default. Twenty ticks a second times 2 KB is the
  whole budget. Reads are batched and committed to the tape in one write so
  the write tick is not paid per chunk; a 3 minute song takes roughly half a
  minute.
- **A transfer finishes on Content-Length, not on end-of-stream.** The card
  only raises end-of-stream when the socket closes, and a keep-alive
  connection may never close — waiting for it alone hangs at 100%, then tries
  to "resume" past the end of the file forever.
- **Files always come from `raw.githubusercontent.com`**, public or private —
  the raw host takes an `Authorization` header for private repositories. The
  contents API works too, but it is not a file server: it ignores `Range` and
  answers 200 with the whole file, so a resume there silently restarts from
  zero and a flaky download can never converge. The raw host advertises
  `Accept-Ranges: bytes` and answers 206 properly.
- **A dropped connection resumes itself.** The internet card fills its response
  queue from a background thread and only raises end-of-stream when that
  thread finishes cleanly; if the connection dies mid-transfer the flag is
  never set and `read()` returns empty forever, so a naive loop hangs at
  whatever percentage it reached. A transfer that goes quiet for 12 seconds is
  treated as broken and reopened with an HTTP `Range` request from the byte it
  stopped at, up to four times. If the server ignores the range and replies
  200, the counter resets rather than double-counting.
- **ESC never reaches the app** — Minecraft takes it to open the game menu. So
  `X` cancels a recording and `Ctrl+C` dismisses a prompt.
- **Speed changes pitch.** It is a tape. Listed times update when you change
  it.
- **Under NgOS** the app pulls signals itself instead of yielding after each
  event, because the kernel only resumes an app when a real signal arrives and
  a media player needs a clock. Clicks on the kernel's own minimise and close
  buttons are pushed back and handed over, so the window controls still work.
- **Quitting hands back to the kernel** rather than returning. NgOS apps are
  not written to return — the desktop and the store both loop on
  `coroutine.yield()` forever and are closed by the title bar button. The
  kernel's launch path resumes a new app and only checks `if not ok`, never
  whether the coroutine finished, so an app that returns leaves a dead
  coroutine installed as the active process and the next key press reports
  "App Crashed". `Q` therefore synthesises the same click the close button
  produces. Both behaviours live in [`mplayer/rt.lua`](mplayer/rt.lua).

---

## Testing

`tape.lua`, `download.lua` and `player.lua` were exercised offline against a
mock drive reproducing `TapeStorage.java` semantics — including the
`size - position - 1` write clamp and zero-padded reads — covering the index
round trip, seek clamping, HTTP failures, empty-vs-EOF reads, running out of
tape mid-download, and the shuffle/repeat state machine. 92 checks.

The interface and the NgOS integration have not been covered by those
tests — they need a real world to exercise.
