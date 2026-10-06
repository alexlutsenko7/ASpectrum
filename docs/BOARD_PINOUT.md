# QMTECH Cyclone IV EP4CE15F23 core board — header pinout

Source: `docs/vendor/QMTECH_EP4CE15F23_V2_schematic.pdf` (QMTECH, rev 2, 2021-08-28), read from the schematic
image. **Verify against your board revision / silkscreen before wiring.** The SDRAM pins in this schematic match
the vendor demo project, which works on the user's board.

All user I/O banks are VCCIO = 3.3 V (LVTTL/LVCMOS). Cyclone IV I/O is **not 5 V tolerant**.

## On-board
| Function | FPGA pin | Notes |
|---|---|---|
| 50 MHz oscillator | T2 | |
| KEY0 (SW1) | W13 | active low, 4.7k pull-up (used as RESET_N in DDR_TEST) — the button farther from the long edge |
| KEY1 (SW2) | Y13 | active low, 4.7k pull-up (used as KEY in DDR_TEST) — the button closest to the long edge |
| LED0 (D5) | E4 | active low (anode to 3V3 via 1k) |
| Config flash W25Q64 | DCLK K2, DATA0 K1, ASDO D1, nCSO E2 | dedicated AS pins; reachable from user logic via `cycloneive_asmiblock` |
| SDRAM W9825G6KH | see DDR_TEST.qsf | |

## Header U8 (HDR 32x2) — "right" header
| Pin | Signal | Pin | Signal |
|---|---|---|---|
| 1 | GND | 2 | GND |
| 3 | 3V3 | 4 | 3V3 |
| 5 | AA11 (CLK15, clock input) | 6 | AB11 (CLK14, clock input) |
| 7 | AA13 | 8 | AB13 |
| 9 | AA14 | 10 | AB14 |
| 11 | AA15 | 12 | AB15 |
| 13 | AA16 | 14 | AB16 |
| 15 | AA17 | 16 | AB17 |
| 17 | AA18 | 18 | AB18 |
| 19 | AA19 | 20 | AB19 |
| 21 | AA20 | 22 | AB20 |
| 23 | Y22 | 24 | Y21 |
| 25 | W22 | 26 | W21 |
| 27 | V22 | 28 | V21 |
| 29 | U22 | 30 | U21 |
| 31 | R22 | 32 | R21 |
| 33 | P22 | 34 | P21 |
| 35 | N22 | 36 | N21 |
| 37 | M22 | 38 | M21 |
| 39 | L22 | 40 | L21 |
| 41 | K22 | 42 | K21 |
| 43 | J22 | 44 | J21 |
| 45 | H22 | 46 | H21 |
| 47 | F22 | 48 | F21 |
| 49 | E22 | 50 | E21 |
| 51 | D22 | 52 | D21 |
| 53 | C22 | 54 | C21 |
| 55 | B22 | 56 | B21 |
| 57 | N20 | 58 | N19 |
| 59 | M20 | 60 | M19 |
| 61 | GND | 62 | GND |
| 63 | VIN (5 V) | 64 | VIN (5 V) |

## Header U7 (HDR 32x2) — "left" header
| Pin | Signal | Pin | Signal |
|---|---|---|---|
| 1 | GND | 2 | GND |
| 3 | 3V3 | 4 | 3V3 |
| 5 | n.c. | 6 | n.c. |
| 7 | R1 | 8 | R2 |
| 9 | P1 | 10 | P2 |
| 11 | N1 | 12 | N2 |
| 13 | M1 | 14 | M2 |
| 15 | J1 | 16 | J2 |
| 17 | H1 | 18 | H2 |
| 19 | F1 | 20 | F2 |
| 21 | E1 | 22 | D2 |
| 23 | C1 | 24 | C2 |
| 25 | B1 | 26 | B2 |
| 27 | B3 | 28 | A3 |
| 29 | B4 | 30 | A4 |
| 31 | C4 | 32 | C3 |
| 33 | B5 | 34 | A5 |
| 35 | B6 | 36 | A6 |
| 37 | B7 | 38 | A7 |
| 39 | B8 | 40 | A8 |
| 41 | B9 | 42 | A9 |
| 43 | B10 | 44 | A10 |
| 45 | B13 | 46 | A13 |
| 47 | B14 | 48 | A14 |
| 49 | B15 | 50 | A15 |
| 51 | B16 | 52 | A16 |
| 53 | B17 | 54 | A17 |
| 55 | B18 | 56 | A18 |
| 57 | B19 | 58 | A19 |
| 59 | B20 | 60 | A20 |
| 61 | GND | 62 | GND |
| 63 | VIN (5 V) | 64 | VIN (5 V) |

