#!/usr/bin/env python3
"""mk_load_tzx.py OUT.tzx -- a BASIC program for the end-to-end load test:
    10 BORDER 4
saved as header + data with standard ROM pulse timings (TZX 0x11 blocks), only
the pilot tones shortened to 2400 pulses (5.2 M T-states) to keep the simulation short. The ROM
needs more than ~1900: after the first edge it waits ~3.5 M T-states (LD-WAIT, 0x0574) before
it checks 256 leader pulses. Green (4) is never used by the loader, so it cannot pass by accident."""
import struct
import sys

prog = bytes([0x00, 0x0A, 0x09, 0x00,                     # line 10, 9 bytes
              0xE7, 0x34, 0x0E, 0x00, 0x00, 0x04, 0x00, 0x00,  # BORDER 4 (number 4 in 5-byte form)
              0x0D])
hdr = bytes([0x00]) + b"loadtest  " + struct.pack("<HHH", len(prog), 10, len(prog))


def block(flag, data, pause_ms):
    d = bytes([flag]) + data
    cs = 0
    for b in d:
        cs ^= b
    d += bytes([cs])
    return (b"\x11" + struct.pack("<HHHHHHBH", 2168, 667, 735, 855, 1710, 2400, 8, pause_ms)
            + struct.pack("<I", len(d))[:3] + d)


open(sys.argv[1], "wb").write(b"ZXTape!\x1a\x01\x14" + block(0x00, hdr, 300) + block(0xFF, prog, 100))
