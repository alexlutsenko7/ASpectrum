#!/usr/bin/env python3
"""connection_diagram.py FONT_HEX OUT.png -- ASpectrum wiring overview, pure Python (zlib PNG),
labels in the Spectrum ROM font (rtl/osd_font.hex). Same drawing style as architecture_diagram.py."""
import struct
import sys
import zlib

W, H = 1800, 980
img = bytearray(b"\xff" * (W * H * 3))
font = [int(l, 16) for l in open(sys.argv[1])]


def rect(x, y, w, h, c):
    for yy in range(y, y + h):
        o = (yy * W + x) * 3
        img[o:o + 3 * w] = bytes(c) * w


def frame(x, y, w, h, c, t=3):
    rect(x, y, w, t, c); rect(x, y + h - t, w, t, c)
    rect(x, y, t, h, c); rect(x + w - t, y, t, h, c)


def text(x, y, s, c=(0, 0, 0), sc=2):
    for i, ch in enumerate(s):
        code = ord(ch) if 32 <= ord(ch) < 128 else 63
        for r in range(8):
            row = font[code * 8 + r]
            for b in range(8):
                if row & (0x80 >> b):
                    rect(x + (i * 8 + b) * sc, y + r * sc, sc, sc, c)


def text_w(s, sc=2):
    return len(s) * 8 * sc


BLUE, GREEN, ORANGE, GREY, DARK = (214, 228, 248), (214, 240, 214), (252, 228, 200), (232, 232, 232), (40, 40, 40)
EDGE = {BLUE: (46, 84, 150), GREEN: (56, 128, 56), ORANGE: (190, 110, 30), GREY: (110, 110, 110)}
LBL = (70, 70, 70)


def box(x, y, w, h, lines, fill):
    rect(x, y, w, h, fill)
    frame(x, y, w, h, EDGE[fill])
    ty = y + (h - len(lines) * 22) // 2 + 3
    for i, l in enumerate(lines):
        text(x + (w - text_w(l)) // 2, ty + i * 22, l, DARK, 2)


def hline(x0, x1, y, t=5):
    if x1 < x0: x0, x1 = x1, x0
    rect(x0, y - t // 2, x1 - x0 + 1, t, DARK)


def vline(x, y0, y1, t=5):
    if y1 < y0: y0, y1 = y1, y0
    rect(x - t // 2, y0, t, y1 - y0 + 1, DARK)


text(40, 24, "ASpectrum - connections", DARK, 3)
for i, (c, l) in enumerate([(BLUE, "FPGA core board"), (GREEN, "adapter, SD card"), (ORANGE, "ESP32 controller"), (GREY, "devices")]):
    rect(1000 + (i % 2) * 380, 20 + (i // 2) * 30, 26, 22, c); frame(1000 + (i % 2) * 380, 20 + (i // 2) * 30, 26, 22, EDGE[c], 2)
    text(1036 + (i % 2) * 380, 23 + (i // 2) * 30, l, DARK, 2)

# core board with its two headers
box(640, 120, 520, 760, [], BLUE)
text(640 + (520 - text_w("QMTECH CYCLONE IV")) // 2, 470, "QMTECH CYCLONE IV", DARK, 2)
text(640 + (520 - text_w("EP4CE15 + SDRAM")) // 2, 496, "EP4CE15 + SDRAM", DARK, 2)
box(660, 140, 90, 720, [], GREY)
box(1050, 140, 90, 720, [], GREY)
for i, ch in enumerate("U7"): text(690, 470 + i * 24, ch, DARK, 2)
for i, ch in enumerate("U8"): text(1080, 470 + i * 24, ch, DARK, 2)

# right: U8
box(1300, 330, 440, 470, ["QM_ATRIX ADAPTER", "J2 plugged into U8", "", "VGA, keyboard UART,", "5 V from U8.64", "", "J2.1 on U8.64"], GREEN)
hline(1140, 1300, 560); text(1160, 530, "U8.15-64", LBL, 2)
box(1440, 860, 300, 80, ["VGA, USB KBD"], GREY)
vline(1590, 800, 860)

# left: U7
box(60, 140, 440, 230, ["ADAPTER J1", "(wires to U7)", "", "AY + beeper audio,", "joystick, GND U7.1"], GREEN)
hline(500, 660, 255); text(512, 222, "U7.15,16", LBL, 2); text(512, 266, "U7.23-27", LBL, 2)
box(60, 450, 440, 300, ["ESP32-WROOM-32", "SYSTEM CONTROLLER", "", "LINK: D35 D34 D14", "D13 D33", "I2S: D26 D25 D22", "UART: RX2 TX2", "GND, power: USB"], ORANGE)
hline(500, 660, 560); text(512, 527, "U7.7-11", LBL, 2)
hline(500, 660, 640); text(512, 607, "U7.17-21", LBL, 2); text(512, 651, "GND U7.2", LBL, 2)
box(60, 830, 200, 110, ["MICROSD", "BFF (SPI)"], GREEN)
vline(160, 750, 830)                                     # wires ESP32 -> SD card
box(300, 830, 200, 110, ["BT HEAD-", "PHONES"], GREY)
for y in range(750, 830, 16): rect(398, y, 5, 8, DARK)   # radio link, dashed

raw = b"".join(b"\x00" + bytes(img[y * W * 3:(y + 1) * W * 3]) for y in range(H))
def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
open(sys.argv[2], "wb").write(png)
print("written", sys.argv[2], len(png))
