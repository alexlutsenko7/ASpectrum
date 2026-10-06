# QM_Atrix adapter — the user's existing ZX I/O board

KiCad project in `QM_Atrix_adapter/`, originally made (Mar 2024) as a plug-on board for a QMTECH **Artix-7**
core board (two 2x25 headers named JP2/JP3). It is **not** pin- or size-compatible with the QMTECH Cyclone IV
board (two 2x32 headers U7/U8, see `BOARD_PINOUT.md`). How it will be connected is **not decided yet**.

Netlists below were extracted with `kicad-cli` (schematic) and by parsing the `.kicad_pcb` pad nets (2026-10-06).

## Files

| Path | Role |
|---|---|
| `qm_atrix.kicad_sch` | Schematic, Mar 2024 (KiCad 6), **auto-converted to KiCad 10.0.1 on 2026-10-06** (no intentional edits; the conversion re-annotated parts) |
| `qm_atrix.pdf` | Plot of the converted schematic (2026-10-06) |
| `qm_atrix.kicad_pcb` | Layout, Mar 2024 (KiCad 6 format) = **what was built**; reference designators differ from the converted schematic (see "Schematic vs PCB") |
| `qm_atrix.kicad_pro/.kicad_prl` | Project files |
| `pcb_manufactoring/` (+ `.zip`) | Gerbers + drill files of the 2024 PCB (what was manufactured) |
| `qm_atrix.dsn/.ses/.rules` | FreeRouting export/import of the 2024 PCB |
| `qm_atrix-backups/`, `.history/`, `fp-info-cache` | KiCad autosaves / local history / footprint cache |

## Board

