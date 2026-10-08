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

## ZX Spectrum I/O assignment — prototype with the QM_Atrix adapter (2026-10-06)

**Prototype only, not the final hardware.** The user's QM_Atrix adapter (see `QM_ATRIX_ADAPTER.md`) is plugged
with its **J2** straight into **U8**: J2 pin 1 on U8 pin 64, so J2 pin k sits on U8 pin 65-k. Adapter J2.2 is
cut (it would sit on VIN). J1 hangs outside the Cyclone board and its signals go to **U7** by wires.
(The earlier all-on-U7 hand-wiring proposal of 2026-10-05 is superseded.)

### U8 — adapter J2 plugged in

| U8 pin | FPGA pin | Bank | Adapter | Signal | Dir | Notes |
|---|---|---|---|---|---|---|
| 64 | — | | J2.1 5v0 | VIN 5 V | power | feeds the adapter: 7803 (3v3 rail, pull-ups), keyboard module, audio amp module |
| 63 | — | | J2.2 (cut) | VIN | | pin removed on the adapter |
| 61, 62 | — | | J2.4, J2.3 GND | GND | | VGA ground return |
| 59 | M20 | 5 | BL | VGA_B_LOW | out | |
| 57 | N20 | 5 | BH | VGA_B | out | |
| 55 | B22 | 6 | GL | VGA_G_LOW | out | |
| 53 | C22 | 6 | GH | VGA_G | out | |
| 51 | D22 | 6 | RL | VGA_R_LOW | out | |
| 49 | E22 | 6 | RH | VGA_R | out | |
| 47 | F22 | 6 | HS | VGA_HSYNC | out | 22 Ω + 6p8 on the adapter |
| 45 | H22 | 6 | VS | VGA_VSYNC | out | 22 Ω + 6p8 on the adapter |
| 25 | W22 | 5 | Tape_out | — | in | never used: leave as input |
| 23 | Y22 | 5 | Tape_in | TAPE_IN | in | tape simulator / SD card loader data |
| 21 | AA20 | 4 | Turbo | TURBO_N | in | active low: low = 28 MHz turbo; 680 Ω pull-up on the adapter keeps it off when no loader is connected |
| 19 | AA19 | 4 | Kb_out (J5.2) | KBD_TX ? | out? | keyboard module UART, 3.3 V. **Direction to confirm** on the module |
| 17 | AA18 | 4 | Kb_in (J5.3) | KBD_RX ? | in? | 115200 baud. **Direction to confirm** |
| 16 | AB17 | 4 | J2.49 GND | GND_TIE | **never drive high** | FPGA I/O hard-wired to GND: set as output driving ground (extra ground return) or input |
| 15 | AA17 | 4 | J2.50 GND | GND_TIE | **never drive high** | same |

