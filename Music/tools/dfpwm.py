"""DFPWM 1.0 — the variant Computronics actually decodes.

There are two incompatible codecs called DFPWM. ffmpeg implements **DFPWM1a**
(ChenThread's 1a revision, which CC:Tweaked uses). Computronics decodes
through AsieLib's `pl.asie.lib.audio.DFPWM`, which is GreaseMonkey's original
**1.0** from 2013. They differ in charge precision, in how the response
strength moves, and 1a adds an antijerk filter that 1.0 has no idea about:

                    1.0 (here)                  1a (ffmpeg)
    charge          (resp*(t-lvl)+128)>>8       (s*(t-q)+512)>>10
    strength        RESP_INC 7 / RESP_DEC 20    +/-1 per sample, floor 8
    antijerk        none                        yes

Feeding 1a data to a 1.0 decoder does not sound slightly worse, it sounds like
noise. So the encoder below is a direct port of AsieLib's `compress`, which
guarantees the bytes we write are the bytes the tape drive expects.

Ported from AsieLib, itself by Ben "GreaseMonkey" Russell, 2013 — public domain.
"""

from __future__ import annotations

RESP_INC = 7
RESP_DEC = 20
LPF_STRENGTH = 100


class DFPWM:
    """One codec context. Encoding and decoding are stateful and sequential."""

    def __init__(self) -> None:
        self.response = 0
        self.level = 0
        self.lastbit = False
        self.flastlevel = 0
        self.lpflevel = 0

    def _ctx_update(self, curbit: bool) -> None:
        target = 127 if curbit else -128

        nlevel = self.level + ((self.response * (target - self.level) + 128) >> 8)
        if nlevel == self.level and self.level != target:
            nlevel += 1 if target == 127 else -1

        if curbit == self.lastbit:
            rtarget, rdelta = 255, RESP_INC
        else:
            rtarget, rdelta = 0, RESP_DEC

        nresponse = self.response + ((rdelta * (rtarget - self.response) + 128) >> 8)
        if nresponse == self.response and self.response != rtarget:
            nresponse += 1 if rtarget == 255 else -1

        self.level = nlevel
        self.response = nresponse
        self.lastbit = curbit

    def compress(self, pcm: bytes) -> bytearray:
        """8-bit signed PCM in, packed 1-bit DFPWM out (8 samples per byte)."""
        out = bytearray()
        level_of = self.__dict__          # local lookups in the hot loop
        for base in range(0, len(pcm) - 7, 8):
            d = 0
            for k in range(8):
                sample = pcm[base + k]
                if sample > 127:          # bytes are unsigned; make them signed
                    sample -= 256
                level = level_of["level"]
                curbit = sample > level or (sample == level and level == 127)
                d = ((d >> 1) + 128) if curbit else (d >> 1)
                self._ctx_update(curbit)
            out.append(d)
        return out

    def decompress(self, data: bytes) -> bytearray:
        """The inverse, for verifying an encode without leaving the desk."""
        out = bytearray()
        for byte in data:
            d = byte
            for _ in range(8):
                curbit = (d & 1) != 0
                lastbit = self.lastbit
                self._ctx_update(curbit)
                d >>= 1

                # noise shaping
                blevel = self.level if curbit == lastbit else \
                    ((self.flastlevel + self.level) >> 1)
                self.flastlevel = self.level

                # low-pass filter
                self.lpflevel += ((LPF_STRENGTH * (blevel - self.lpflevel) + 0x80) >> 8)
                out.append(self.lpflevel & 0xFF)
        return out


class DFPWM1a:
    """The *other* codec: ChenThread's 1a, what ffmpeg and CC:Tweaked use.

    Included so the two can be compared directly on real hardware. On a
    Computronics drive this should sound like hiss, because the drive decodes
    1.0 -- but a claim like that is worth being able to test rather than take
    on trust.

    Ported from ffmpeg's libavcodec/dfpwmenc.c, itself from
    https://github.com/ChenThread/dfpwm/tree/master/1a -- public domain.
    """

    def __init__(self) -> None:
        self.q = 0          # charge
        self.s = 0          # strength, 0..1023
        self.lt = -128      # last target

    def compress(self, pcm: bytes) -> bytearray:
        """8-bit signed PCM in, packed 1-bit DFPWM1a out."""
        out = bytearray()
        for base in range(0, len(pcm) - 7, 8):
            d = 0
            for k in range(8):
                v = pcm[base + k]
                if v > 127:                 # bytes are unsigned; make signed
                    v -= 256

                t = 127 if (v > self.q or (v == self.q and v == 127)) else -128
                d >>= 1
                if t > 0:
                    d |= 0x80

                # adjust charge — note 10-bit precision, unlike 1.0's 8
                nq = self.q + ((self.s * (t - self.q) + 512) >> 10)
                if nq == self.q and nq != t:
                    nq += 1 if t == 127 else -1
                self.q = nq

                # adjust strength — steps by one, with a floor of 8
                st = 0 if t != self.lt else 1023
                ns = self.s
                if ns != st:
                    ns += 1 if st != 0 else -1
                if ns < 8:
                    ns = 8
                self.s = ns

                self.lt = t
            out.append(d)
        return out


def compress(pcm: bytes, variant: str = "1.0") -> bytes:
    """Compress to DFPWM. `variant` is "1.0" (Computronics) or "1a" (ffmpeg)."""
    codec = DFPWM1a() if variant == "1a" else DFPWM()
    return bytes(codec.compress(pcm))


def decompress(data: bytes) -> bytes:
    return bytes(DFPWM().decompress(data))