- 60 x 68 mm, 2 layers, SMD 0603 passives + THT connectors.
- J1 (JP2) and J2 (JP3): 2x25 2.54 mm headers on the **bottom** side, 50.8 mm (2.0") apart — they plug into the
  Artix board. Only the odd-numbered side of a few pins is used; all signals are 3.3 V.
- Front side: VGA DB15 (J7, at the board edge), Atari/Kempston DB9 male (J4), 50/60 Hz slide switch (S1),
  pin headers for the keyboard module (J5), tape module (J6), audio module (J3) and two volume pots (RV1, RV2).

## Signals on the host headers

J1 = JP2, J2 = JP3. Pins not listed are unconnected.

| Header pin | Net | Dir (FPGA) | Function / circuit on the adapter |
|---|---|---|---|
| J1.1, J2.1 | 5v0 | power | 5 V: audio module J3.4, keyboard module J5.4 (and U1 input, schematic only) |
| J1.2, J2.2 | 3v3 | power | 3.3 V from the host (built PCB). The schematic leaves them open and draws 3v3 from U1 instead |
| J1.3, J1.4, J1.49, J1.50, J2.3, J2.4, J2.49, J2.50 | GND | | |
| J1.5 | Vrf | in | S1: GND or 3v3 via R1 3k3 — 50/60 Hz vertical refresh switch |
| J1.7 | Rght | in | DB9 pin 4 **and pin 7**, 3k3 pull-up to 3v3 |
| J1.9 | Lft | in | DB9 pin 3, 3k3 pull-up |
| J1.11 | Dwn | in | DB9 pin 2, 3k3 pull-up |
| J1.13 | Btn | in | DB9 pin 6 (fire), 3k3 pull-up |
| J1.15 | Up | in | DB9 pin 1, 3k3 pull-up |
| J1.17 | AY | out | R2 68 Ω + C1 100 nF to GND (RC low-pass, fc ≈ 23 kHz) → C2 10 µF → RV1 → J3.3 |
| J1.19 | Beeper | out | C3 10 µF (no resistor/filter) → RV2 → J3.1 |
| J2.6 / J2.8 | BL / BH | out | blue low / high bit |
| J2.10 / J2.12 | GL / GH | out | green low / high bit |
| J2.14 / J2.16 | RL / RH | out | red low / high bit |
| J2.18 | HS | out | 6p8 to GND, R 22 Ω → VGA pin 13 |
| J2.20 | VS | out | 6p8 to GND, R 22 Ω → VGA pin 14 |
| J2.40 | Tape_out | out | J6.6 — **never used** (tape is load-only) |
| J2.42 | Tape_in | in | J6.5 |
| J2.44 | Turbo | in | J6.1, 680 Ω pull-up to 3v3 (fitted on the real board; in the schematic, missing from the PCB file) |
| J2.46 | Kb_out | out? | J5.2 (3.3 V logic) |
| J2.48 | Kb_in | in? | J5.3 (3.3 V logic) |

21 signals on the headers (20 used — Tape_out never used): 8 VGA, 2 audio, 2 keyboard UART, 3 tape/turbo, 1 switch, 5 joystick.

## On-board circuits

- **VGA DAC** (J7): per colour, high bit via 130 Ω and low bit via 340 Ω into the 75 Ω monitor load, 6p8 to GND
  on each colour line. Weights ≈ 2.6:1 (4 levels per colour, matches the reference design's 2-bit RGB).
  Full scale at 3.3 V ≈ 3.3·75/(75+130‖340) ≈ 1.46 V (above the 0.7 V standard), but it worked fine on the Artix
  board — **kept as is** (user's decision 2026-10-06).
- **Joystick** (J4, DB9 male): Atari/Kempston pinout 1 Up, 2 Down, 3 Left, 4 Right, 6 Fire, 8 GND; 3k3 pull-ups to
  3v3. Pin 7 is also tied to Rght (both schematic and PCB). Only a plain switch joystick is used (no autofire,
  nothing drives pin 7), so this is harmless; just never plug in an autofire (+5 V on pin 7) or Sega pad.
- **Keyboard** (J5, footprint `USB_MODULE_KEYB_V2`): 1 GND, 2 Kb_out, 3 Kb_in, 4 5 V — the USB-HID→UART module
  (CH9350-style, 115200 baud, as in `Reference_ZX_On_DE10_Lite`). 5 V is only the USB power pass-through; the
  UART levels are 3.3 V (confirmed by the user), so it connects directly to Cyclone IV pins.
- **Tape** (J6): 1 Turbo, 2 n.c., 3 3v3, 4 GND, 5 Tape_in, 6 Tape_out — header to the tape simulator module,
  which also supplies the Turbo level. Turbo is **active low**: the loader pulls it low for turbo and releases it
  for normal speed; with no loader connected the 680 Ω pull-up on the adapter (fitted on the real board, see
  below) keeps it high (= normal). The FPGA weak pull-up can stay on as well (harmless). Tape_out was never used: the tape path is load-only.
- **Audio** (J3, footprint `audio_pcb`): 1 Beeper channel, 2 GND, 3 AY channel, 4 5 V, 5 GND — header for a 5 V
  audio amplifier module. RV1 (AY) / RV2 (beeper) are 1 kΩ volume pots on 3-pin headers (wiper → J3).
- **Power**: 4x 100 nF on 3v3, 4x 100 nF on 5v0. The schematic also has U1 `7803_switcing` (switching 7803
  drop-in, 5v0 → 3v3). It is missing from the PCB file but **fitted on the real board** (user, 2026-10-06), so the
  adapter makes its own 3v3 from 5v0 (feeds the joystick 3k3 and Turbo 680 Ω pull-ups and the 50/60 switch).
  Only 5v0 + GND are needed from the host. Do not also tie the host 3V3 to the adapter's 3v3 rail (two regulators in
  parallel) unless a continuity check shows the header 3v3 pins are isolated on the real board.

## Schematic vs PCB

Both date from Mar 2024. The 2024 schematic already contained two **unannotated** parts (`U?` = 7803 regulator,
`R?` = 680 Ω Turbo pull-up) that were never transferred to the PCB file. The KiCad 10 conversion (2026-10-06) annotated
them, which shifted the resistor numbering. The netlists differ as follows. **The PCB file is not exactly the real board**: the user confirmed
(2026-10-06) that the 680 Ω Turbo pull-up **is fitted** on the real board (hand-added, probably a version mismatch
between schematic and PCB). The 7803 is fitted too. So for these two parts the real board follows the **schematic**, not the PCB file.

| Item | PCB / gerbers (built) | Converted schematic |
|---|---|---|
| 3v3 source | host header pins J1.2 / J2.2 | U1 7803 from 5v0; J1.2 / J2.2 unconnected — **real board: 7803 fitted** |
| Turbo pull-up | none in the file — **but fitted on the real board** | R9 680 Ω to 3v3 |
| Joystick pull-ups | R9 Up, R10 Btn, R11 Dwn, R14 Lft, R15 Rght | R10 Up, R11 Btn, R12 Dwn, R15 Lft, R16 Rght |
| HS / VS series 22 Ω | R12 / R13 | R13 / R14 |
| DB9 shield (J4 pad 0) | no net | GND |

## Connecting to the Cyclone IV board (not decided)

For reference only: if hand-wired to U7 as proposed in `BOARD_PINOUT.md`, the adapter's nets map as follows:

| Adapter | U7 pin (FPGA) | Proposed signal |
|---|---|---|
| GND | 1, 2 | GND |
| 3v3 | — | **do not connect**: the adapter's 7803 makes 3v3 from 5v0 (check J1.2/J2.2 are isolated on the real board) |
| 5v0 (J1.1/J2.1) | 63, 64 (VIN) | 5 V for the audio and keyboard modules |
| RH, RL, GH, GL, BH, BL | 7, 8, 9, 10, 11, 12 (R1 R2 P1 P2 N1 N2) | VGA_R, VGA_R_LOW, VGA_G, VGA_G_LOW, VGA_B, VGA_B_LOW |
| HS, VS | 13, 14 (M1, M2) | VGA_HSYNC, VGA_VSYNC |
| AY, Beeper | 15, 16 (J1, J2) | AUDIO_AY, AUDIO_BEEPER |
| Kb_in, Kb_out | 17, 18 (H1, H2) | KBD_RX, KBD_TX (direction to be confirmed on the module) |
| Tape_in, Turbo | 19, 20 (F1, F2) | TAPE_IN, TURBO_N (active low, 680 Ω pull-up on the adapter) |
| Vrf | 22 (D2) | SW_50_60 (S1 drives GND / 3v3 via 3k3: compatible) |
| Up, Dwn, Lft, Rght, Btn | 23-27 (C1 C2 B1 B2 B3) | JOY_* |
| Tape_out | — | not needed (never used) |

Not on the adapter but in the proposal:
- **Reset**: on the Artix board the machine reset was the FPGA board's own reset button. Same approach here: the
  Cyclone IV on-board KEY0 (W13) — U7.21 RESET_BTN_N is then not needed for the adapter.
- **ROM select**: the adapter was built for a production machine and has no ROM select. It must be implemented
  differently. **Agreed 2026-10-06**: on-board KEY1 (Y13) held during reset/power-up -> DiagROM, otherwise 128K ROM
  (no extra hardware; optionally a USB-keyboard hotkey later). U7.28 ROM_SEL is dropped.

## Plugging J2 directly into a Cyclone header (user's plan, 2026-10-06)

Why the files don't match the board: the user's last schematic/PCB revision was lost; the KiCad files are an earlier
one. The plan is to plug the adapter's **J2** (VGA + tape/turbo + keyboard) straight into a Cyclone 2x32 header, so
the analog VGA lines get a short, rigid path. **J1** signals (joystick, AY, beeper, 50/60) go by wires.

Every alignment of the 2x25 J2 on a 2x32 header was checked (row offset, both row directions, both column
parities). Rule: adapter 5V must not reach GND or I/O, adapter GND must not reach 3V3/VIN, and all 8 VGA lines must
land on I/O. Only two families pass:

**A. Reversed (recommended): J2 pin 1 at the header's VIN end.** Works on U7 or U8. J2.1 5v0 -> VIN (adapter
powered from the header), J2.3/J2.4 GND -> GND 61/62 (real ground at the VGA end). J2.49/J2.50 GND land on two
I/O pins (leave them as inputs, never drive high). **J2.2 lands on VIN (5 V)**: must be isolated on the real board
(the schematic leaves it open since the 7803 makes 3v3). **Check with a meter before plugging in**: J2.2 must not
connect to the adapter's 3v3 rail. If it does, 5 V reaches the 3v3 pull-ups and from there the FPGA inputs.

Which column parity applies depends on how the headers mate; either works. On U7:

| Adapter | U7 pin / FPGA (parity 1) | U7 pin / FPGA (parity 2) |
|---|---|---|
| 5v0 J2.1 / J2.2 | 63 / 64 VIN | 64 / 63 VIN |
| GND J2.3, J2.4 | 61, 62 GND | 62, 61 GND |
| BL BH GL GH (J2.6-12) | 60 A20, 58 A19, 56 A18, 54 A17 | 59 B20, 57 B19, 55 B18, 53 B17 |
| RL RH HS VS (J2.14-20) | 52 A16, 50 A15, 48 A14, 46 A13 | 51 B16, 49 B15, 47 B14, 45 B13 |
| Tape_out, Tape_in, Turbo | 26 B2, 24 C2, 22 D2 | 25 B1, 23 C1, 21 E1 |
| Kb_out, Kb_in | 20 F2, 18 H2 | 19 F1, 17 H1 |
| GND J2.49, J2.50 | 15 J1, 16 J2 (I/O tied to GND) | 16 J2, 15 J1 |

All VGA pins are in one I/O bank either way. On U8 the same alignment puts VGA on M19 N19 B21 C21 D21 E21 F21 H21 (parity 1)
or M20 N20 B22 C22 D22 E22 F22 H22 (parity 2). That works too, but it takes the pins the QMTECH daughterboard uses for VGA.

**B. Straight, U7 only: J2 pin 1 at U7 pin 5.** J2.1/J2.2 -> U7.5/6 (n.c.; verify they really are open), so
**no power and no ground** through the header: adapter GND lands on FPGA I/O (U7.7/8, 53/54), which is a poor VGA
return. That needs extra GND and 5 V wires. Not recommended.

Still to check physically (user): where the adapter body and J1 end up relative to the Cyclone board and its
components for the chosen orientation. Once the fit is chosen, the U7 assignment in `BOARD_PINOUT.md` (VGA on
U7.7-14) must be redone to match.

## Open decisions (user)
- Physical connection: J2 plugged straight into a Cyclone header for VGA (user, 2026-10-06), J1 by wires; orientation
  (family A recommended) and U7 vs U8 to be fixed after a physical test fit.
- ~~ROM select method~~ — decided: KEY1 held at reset (see above).