All other U8 pins under J2 (17-60 not listed above) sit on unconnected adapter pins, including the
configuration-related ones (pins 35-42: N22/N21 DEV_OE/DEV_CLRn, L22/L21, K22/K21): leave unused, keep
DEV_CLRn/DEV_OE options off. U8 pins 1-14 (incl. the clock-only inputs on 5/6) are not covered by the adapter.
VGA spans banks 5 and 6, both VCCIO 3.3 V: no problem. This uses the QMTECH daughterboard's VGA area, so that
board cannot be used at the same time (it couldn't anyway).

### U7 — wired from adapter J1

The adapter keeps its own pull-ups (3k3 to its 3v3 rail) and filters. Adapter ground is already common through
J2/U8; add one GND wire in the bundle (J1.3 -> U7.1) to keep the loop area small. Do **not** wire J1.1 (5 V) or
J1.2 (3v3).

| U7 pin | FPGA pin | Adapter J1 | Signal | Dir | Notes |
|---|---|---|---|---|---|
| 1 | — | J1.3 GND | GND | | ground wire along the bundle |
| 15 | J1 | J1.17 AY | AUDIO_AY | out | PWM; 68 Ω + 100 nF low-pass on the adapter |
| 16 | J2 | J1.19 Beeper | AUDIO_BEEPER | out | port FE bit 4 |
| 22 | D2 | J1.5 Vrf | SW_50_60 | in | S1: GND or 3v3 via 3k3 |
| 23 | C1 | J1.15 Up | JOY_UP_N | in | 3k3 pull-up on the adapter; active low |
| 24 | C2 | J1.11 Dwn | JOY_DOWN_N | in | |
| 25 | B1 | J1.9 Lft | JOY_LEFT_N | in | |
| 26 | B2 | J1.7 Rght | JOY_RIGHT_N | in | also DB9 pin 7 (harmless, plain joystick only) |
| 27 | B3 | J1.13 Btn | JOY_FIRE_N | in | |

These are the same U7 pins as in the 2026-10-05 proposal, so nothing moves for these signals. U7 7-14, 17-21 and
28-60 are now free.

### U8 top — SD card (Adafruit 5683 MicroSD BFF), wired by the user 2026-10-08

BFF jumpers unmodified (CS = TX via SJ2). SCK/MOSI/MISO on 5 mm pins, CS by a 25 mm wire. 10 uF + 100 nF across
3V3/GND at the BFF. Other BFF pins (RX, A0-A3, SDA, SCL, 5V) unconnected. U8.1-14 are above the adapter's J2
(U8.15-64). See docs/SD_TAPE_LOADER.md.

| U8 pin | FPGA pin | BFF pin | Signal | Dir | Notes |
|---|---|---|---|---|---|
| 1/2 | — | JP3.6 GND | GND | | |
| 3/4 | — | JP3.5 3.3V | 3V3 | power | core board 3.3 V |
| 7 | AA13 | JP3.4 MOSI | SD_MOSI | out | |
| 9 | AA14 | JP3.3 MISO | SD_MISO | in | FPGA weak pull-up ON (BFF has none) |
| 11 | AA15 | JP3.2 SCK | SD_SCK | out | <= 400 kHz init, then 14 MHz |
| 13 | AA16 | JP1.7 TX | SD_CS_N | out | idle high; weak pull-up ON so the card stays deselected before the loader runs |

U8.5/6 (AA11/AB11) are CLK15/CLK14 dedicated clock inputs: input-only, never use them for outputs.

### On-board
- Machine reset = KEY0 (W13). ROM select = KEY1 (Y13) held during reset/power-up -> DiagROM.
  Since 2026-10-08 (SD tape loader build): DiagROM = F1 held at CPU start, 50/60 = F8, KEY1 unused (v1 used KEY1).

### Rules for every bitstream loaded on this board while the adapter is attached
- AB17/AA17 are tied to GND: never drive them high. Unused pins must be plain inputs (Quartus "Reserve all unused
  pins: As input tri-stated", which is what DDR_TEST uses).
- Know what is in the configuration flash: a demo image that drives header pins could fight the adapter
  (GND ties, keyboard TX, Turbo pull-up). Program a safe image or erase the flash before powering up with the adapter.
- Mechanical: the adapter hangs from U8 only; support the J1 side (spacer) so cable strain does not lever on U8.

Electrical notes:
- Inputs can get the FPGA's internal weak pull-up (~25 kOhm, `WEAK_PULL_UP_RESISTOR ON` in the .qsf); with the
  QM_Atrix adapter the joystick, 50/60 and Turbo lines already have pull-ups on the adapter. For a long joystick cable, an external 4.7-10 kOhm pull-up and a
  100-330 Ohm series resistor per line make the input more robust (noise, ESD).
- Inputs are synchronised (2 flip-flops) and the buttons/switches debounced in the FPGA.
- During FPGA configuration all user pins are inputs with weak pull-ups: VGA/audio outputs float high for
  ~0.3 s at power-up. Harmless for a resistor DAC and an RC filter.
- **Check the U7/U8 pin numbering against the board with a meter** before connecting (it was read from the
  schematic image): e.g. confirm pins 1/2 = GND, 3/4 = 3.3 V, 61/62 = GND, 63/64 = VIN.
