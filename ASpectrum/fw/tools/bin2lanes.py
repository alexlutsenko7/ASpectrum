#!/usr/bin/env python3
"""bin2lanes.py BIN WORDS OUTPREFIX -- split a little-endian RV32 image into four
byte-lane $readmemh files OUTPREFIX0.hex .. OUTPREFIX3.hex of WORDS lines each
(lane n = byte n of every 32-bit word; rtl/tape_loader.v has one 8-bit RAM per lane)."""
import sys

def main():
    src, words, prefix = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    data = open(src, "rb").read()
    if len(data) > 4 * words:
        sys.exit(f"bin2lanes: image is {len(data)} bytes, RAM is {4 * words}")
    data = data + bytes(4 * words - len(data))
    for lane in range(4):
        with open(f"{prefix}{lane}.hex", "w", newline="\n") as f:
            f.write("".join(f"{data[4 * w + lane]:02x}\n" for w in range(words)))

if __name__ == "__main__":
    main()