Pin numbers 1/2, 61/62 GND and 63/64 VIN are as drawn; the exact pin-5/6 and power-row assignment should be
checked with a meter before connecting an adapter.

## ZX Spectrum I/O assignment (proposed 2026-10-05, all on header U7)

The user's existing adapter (built for another FPGA board, all 3.3 V; see `QM_ATRIX_ADAPTER.md`) will be wired to U7 by hand.
Confirmed by the user 2026-10-05: two separate audio outputs (beeper and AY PWM); ROM select switch on pin 28.

| U7 pin | FPGA pin | Signal | Dir | Notes |
|---|---|---|---|---|
| 1, 2 | — | GND | | ground for the adapter (VGA ground return) |
| 3, 4 | — | 3V3 | | not used by the QM_Atrix adapter (it has its own 7803 from 5 V); do not tie to the adapter 3v3 rail |
| 7 | R1 | VGA_R | out | red, high bit |
| 8 | R2 | VGA_R_LOW | out | red, low (brightness) bit |
| 9 | P1 | VGA_G | out | |
| 10 | P2 | VGA_G_LOW | out | |
| 11 | N1 | VGA_B | out | |
| 12 | N2 | VGA_B_LOW | out | |
| 13 | M1 | VGA_HSYNC | out | |
| 14 | M2 | VGA_VSYNC | out | |
| 15 | J1 | AUDIO_AY | out | AY-3-8910/12 sound, PWM (needs RC low-pass on the adapter) |
| 16 | J2 | AUDIO_BEEPER | out | ZX beeper (port FE bit 4), plain logic level |
| 17 | H1 | KBD_RX | in | from the keyboard adapter's TX (115200 baud) |
| 18 | H2 | KBD_TX | out | to the keyboard adapter's RX |
| 19 | F1 | TAPE_IN | in | tape simulator data |
| 20 | F2 | TURBO_N | in | active low: low = 28 MHz turbo, released/high = normal. Driven by the SD card loader (tape simulator) when connected; 680 Ω pull-up on the adapter (plus FPGA weak pull-up) keeps turbo off when nothing is connected |
| 21 | E1 | RESET_BTN_N | in | Z80/machine reset button to GND, internal pull-up. Not used with the QM_Atrix adapter: reset = on-board KEY0 (W13) |
| 22 | D2 | SW_50_60 | in | 50/60 Hz switch to GND, internal pull-up |
| 23 | C1 | JOY_UP_N | in | Kempston, to GND when pressed, internal pull-up |
| 24 | C2 | JOY_DOWN_N | in | |
| 25 | B1 | JOY_LEFT_N | in | |
| 26 | B2 | JOY_RIGHT_N | in | |
| 27 | B3 | JOY_FIRE_N | in | |
| 28 | A3 | ROM_SEL | in | ROM select switch, read at reset: open (pull-up) = 128K ROM, to GND = DiagROM (polarity can be swapped). **Dropped 2026-10-06**: ROM select = on-board KEY1 (Y13) held during reset/power-up -> DiagROM; U7.28 free |
| 29-60 | B4... | — | | free |

Why these pins:
- One header, one contiguous block (U7 pins 7-28): a single ribbon/IDC cable; GND (1-2) and 3V3 (3-4) on the
  same connector, next to the VGA group.
- VGA outputs together in one I/O bank (left side), at the end nearest the ground pins.
- None of them are special: avoids the clock-input-only pins (U8 5/6 = AA11/AB11), the configuration-related
  pins on U8 (K22 nCEO, K21 CLKUSR, L21 CRC_ERROR, L22 INIT_DONE, N21/N22 DEV_CLRN/DEV_OE), and the pins the QMTECH
  daughterboard uses for VGA (U8 B21-N19), in case that board is ever used.
- B3/A3 (bank 8) are dual-purpose configuration data pins in passive modes only; in our AS mode they are normal I/O.
- U8 stays completely free for future expansion.

Electrical notes:
- All inputs get the FPGA's internal weak pull-up (~25 kOhm, `WEAK_PULL_UP_RESISTOR ON` in the .qsf). Buttons,
  switches and joystick lines just switch to GND. For a long joystick cable, an external 4.7-10 kOhm pull-up and a
  100-330 Ohm series resistor per line make the input more robust (noise, ESD).
- Inputs are synchronised (2 flip-flops) and the buttons/switches debounced in the FPGA.
- During FPGA configuration all user pins are inputs with weak pull-ups: VGA/audio outputs float high for
  ~0.3 s at power-up. Harmless for a resistor DAC and an RC filter.
- **Check the U7 pin numbering against the board with a meter** before connecting (it was read from the
  schematic image): e.g. confirm pins 1/2 = GND and 3/4 = 3.3 V.
