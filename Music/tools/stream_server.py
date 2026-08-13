#!/usr/bin/env python3
"""Serve one song to the in-game Music app, converted on the fly.

    python stream_server.py "Artist - Title.mp3"
    python stream_server.py song.mp3 --port 25999 --hq

Then in game: set the server address once, put a blank cassette in the drive,
and press R.

How it works
------------

ffmpeg decodes and filters the source into 8-bit signed mono PCM; this script
compresses that to DFPWM and writes it down a TCP socket. When the song ends
the socket is closed, which is how the client knows it is finished -- a plain
socket has an unambiguous end, unlike an HTTP response that may be kept alive.

Why not `ffmpeg -c:a dfpwm`
---------------------------

Because that writes DFPWM**1a**, and Computronics decodes DFPWM **1.0**
through AsieLib. They are different codecs. Measured by decoding with
AsieLib's own maths, 1.0 material reconstructs at 11.70 dB SNR against 2.88 dB
for 1a -- the difference between music and hiss. So ffmpeg only decodes and
filters here, and tools/dfpwm.py does the compression.

Reaching your PC from Minecraft
-------------------------------

OpenComputers ships `deny private` in its internet filtering rules, so the
game cannot dial 127.0.0.1 or your LAN address without a config change. The
simplest way round it is a TCP tunnel:

    ngrok tcp 25999

which prints something like `tcp://0.tcp.ngrok.io:12345`. Give the app that
host and port. Anyone who finds the address can pull the stream while it is
running, so stop the tunnel when you are done.
"""

from __future__ import annotations

import argparse
import os
import shutil
import socket
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dfpwm

# The drive consumes packetSize bytes every 250 ms, where packetSize is
# round(1024 * speed): 4096 B/s at speed 1.0, which is 32768 samples of one
# bit each. At the maximum speed of 2.0 it plays 65536 Hz -- twice the
# bandwidth for twice the tape, which is what --hq encodes for.
NATIVE_RATE = 32768
HQ_RATE = 65536


def filter_chain(rate: int) -> str:
    """Pre-processing a one-bit delta coder can actually cope with.

    It slews towards the signal at a fixed rate, so sharp treble outruns it
    (heard as hiss), subsonic rumble wastes slew on nothing audible, and quiet
    passages sit low in a fixed noise floor. Rolling off both ends and
    levelling the dynamics is worth more than any encoder setting.
    """
    cutoff = 7000 if rate <= NATIVE_RATE else 12000
    return (f"highpass=f=40,lowpass=f={cutoff},"
            "dynaudnorm=f=200:g=15:p=0.9,alimiter=limit=0.95")


def find_ffmpeg() -> str:
    found = shutil.which("ffmpeg")
    if found:
        return found
    local = os.environ.get("LOCALAPPDATA")
    if local:
        packages = Path(local) / "Microsoft" / "WinGet" / "Packages"
        if packages.is_dir():
            for exe in packages.glob("Gyan.FFmpeg*/**/bin/ffmpeg.exe"):
                return str(exe)
    sys.exit("ffmpeg not found.  winget install Gyan.FFmpeg  (then reopen the terminal)")


def encode_stream(ffmpeg: str, source: Path, rate: int, raw: bool, variant: str):
    """Yield DFPWM chunks for `source`, converting as we go.

    A .dfpwm input is passed through untouched -- it is already encoded, and
    re-encoding one-bit audio into one-bit audio only adds noise.
    """
    if source.suffix.lower() == ".dfpwm":
        with source.open("rb") as f:
            while True:
                chunk = f.read(65536)
                if not chunk:
                    return
                yield chunk
        return

    command = [ffmpeg, "-hide_banner", "-loglevel", "error", "-i", str(source), "-vn"]
    if not raw:
        command += ["-af", filter_chain(rate)]
    command += ["-ac", "1", "-ar", str(rate), "-f", "s8", "-"]

    # One codec context for the whole song: both variants are stateful, and
    # restarting mid-song would audibly glitch.
    codec = dfpwm.DFPWM1a() if variant == "1a" else dfpwm.DFPWM()
    leftover = b""

    proc = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        while True:
            pcm = proc.stdout.read(65536)
            if not pcm:
                break
            pcm = leftover + pcm
            # compress() emits one byte per 8 samples, so feed whole groups.
            usable = len(pcm) - (len(pcm) % 8)
            leftover = pcm[usable:]
            if usable:
                yield bytes(codec.compress(pcm[:usable]))
    finally:
        proc.stdout.close()
        proc.wait()


def stream_song(conn, ffmpeg, source, rate, raw, variant) -> int:
    sent = 0
    for chunk in encode_stream(ffmpeg, source, rate, raw, variant):
        conn.sendall(chunk)
        sent += len(chunk)
    return sent


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("song", help="any file ffmpeg can read, or a .dfpwm to serve as-is")
    parser.add_argument("--port", type=int, default=25999)
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--hq", action="store_true",
                        help="encode at 65536 Hz; needs playback at speed 2.0")
    parser.add_argument("--raw", action="store_true", help="skip the filter chain")
    parser.add_argument("--once", action="store_true", help="exit after one song")
    parser.add_argument("--codec", choices=("1.0", "1a"), default="1.0",
                        help="1.0 is what Computronics decodes; 1a is ffmpeg's")
    parser.add_argument("--out", metavar="FILE",
                        help="write the encoded file and exit, instead of serving")
    args = parser.parse_args()

    source = Path(args.song)
    if not source.is_file():
        sys.exit(f"No such file: {source}")

    ffmpeg = find_ffmpeg()
    rate = HQ_RATE if args.hq else NATIVE_RATE

    if args.out:
        total = 0
        with open(args.out, "wb") as f:
            for chunk in encode_stream(ffmpeg, source, rate, args.raw, args.codec):
                f.write(chunk)
                total += len(chunk)
        seconds = total / (rate / 8)
        print(f"Wrote {args.out}")
        print(f"  {total/1048576:.2f} MB  {int(seconds)//60}:{int(seconds)%60:02d}  "
              f"{rate} Hz  DFPWM {args.codec}")
        return

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((args.host, args.port))
    server.listen(1)

    passthrough = source.suffix.lower() == ".dfpwm"
    print(f"Serving  {source.name}")
    if passthrough:
        print("         already encoded - passing the bytes through untouched")
    else:
        print(f"         {rate} Hz{'  (HQ - play at speed 2.0)' if args.hq else ''}, "
              f"DFPWM {args.codec}")
    print(f"Listening on {args.host}:{args.port}")
    print("Expose it with:  ngrok tcp %d" % args.port)
    print("Waiting for the computer to connect...  (Ctrl+C to stop)")

    try:
        while True:
            conn, peer = server.accept()
            print(f"\n  {peer[0]} connected - streaming...")
            try:
                bytes_sent = stream_song(conn, ffmpeg, source, rate, args.raw, args.codec)
                seconds = bytes_sent / (rate / 8)
                print(f"  sent {bytes_sent/1048576:.2f} MB "
                      f"({int(seconds)//60}:{int(seconds)%60:02d} of audio)")
            except (BrokenPipeError, ConnectionResetError):
                print("  the computer disconnected early")
            finally:
                # Closing is the client's end-of-song signal.
                conn.close()
                print("  connection closed")
            if args.once:
                break
    except KeyboardInterrupt:
        print("\nStopped.")
    finally:
        server.close()


if __name__ == "__main__":
    main()
