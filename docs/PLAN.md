# AlteraZX — ZX Spectrum 128 on QMTECH Cyclone IV (EP4CE15F23C8N) with SDRAM

Decisions and analysis agreed with the user, 2026-10-05. Source of truth for the porting plan.

## Goal
Port the user's working ZX Spectrum 128 (`Reference_ZX_On_DE10_Lite/`, MAX10, block-RAM only) to the QMTECH
Cyclone IV board, moving RAM (and ROM) into the on-board W9825G6KH-6 SDR SDRAM, with a fast "turbo" mode
(~28 MHz) for the user's tape simulator.

## Agreed architecture
- **One system clock** (PLL from 50 MHz) for SDRAM controller, CPU, bridge, AY, ports. No clock muxes.
- **CPU: T80 with clock enable (T80se)** stepping on CEN pulses from a 32-bit phase accumulator (DDS).
  - Normal: precise Spectrum speed (3.5469 MHz for 128K, or 3.5 MHz) — average exact, ±1 system clock jitter.
  - Turbo: ~28 MHz, selected by the TURBO_N input, active low (low = turbo, released/high = normal). Switching = change the accumulator
    increment; glitch-free at any time. Exact speeds not required, only "as precise as possible".
  - Turbo timing need not be cycle-exact: when SDRAM is not ready the bridge holds CEN (stalls the CPU).
  - Normal mode: memory always ready within a T-state budget -> cycle-exact, no waits.
  - T80 paths get multicycle constraints (CEN never closer than N system clocks); audit that all T80 regs are CEN-gated.
- **T80 version**: current T80 from the MiSTer ZX-Spectrum core, commit af0e6723 (2026-07-24), copied to `T80/`
  (see T80/SOURCE.md). The user's old T80(b) ver 303 stays in the reference folder as fallback.
- **CEN analysis done** (docs/T80_CEN_ANALYSIS.md): all T80 state is CEN-gated, so stalling CEN is safe. MiSTer ZX
  core does the same at 112 MHz (T80pa, turbo 28/56, SDRAM stall, VRAM shadow). Plan: own T80se-style wrapper
  (single CEN, exports MC/TS); DDS CEN (normal 3.5469 MHz, turbo exactly 112/4 = 28 MHz); CPU-internal multicycle
  setup 4 / hold 3; bridge starts SDRAM read at T1 (not on RD_n). T80 Fmax on EP4CE15 C8 measured: 63.5 MHz (15.75 ns) slow corner.
- **Memory map in SDRAM** (18-bit window, done):
  - 0x00000-0x1FFFF: RAM pages 0..7 (16 KB each)
  - 0x20000-0x27FFF: 128K ROM set (ROM 0 = 128K editor, ROM 1 = 48K BASIC; 7FFD bit 4 selects)
  - 0x28000-0x2BFFF: DiagROM v1.59 (16 KB); when selected it appears for both ROM pages
  - 0x2C000-0x3FFFF: spare
  - ROM region is read-only for the CPU. ROM set chosen by a switch sampled at reset (no re-copy needed).
  - No separate 48K ROM (user decision: ROM 1 of the 128K set serves 48K BASIC).
- **Flash (W25Q64 = EPCS64) layout**:
  - 0x000000: FPGA bitstream (~0.5 MB)
  - 0x100000: 128K ROM set, 32 KB  (source `Reference_ZX_On_DE10_Lite/128K_rom_hex.hex`, md5 85fede41...)
  - 0x108000: DiagROM, 16 KB       (source `Reference_ZX_On_DE10_Lite/DiagROM.hex`, "DIAGROM V1.59", md5 b90755c9...)
  - Boot copies both (48 KB, ~20 ms) into SDRAM.
  - Verified 2026-10-05: Quartus 25.1 Lite `quartus_cpf -c -d EPCS64 -s EP4CE15` builds a .jic; SFL images
    for EP4CE15 present (`quartus/common/devinfo/programmer/sfl_ep4ce15.sof`).
- **ROM source: on-board W25Q64 config flash** (EPCS64-compatible, ID 0x16). Bitstream uses ~0.5 MB; ROM image(s)
  stored at a fixed offset (proposed 0x100000). At boot: SDRAM init -> copy 32 KB flash->SDRAM via the
  `cycloneive_asmiblock` primitive (own SPI READ 0x03 FSM, ~20 MHz, ~13 ms) -> release CPU reset.
  Programming: Quartus "Convert Programming Files" -> .jic with .sof + ROM hex ("Add Hex Data" at the offset),
  programmed once via JTAG/SFL; day-to-day development loads .sof over JTAG, ROM stays in flash.
  To verify: EPCS64 still offered for Cyclone IV E in Quartus 25.1 Lite.
- **Video**: stays in FPGA block RAM — shadow copies of the screen area of pages 5 and 7 (6912 B each, 14-16 M9K),
  written in parallel with CPU writes to those pages. Video and floating-bus reads use the shadow, never SDRAM.
  ROMs stay in SDRAM (re-confirmed by the user 2026-10-06). ROM 32 KB + both shadows (46 of 56 M9K) would fit the
  EP4CE15, and loading only the selected ROM from flash into block RAM was considered. It was rejected so the design
  needs only ~15 M9K and can move to a smaller FPGA. The cost is an occasional 1-clock turbo stall on ROM fetches.
- **Refresh** hidden in the Z80 M1 refresh slot (T3/T4) where possible; otherwise forced every 7.5 us.
- **Reused from the reference** (ported into the single clock domain with CENs): 7FFD paging + lock, port FE
  (border/beeper/EAR, tape auto-lock), AY via JT49 (1.75 MHz), PWM audio, UART keyboard (CH9350-style HID packets),
  Kempston @1F, floating bus, VGA 640x480 50/60 Hz, INT 32 T-states from vsync.
- **Board I/O to add on headers** (QMTECH has none of it): VGA RGB444 + syncs, audio PWM, beeper, keyboard UART RX,
  tape in, turbo GPIO, Kempston, 50/60 Hz select, Z80 reset. DE10-Lite 7-segment debug is dropped.

## Turbo memory budget (system clock 112 MHz, CEN every 4 clocks = 28 MHz)
Opcode fetch needs data ~2 T-states after address = ~8 system clocks.
| SDRAM case | clocks incl. bridge | fits |
|---|---|---|
| write | 1 | yes |
| read, row open | 5 | yes |
| read, bank idle | 7 | yes |
| read, other row open | 9 | 1-clock stall |
| refresh | hidden in RFSH slot | — |
At 100 MHz (CEN avg every 3.57 clocks) the budget is ~7 clocks: est. 24-27 MHz effective; hence the move to 112 MHz.

## Steps
1. [done] DDR_TEST: 128Kx8 RAM on SDRAM @100 MHz, CL2, open-row; simulated + timing-clean + passes on hardware.
2. [done] SDRAM/system clock 112 MHz (28 x 4): timing closed (+0.74 ns worst), sim passes, passed on hardware.
3. ROM in SDRAM:
   a. [done] Controller + tester widened to 18-bit window (sdram_ram, ADDR_BITS=18); passes sim + hardware (soak test running).
   b. Flash->SDRAM ROM loader (asmiblock SPI READ), .jic flow with ROM hex, verify copy on hardware.
4. Z80 bus bridge (T80se + CEN DDS + stall), turbo GPIO; simulate with real ROM boot.
5. Port Spectrum peripherals into single clock domain; video with screen shadows; INT.
6. Pinout for add-on hardware on QMTECH headers; bring-up.

## Next stage: ESP32 as system controller (agreed 2026-10-13)

**Goal:** free block RAM. The FPGA stays the EP4CE15 (an EP4CE6 does not fit, see the session log). PicoRV32 and its
35 KB RAM leave the FPGA; the ESP32 (already there for Bluetooth) runs all loader firmware and drives the existing
loader hardware through an SPI link. Gain: **~38 M9K** (35 RAM + 2 CPU registers + 1 UART FIFO) of 56, ~2,600 LEs.
The same ESP32 + link is meant to serve later cores (C64) unchanged: machine-agnostic system controller.

### Split
| ESP32 (Arduino sketch, grows from `AAudio/`) | FPGA (`tape_loader` without the CPU) |
|---|---|
| SD card (own SPI host, FATFS, long names), directory listing + sort | pulse player + 512-entry command FIFO (T-state exact) |
| browser, save dialog, F-key handling, OSD drawing | MIC recorder with `hold` (no edge lost however slow the link is) |
| TAP/TZX parsing -> FIFO commands, MIC events -> TAP file | snapshot freeze + command port (MRD/MWR/REG/DIR/LOAD/AY/PORT/STATE) |
| .z80 load/save (`fw/snap.c`), BT menu (local calls, no UART) | OSD text RAM + font, INTPOS, contention switch, keys/KEYRAW |
| A2DP Bluetooth (core 0), loader (core 1) | **SPI-slave bridge** onto the register map + IRQ |

`fw/*.c` is ported, not rewritten: `hw.h` register access becomes link calls, `sd.c`/`fat.c` are replaced by the
ESP-IDF/Arduino FS, the browser keeps its list on the ESP32 (no 320-entry limit). The ESP32 becomes required for
loading/saving (the machine still boots and runs without it).

### Link (draft; finalise when building)
- SPI mode 0, ESP32 = master, FPGA = slave oversampling SCK in the 56 MHz loader domain: SCK <= 10 MHz (~1 MB/s;
  a 128 KB snapshot ~0.15 s). CS_N frames one command. MSB first.
- Frame = command byte + arguments; reads have one dummy byte before the data:
  | Cmd | Arguments | Purpose |
  |---|---|---|
  | `WR` | reg, data32 | write a loader register (same offsets as `fw/hw.h`) |
  | `RD` | reg, dummy -> data32 | read a loader register |
  | `FIFO` | n x data32 | push pulse-player commands (burst) |
  | `OSD` | addr16, n bytes | OSD text, auto-increment |
  | `MWR` / `MRD` | addr24, n bytes | Spectrum memory through the snapshot port, auto-increment (burst) |
  | `STAT` | dummy -> data32 | IRQ causes + FIFO free + core ID (reading acknowledges) |
- `ESP_IRQ` (FPGA -> ESP32, level, active high): FIFO below threshold, key report changed, recorder event, command done.
- Core ID register (e.g. "ZX", version) so the ESP32 firmware picks the machine's file handlers (C64 later).

### Test wiring (prototype, 2026-10-14)
SD card (Adafruit BFF, today on U8.7-13) moves to the ESP32; the link uses the free U7.7-11 next to the BT wires.
The current bitstream's F12 loader cannot reach the card any more after this; BT audio keeps working.

| Signal | ESP32 (DOIT 30-pin) | FPGA | U7 pin | Notes |
|---|---|---|---|---|
| SD SCK | GPIO18 (VSPI) | — | — | BFF JP3.2 |
| SD MISO | GPIO19 (VSPI) | — | — | BFF JP3.3; 10k pull-up to 3V3 if the BFF has none |
| SD MOSI | GPIO23 (VSPI) | — | — | BFF JP3.4 |
| SD CS | GPIO5 | — | — | BFF JP1.7 (TX); strapping pin, high at boot = default, OK |
| SD 3V3 / GND | 3V3 / GND | — | — | 10 uF + 100 nF stay at the BFF |
| ESP_SCK | GPIO14 | P1 | 9 | ESP32 -> FPGA |
| ESP_MOSI | GPIO13 | P2 | 10 | ESP32 -> FPGA |
| ESP_CS_N | GPIO33 | N1 | 11 | ESP32 -> FPGA; FPGA weak pull-up (deselected while the ESP32 boots) |
| ESP_MISO | GPIO35 (input only) | R1 | 7 | FPGA -> ESP32 |
| ESP_IRQ | GPIO34 (input only) | R2 | 8 | FPGA -> ESP32 |
| GND | GND | — | 1/2 | one more GND wire in the bundle |

Unchanged: I2S GPIO26/25/22 = U7.17-19; UART GPIO16/17 = U7.20/21 (kept until the BT menu runs on the ESP32).
Pins avoided on purpose: GPIO12 (strapping: high at boot selects 1.8 V flash; the FPGA's weak pull-ups would do
that), GPIO2/15 (strapping), GPIO6-11 (flash). SDMMC 1-bit/4-bit would need GPIO2/12/15, hence SD in SPI mode
(20-40 MHz, far more than tapes need). FPGA side: plain I/O in bank 2; Quartus confirms at the first build.

### Steps
1. First hardware test: ESP32 sketch mounts the SD card and lists a folder; FPGA build with the bridge
   (`ESP_LINK`, PicoRV32 removed) — ESP32 reads the core ID/TIMER, draws the listing on the OSD, reads keys,
   MWR/MRD burst round trip into a frozen machine. Sim first: bridge testbench with an ESP32 SPI-master model.
2. Port tape playback (`tape.c`: TAP/TZX -> FIFO, IRQ-driven refill) incl. turbo; compare with `run_loader_sim` data.
3. Port saving (`save.c`, recorder events), snapshots (`snap.c`), browser/save dialog, BT menu (drop the UART).
4. Remove PicoRV32, firmware RAM, UART and SD SPI master from the RTL; update docs (SD_TAPE_LOADER, Architecture,
   Connection, Keys) and `Extended/` (microSD to the ESP32, link pins on J1).
5. Later: second core (C64) reusing the ESP32 firmware's common part (SD, browser, OSD, BT, link).

## Session log
### 2026-10-05 (end of day)
Done: steps 1, 2, 3a (SDRAM controller 112 MHz, 256 KB window, passes sim + hardware); SDRAM chip confirmed plain -6;
T80 (MiSTer @af0e6723) copied to T80/, CEN approach analysed and confirmed (docs/T80_CEN_ANALYSIS.md), T80 alone
measured 63.5 MHz on EP4CE15 C8 (tests/t80_fmax); I/O pinout for the user's adapter agreed (docs/BOARD_PINOUT.md,
all on U7: VGA 2-bit RGB + syncs, AY PWM + separate beeper, keyboard RX/TX, tape in, turbo, reset, 50/60, Kempston,
ROM select); docs: SDRAM_TUTORIAL.md/.docx (incl. development history), SDRAM_CONTROLLER.md.
Waiting on the user: soak-test result; adapter wired to U7 and header power pins checked with a meter.
Next: step 3b — flash->SDRAM ROM loader (128K ROM @0x100000, DiagROM @0x108000 -> SDRAM 0x20000/0x28000),
.jic with ROM hex, ROM select = on-board KEY1 (Y13) held during reset/power-up -> DiagROM, else 128K ROM
(agreed 2026-10-06; machine reset = on-board KEY0 W13);
then step 4 (Z80 bridge).

### 2026-10-06
Done: indexed the user's I/O adapter `QM_Atrix_adapter/` (KiCad, made for a QMTECH Artix-7 board, 2x25 headers) ->
docs/QM_ATRIX_ADAPTER.md (files, header netlist, circuits, schematic-vs-PCB, mapping to the U7 proposal).
Facts confirmed by the user:
- The KiCad files are from Mar 2024 and were auto-converted to KiCad 10 today; the PCB/gerbers are close to the
  built board but not exact (the schematic's U1 7803 and Turbo 680 Ohm pull-up are missing from the PCB file, yet the
  pull-up is fitted on the real board -- see correction below; R numbering differs after conversion).
- Keyboard module: 5 V is only USB power pass-through; UART levels are 3.3 V.
- Tape_out never used (tape is load-only). DB9: only a plain joystick (no autofire) -> pin 7 tied to Right is harmless.
- VGA DAC (130/340 Ohm, ~1.46 V full scale) worked fine on the Artix board -> keep as is.
- Machine reset = FPGA board's own reset button -> on-board KEY0 (W13); U7.21 RESET_BTN_N not needed with this adapter.
- ROM select: not on the adapter (it was a production board) -> must be implemented differently, method TBD.
  AGREED: on-board KEY1 (Y13) held during reset/power-up -> DiagROM, otherwise 128K ROM
  (no extra hardware; optionally a USB-keyboard hotkey later). U7.28 ROM_SEL dropped.
Open (user's decision): how the adapter physically connects to the Cyclone IV board (it does not fit the U7/U8
2x32 headers).
- Turbo input polarity (user, 2026-10-06): **active low**. The SD card loader (tape simulator), when connected,
  pulls the pin low for turbo and releases it for normal speed; when no loader is connected the pin must read high
  (= normal), which was done with a pull-up. The 680 Ohm pull-up is fitted on the real adapter (user,
  2026-10-06: missing from the PCB file, version mismatch); FPGA weak pull-up ON as well (as the reference .qsf). Synchronise it
  (2-FF) and debounce/filter it before it changes the CEN increment. Earlier "high = turbo" in this plan was wrong.
- Correction (user, 2026-10-06): the KiCad PCB file does not fully match the real adapter. The 680 Ohm Turbo
  pull-up IS fitted on the real board. The 7803 (5 V -> 3v3) is fitted too (user, 2026-10-06), so the
  adapter needs only 5 V + GND from the Cyclone board; do not tie the host 3V3 to the adapter's 3v3 rail.
- The user's last adapter schematic/PCB revision was lost; the KiCad files are an earlier revision (explains the mismatch).
- Plan (user): plug adapter J2 (VGA, tape, turbo, keyboard) straight into a Cyclone header so the analog VGA path stays
  rigid; J1 (joystick, audio, 50/60) via wires. Alignment analysis in docs/QM_ATRIX_ADAPTER.md: recommended = J2 reversed
  with pin 1 at the VIN end (5 V/GND come through the header), provided J2.2 is isolated (meter check). The U7 pin
  assignment in BOARD_PINOUT.md must be redone once the physical fit is chosen.
- Decision (user): ROMs stay in SDRAM, loaded from flash at boot (original plan). Block-RAM ROM was considered and
  rejected so the design isn't tied to the EP4CE15's block RAM (option to move to a smaller FPGA).
- Turbo is only used for loading software, so 1-clock SDRAM stalls are irrelevant there (agreed with the user). The ROM
  loader's pulse-timing loop has no RAM accesses and runs from one SDRAM row. INT as in the reference: 50 Hz mode = from
  VGA vsync (real-time 50 Hz, also in turbo); 60 Hz mode = every 70000 CPU clocks (scales with turbo). Pulse = 32 CPU
  clocks. Implementation rule: count INT width and the 70000 period in CPU CEN pulses, not system clocks.
- Prototype hardware fit (user, 2026-10-06; prototype only, not the final design): adapter J2 plugged into U8 with
  J2 pin 1 on U8.64 (J2.2 cut), J1 outside the board and wired to U7. VGA/tape/turbo/keyboard on U8, joystick/audio/
  50/60 on U7. AB17/AA17 are tied to GND by the adapter: never drive high. Pin tables in docs/BOARD_PINOUT.md.
- VGA_TEST/ created (adapter bring-up): colour bars, 640x480 at 60 Hz (800x525) or 50 Hz (850x588, 50.02 Hz) on one
  25 MHz pixel clock, switch S1 (U7.22). Built + simulated. Waiting on the user: hardware test on the monitor.
- VGA_TEST first hardware try: "Input not supported" in both S1 positions. The LED showed 50 Hz all the time: S1 had no
  effect (D2/U7.22 wiring to check), and 850x588 (29.4 kHz line) is likely below the monitor's range. Changed 50 Hz to
  800x625 (31.25 kHz, 50.00 Hz), KEY1 now swaps 50/60. For the ZX: INT from vsync at 50.00 Hz (real 128: 50.02 Hz).
- 800x625@50 was shown by the user's monitor as "800x600@50" (picture squeezed to the top); 640x480@60 works. A true
  640x480@50 is not possible on analog VGA (the monitor picks the mode from H/V rate + line count). Agreed: 50 Hz =
  720x576@50 (576p, 27 MHz); 60 Hz stays 640x480 (25 MHz); pixel clock switched with the global clock control block
  (sequenced, video reset during the switch). For the ZX at 50 Hz: 512x384 screen + 104 px / 96 line borders.
- VGA_TEST passed on hardware (2026-10-06): 640x480@60 normal; 576p (OSD "800x600@50") centred vertically, sharp.
  Open: S1 (50/60) has no effect -> check the J1.5 -> U7.22 (D2) wire; then program VGA_TEST.jic as the safe flash image.
- S1 had no effect because it was miswired (user). Kept unwired for now: 50/60 is chosen with KEY1 (SW2, Y13); weak
  pull-up on D2 so the floating input reads a steady 50 Hz. Wire S1 (J1.5 -> U7.22) later; it overrides the pull-up.
- ROMs extracted to roms/ (zx128.rom, diagrom_v159.rom; hashes match this plan).
- ASpectrum/ created: the full ZX Spectrum 128K (steps 3b, 4, 5 and the U8/U7 pinout in one design; see ASpectrum/README.md).
  Builds clean (4,563 LEs, timing met, fully constrained). Sim: loader copies the bit-reversed flash image correctly
  (the .jic really stores user hex data bit-reversed -> loader auto-detect), 128K ROM boots (RAM test through all
  pages, INT every 70908 T, turbo 27.4 MHz effective). Next: hardware bring-up (program ASpectrum.jic once).
- ASpectrum works on hardware (2026-10-06, first try): 128K boots to the menu, user: "works just fine".
  Not yet tested by the user: full keyboard, DiagROM, turbo loading, AY/beeper, joystick (J1 wiring), tape.
- Final ASpectrum resources on EP4CE15: 4,563 LEs (30 %; T80 2,490, AY 486, SDRAM 428, keyboard 366, bus 334,
  video 167, loader 126), 17/56 M9K, 2 PLLs. Fits EP4CE10 comfortably, EP4CE6 at ~73 %.
- Smaller-board candidate (user, 2026-10-06): "Cyclone4 FPGA Core Board EP4CE6F17", 78x48 mm: 50 MHz clock,
  16 Mbit SPI flash (2 MB -> ROMs stay at 0x100000; .cof device EPCS16), 128 Mbit SDRAM = W9812G6KH-6
  (4 banks x 4096 rows x 512 cols x 16, A0-A11, CL2 to 133 MHz: drop-in for sdram_ram), 102 user I/O, one button.
  Port plan: new .qsf (device + pins from the vendor demo/schematic), SDRAM A12 unconnected, reset = the button,
  DiagROM select + 50/60 swap via keyboard hotkeys (proposed: F12 swap, hold F1 at reset = DiagROM) and/or S1;
  check header bank voltage (3.3 V), re-check timing at 73 % fill, add the W9812G6KH datasheet to docs/vendor/.

### 2026-10-08
- Agreed: internal SD tape loader replaces the external MCU loader. PicoRV32 (not Nios: no vendor lock-in) at 112 MHz
  from M9K, plays unmodified .tap/.tzx (no PC preprocessing), pulse FIFO counted in CPU CEN ticks (exact at 1x and 8x),
  loader keys on the keyboard numpad (F-key fallback, optional separate LOADER button on a U7 pin opens the menu without a keyboard; no long/short-press dual use), OSD replaces the
  LCD. Prototype SD adapter: Adafruit 5683 MicroSD BFF (bare socket; add caps, MISO pull-up). DivMMC/esxDOS rejected. ~1,700 LEs + ~20-29 M9K: fits EP4CE15/
  EP4CE10, not the EP4CE6 candidate. Full design: docs/SD_TAPE_LOADER.md.
- Hotkeys assigned: F12 browser, F9/F10/F11 navigate/play, F1 at start = DiagROM, F8 = 50/60, Ctrl+Alt+Del = reset;
  KEY1 retired (user). Adafruit BFF: only TX (= CS via SJ2) used. BFF wired (user): MOSI AA13, MISO AA14, SCK AA15,
  CS_N AA16 (U8.7/9/11/13), caps fitted.
- SD tape loader implemented: PicoRV32 at 56 MHz (user left 56 vs 112 to us), firmware in ASpectrum/fw
  (FAT16/32, TAP + TZX incl. loops/jumps/calls, OSD browser), pulse player with gapless command chaining and
  T-state crediting, F1/F8/Ctrl+Alt+Del in RTL, KEY1 unused. PC tests (3 card layouts, every signal vs an
  independent Python reference) and RTL sims pass. Loads games on hardware (user).
- Same day, all working on hardware (user): F7 / keypad * Stop; browser 400 entries (32 KB RAM, RV32IMC);
  saving = recording mode ([Save to this folder] + 8.3 name, every ROM-format block into one .tap until F12;
  MIC recorder holds the Z80 while the firmware is busy); F6 = turbo / normal speed for loading and saving.
  First save version (dialog after the header, end after 3 s) split header/data into two files because the ROM's
  1 s inter-block pause (real-time 50 Hz INTs) is 8x longer in turbo T-states -> replaced by start/stop.
  End-to-end sim: 128K ROM loads a BASIC program from the SD image (first attempt had too-short test pilots: the
  ROM's LD-WAIT needs ~3.5 M T before the leader). Build: 8,379 LEs (54 %), 55/56 M9K, worst slack +0.47 ns.
  Docs: KNOWN_ISSUES.md, ASpectrum_Keys.docx, ASpectrum_Architecture.docx (Letter; generators in docs/src).

- GitHub: https://github.com/alexlutsenko7/ASpectrum.git (user commits from a separate folder). Checked from a fresh
  clone: complete (T80, sim, fw/test added), firmware rebuilds identical, PC tests + loader sim pass. Cosmetic left:
  .sh files without the executable flag, 32 leftover files tracked (VGA_TEST/sim/work, transcripts, a log, .qws), no
  .gitignore. Top-level README.md written (AlteraZX/README.md, to be copied to the repo root).
- Game sources: archive.org "World of Spectrum June 2017 Mirror" (92.8 GB zip, torrent
  https://archive.org/download/World_of_Spectrum_June_2017_Mirror/World_of_Spectrum_June_2017_Mirror_archive.torrent);
  worldofspectrum.net is not wget-able (WordPress pages, files on spectrumcomputing.co.uk); spectrumcomputing.co.uk
  robots.txt disallows everything except /entry/ -> manual downloads only.

### Next session
- Open items: docs/KNOWN_ISSUES.md (SD card once not recognised, keyboard once dead at power-up). Block RAM is
  55/56: further block-RAM features would need the SDRAM (e.g. folder list there).
- Still to test from v1: keyboard, AY/beeper + joystick (J1 wiring), external tape (TURBO_N).
- EP4CE6F17 port deprioritised (user, 2026-10-08: too small once the SD loader is in). Possibly: floating bus.

## Session log 2026-10-09

- Video: not all monitors accept 576p50 (user). Power-up mode is now 640x480@60 and only F8 swaps; the S1 switch
  input (SW_50_60, D2) was removed (pin unused). Build timing clean.
- Snapshots (user: .z80 format, F2 saves with a typed name, loading through the F12 browser, no quick slots):
  zx_bus freezes the CPU at an instruction boundary (M1 T2, not INTA, no prefix pending) and offers a command port
  (SDRAM byte, T80 REG words, DIR + LOAD = T80-only reset + DIRSet, AY, ports, state) to the loader CPU; fw/snap.c
  writes .z80 v3 (128K, compressed) and loads v1-3 (48K/128K). Loader RAM became full: -msave-restore, stack
  reserve 1.25 KB (measured ~0.75 KB), browser 400 -> 350 entries. Build: 9,020 LEs, worst setup +0.51 ns.
  Tests: PC host test (reference files + round trips, independent decoder), tb_snap (random freezes / restores vs an
  undisturbed run, turbo and normal speed), whole-machine F2-save / F12-load simulation with the firmware.
  Works on hardware (user, 2026-10-09).
- Aquaplane horizon confirmed on hardware at frame INT 24.1 (line 24, pixel 166) with Level-1 contention: the default.
- Open: a 50 Hz mode for the user's worst TV (rejects 576p50 on VGA). Waiting for its VGA (analog) EDID from MonInfo.
  Analysis so far: 1080p50 is possible on analog VGA at 29.7 MHz (1 clock per Spectrum pixel = 5 screen pixels,
  528 x 1125 clocks, 56.25 kHz / 50.00 Hz, third PLL, 3rd clkctrl input). Catch: with 5 lines per Spectrum row the
  TV beam is ~40 % slower than the Spectrum's, so one INT delay aligns border effects at one height only (Aquaplane
  OK, multi-band / loading stripes drift up to ~8 rows); 3.6 lines per row (4/3 alternating, 691 lines) keeps them
  exact; a border buffer would decouple them but needs ~3 M9K (1 free). 576p stays the exact mode.
- Level-1 contention (F5) and the floating bus (same switch) added; DiagROM's floating bus test was failing before
  (snow test fails by design, not emulated). Sidewize (syncs with the floating bus) works on the hardware.
- Game collection cleanup (tools/sort_games.py, then by hand): 31 broken / bad-checksum TAPs, 1,565 TAPs that have a
  TZX of the same game, 327 TAPs with PAUSE 0 in their BASIC loader (Aqua Plane.tap: a modified emulator version
  that waits for a key with invisible text), and a C64 tape (Sidewize.tap) deleted; list in Games/deleted_taps.txt.
- Analysed, not done (user: not worth it now): TZX 0x19/0x18 (1 / 0 files in the collection), 48K timing mode (a real
  128K keeps 128K timing in 48 BASIC; auto-switch on 7FFD lock or a machine key would be "better than real").
- Game names shortened to the browser's 27 characters (tools/shorten_names.py: abbreviations S1/P2/Alt, brackets
  dropped, middle cut keeping the side/part; clashes get a publisher tag or " 2"): 4,561 files, list in
  Games/renamed_files.txt.
- Game tools keep .z80 / .z80.zip (snapshots load from the browser) and honour Games/protected.txt (names never
  deleted, renamed or moved; first entries: the user's Sidewize.z80 / Sidewize[a].z80 in games/s2).

### 2026-10-11
- Lag seen on 9 October was the TV's (user tested other monitors and a PC).
- Sidewize: the player flickered (~60/40, irregular) on all monitors in 50 Hz mode; clean in a 128K emulator. Not the
  display: moving the INT (PgUp/PgDn, 0..50) changed nothing, F5 off freezes the game (it waits on the floating bus).
  Cause: Sidewize polls port 40FF (IN A,(C) ; CP E ; JP NZ, 35 T) for attribute 40h (row 16) / 03h. Fuse 1.6
  (peripherals/ula.c, periph.c) reads the port after all I/O contention, at the start of the 4th T-state; a
  contended poll then sees only an attribute or FF. zx_bus sampled at T2 (after the T1 contention only): half of the
  polls saw bitmap bytes, a pixel byte 40h/03h ended the wait early. Fix in zx_bus: read point predicted at T2 from
  hpos + the remaining contention (2 pipeline stages, sample at chk[1]; a one-clock version failed timing by 2.5 ns),
  phase origin 14362 as Fuse. tb_float model changed to Fuse's rule (passes). New sim/tb_floatgame.sv +
  run_floatgame_sim.sh + mk_z80img.py: a .z80 game on zx_bus + T80, every floating-bus read vs Fuse (~1 min/frame).
  Build 9,338 LEs, +0.57 ns. Confirmed on hardware (user): Sidewize no flicker, Arkanoid and Cobra work.
- Not changed: Fuse also contends ports C000-FFFF while an odd RAM page is paged in; io_c only contends 40-7F.
- Game collection re-sorted (tools/resort_games.py, moves only): files grouped by first character (a-z, else 123),
  browser order, ceil(n/300) folders per letter, evenly filled; 5,922 of 15,965 files moved, 32 renamed " (n)" for
  same-name clashes in one group, 8 empty folders removed; log Games/resort_moves.log (undo possible).
- Question answered: Bluetooth audio out = original ESP32 (WROOM-32 DevKit, Classic BT; S2/S3/C3 cannot) as A2DP
  source, I2S from the FPGA (ESP32 as I2S master), UART to the PicoRV32 for pairing/PIN in the OSD; KCX_BT_EMITTER
  rejected (no PIN devices). User found a 30-pin WROOM-32 CP2102 Type-C board; not built yet. Latency ~150-250 ms (SBC).

### 2026-10-13
- Bluetooth audio built. ESP32 sketch `AAudio/AAudio.ino` (Arduino core esp32 3.3.2, ESP32-A2DP v1.8.11 from GitHub):
  A2DP source, audio from I2S (ESP32 = master: BCLK GPIO26, WS GPIO25, DIN GPIO22) or a test tone; text commands
  on USB and UART2 (GPIO16/17, for the PicoRV32 later), CRLF output, settings in NVS. PIN devices: legacy PIN
  requests answered with 0000/1234/8888/1111 in turn or a fixed `pin`; BT 2.0 devices (no EIR) listed by name request
  or MAC (library filter overridden); discovery stopped while connected; 16-digit PIN overflow in the library avoided.
- FPGA: `rtl/bt_i2s.v` in zx_system (AY + beeper, two one-pole low-passes at the AY rate, DC blocker per sample,
  Philips I2S slave, synchronised BCLK/LRCK); pins U7.17 H1 BT_BCLK, U7.18 H2 BT_LRCK, U7.19 F1 BT_DATA; U7.20 F2 /
  U7.21 E1 reserved for the ESP32 UART. sim/run_bt_i2s_sim.sh passes (16/32-bit slots). Build 9,498 LEs, 74 pins,
  +0.43 ns. Not yet tried on hardware.
- Bose headphones crashed the ESP32 in 38/40 connects: IntegerDivideByZero in SBC_Encoder_Init (ESP-IDF 5.5). When the
  sink opens/configures the stream itself with the standard SBC config, Bluedroid never fetches its capabilities,
  bta_av_co_audio_set_codec fails and the encoder stays zero. A first fix (calling btc_a2dp_source_setup_codec at
  "connected") asserted (link not yet open). Final fix: -Wl,--wrap=bta_av_co_audio_set_codec (library
  AAudio/libraries/AAudioLinkFix: Arduino passes ldflags only for a precompiled library with a stub archive), the
  wrapper reports success while connected. Confirmed by the user: connects, test tone plays.
- User: the Bluetooth device must be chosen from ASpectrum, USB only for debugging. Added: F3 = Bluetooth menu
  (fw/bt.c: scan, connect, disconnect, forget, PIN, volume, Spectrum sound / test tone; tape keeps playing), UART in
  tape_loader (reg 0x3C, 115200, 512-byte RX FIFO in an M9K; BT_TX F2 = U7.20, BT_RX E1 = U7.21), loader key bit 16
  (F3). ESP32 sketch: `info` one-line state, `scan` drops the link first.
- Firmware no longer fitted 32 KB (19.4 KB code). User pointed out unused block RAM: the screen shadows took 8 M9K
  each (8K x 1 slices) and JT49's 128 x 8 table a whole M9K. A 36 KB lane RAM (9 M9K per lane) made synthesis leave
  the PicoRV32 register file in logic (~1,800 LEs, +0.13 ns): its M9K estimate (shadows at 8) said "full". Final:
  shadows and a 3 KB RAM extension (768 x 32, byte enables, maximum_depth 256 = 3 M9K) as explicit altsyncrams
  (`ifdef ALTERA_RESERVED_QIS`, arrays in simulation), JT49 table in logic (QSF AUTO_ROM_RECOGNITION OFF),
  browser 350 -> 320 entries. 56/56 M9K, 9,829 LEs, +0.71 ns, hold +0.15 ns.
- UART bugs found in simulation (tb_tape_loader + ESP32 model): the stop bit lasted 1-2 clocks between bytes
  (busy ended at its start); OSD redraws (~1.6 ms) overran a 16-byte RX FIFO (now 512); menu redraws on ESP32
  lines and PIN typing. SystemVerilog has no "\r" escape (use "\x0d").
- Full run_loader_sim.sh (19 min) with the final firmware: tape signal 168 segments / 0 mismatches, stop, recording
  (file checked on the card image), speed, and the Bluetooth menu all pass (the menu-closed check had to look at
  osd_full: the "Speed: turbo" row from the step before stays on the bottom line). +define+BT_ONLY run: PASS.
- New document docs/ASpectrum_Connection.docx (all wiring); Architecture and Keys documents updated.
- User: TAPE_IN and TURBO_N (the adapter's tape header, for the old external tape simulator) are not used any more:
  removed from the design (ports, zx_bus EAR hold logic: EAR = loader while it plays, else the beeper; turbo = loader
  only; zx_system FORCE_TURBO parameter for the whole-machine testbench), QSF/SDC and all documents
  (QM_ATRIX_ADAPTER.md keeps the hardware description, marked "not used by ASpectrum"). zx_system: cont_on is now
  declared before its first use (Questa vlog-2388); run_sim.sh compiles bt_i2s.v.
- That build failed timing by 0.16 ns (SDRAM request path, placement only; same logic was +0.71 ns before): QSF
  OPTIMIZATION_MODE "HIGH PERFORMANCE EFFORT" -> 9,753 LEs, 74 pins, 56/56 M9K, +0.60 ns, hold +0.16 ns.


### 2026-10-13 (later): Extended I/O board (KiCad, `Extended/`)

- Discussed other machines on this FPGA (C64 without the 1541 likely fits; the 2-bit VGA DAC cannot show the C64
  palette -> 4-bit DAC; second joystick port). User asked for a new I/O board in `Extended/` (QM_Atrix_adapter/ untouched).
- User decisions: separate board wired to the FPGA board (no plug-in headers), 4-bit DAC (523/1.05k/2.1k/4.22k,
  0.7 V full scale), two standard right-angle DB9 male (pin 7 open), microSD socket on the board, 7803 switching module
  (5 V in), no 50/60 switch, no tape header, no audio amplifier (two volume pots -> 3-pin audio-out header), keyboard
  module with its USB end past the board edge, ESP32 30-pin dev board (DOIT pinout, CP2102 USB-C) on 2x 1x15 sockets,
  host header J1 = 2x32 (same size as U7/U8): pins 1-40 as before + 41-45 BT_BCLK/LRCK/DATA/TX/RX, 46/63/64 GND.
- Footprints checked against JLCPCB/LCSC stock: VGA = CONNFLY DS1038-15F (C75754; 2.29x2.54 rows -> new local
  footprint, flange flush with the edge, pin rows 8.63/11.17/13.71 mm); DB9 = CONNFLY DS1037-09M (C75750; fits the
  KiCad 7.70 footprint, flange 0.4 mm past the edge); microSD = Molex 104031-0811 (C585350). All "Extended" at JLCPCB.
  ESP32 and keyboard modules are bought separately (not JLCPCB parts).
- Layout iterated with the user (the user moved parts; I adjusted the outline, labels, nets). Final 84.1 x 83.43 mm,
  routed on 2 layers with FreeRouting 2.5.0 (no neckdown; +5V 0.4 mm, GND/+3V3 0.3 mm, signals 0.25 mm), GND pours on
  both layers, user's stitching vias. DRC: 0 unconnected, 0 clearance, 0 schematic-parity; left: DB9 outlines at the
  edge, 5 single-spoke thermals (J1.3/20/40/46, RV2.3) that also have GND tracks.
- Open: user review of the routed board; optionally pick a JLCPCB 1x15 female header for the ESP32 sockets; FPGA pin
  assignment for the 2x32 J1 wires (docs/BOARD_PINOUT.md) and the 4-bit VGA in ASpectrum when the board is built.

### 2026-10-13 (evening): cheaper FPGA? -> ESP32 system controller
- Question: move SD/loader work to the ESP32 and use a cheaper FPGA. Current loader: tape_loader 3,953 LEs / 40 M9K,
  of which PicoRV32 2,594 LEs, firmware RAM 35 M9K.
- Trial build (throwaway copy, deleted): EP4CE6F17C8 (6,272 LEs, 30 M9K, 2 PLLs), PicoRV32 + RAM replaced by an
  SPI-slave bus master, everything else unchanged (JT49, keyboard, SD SPI, BT UART): **6,311 combinational cells
  -> does not fit** (39 over); speed / balanced / aggressive-area synthesis all gave 6,311. Memory 145,920 bits,
  2/2 PLLs, 78 pins would have fit. Big users: T80 2,585, zx_bus 710, tape_loader rest 903, keyboard 499,
  JT49 450, sdram_ram 405, video 316. EP4CE10 would fit; DDR boards were considered and rejected.
- User: stay on the EP4CE15; block RAM matters, not LEs; future C64 core. Firmware RAM today: 19.4 KB code,
  11.5 KB browser list (320 x 36 B), ~2.1 KB SD/FAT buffers, stack 1.25 KB. Keeping PicoRV32 with SD/FAT on the
  ESP32 would save only 11-15 M9K; removing PicoRV32 saves ~38. Decision: the latter (section "Next stage" above).
- Next session: user wires the SD card to the ESP32 and the SPI link to U7.7-11 (table above); then step 1.
- Step 1 built the same evening (user: build now, any ESP32 pins): `rtl/esp_link.v` (SPI slave, mode 0, SCK <= 8 MHz
  oversampled at 56 MHz; WR/RD/OSD/FIFO/MWR/MRD/STAT; MWR/MRD bursts = one snapshot command per byte, MRD
  prefetched; sticky error flag), in `tape_loader` under `ESP_LINK` (PicoRV32 + RAM out, SD SPI writes off,
  reg 0x00 = core ID 5A580001, reg 0x04 = IRQ causes/mask; esp_irq pin). Quartus revision **ASpectrum_ESP**
  (`ASpectrum_ESP.qsf`, VERILOG_MACRO ESP_LINK; pins ESP_MISO R1, ESP_IRQ R2, ESP_SCK P1, ESP_MOSI P2, ESP_CS_N N1;
  SD pins dropped; `ASpectrum.sdc` picks the ESP or SD false paths by port existence; `ASpectrum_ESP.cof` -> .jic).
  Build: 7,520 LEs, **19/56 M9K**, 75 pins, +0.39 ns / hold +0.16 ns, fully constrained.
  sim/run_esp_link_sim.sh (tb_esp_link: ID, register R/W, OSD, FIFO, 256-byte MWR/MRD across a page, error flag
  with slow commands, IRQ on key change): PASS. The sim found an MRD bug (saturating byte counter + 1 wrapped:
  bursts stopped after 11 bytes), fixed. ESP32 test sketch `ESPLinkTest/` (id, rd/wr, stat, ls -> OSD, keys via
  IRQ, memtest over the frozen screen, speed); compiles (343 KB). Not yet on hardware.
- 2026-10-14: user wired the ESP32 (link U7.7-11, SD moved to the ESP32). Test_wires/ (FPGA .sof + ESP32 sketch,
  report on USB) found the SD SCK joint bad; after re-soldering ALL WIRES OK (10 link/BT wires: levels, 2 MHz pulses,
  8 MHz SPI, no crosstalk; SD at 20 MHz). Then ASpectrum_ESP.sof + ESPLinkTest on hardware: core ID 5a580001, timer,
  SD ls + OSD, memtest 5 rounds 0 errors, MRD 914 KB/s, link stat 0. Step 1 works; `keys` F1-F12 OK (HID 3A-45, KEYS bits as fw/hw.h).
- 2026-10-14 (later): step 2 by porting, not rewriting: AAudio runs the loader firmware (ASpectrum/fw, compiled as
  C++, register proxies over the link) next to Bluetooth; one ESP32 firmware for both FPGA builds (loader only when
  the link answers 5A580001). Casts added in fat.c/util.c for C++ (PicoRV32 fw.bin byte-identical). Flash now holds
  ASpectrum_ESP.jic. On hardware: loader starts, SD mounts at 20 MHz, BT stays responsive; user confirmed
  the same day that everything works (F12, tapes, .z80, F2, F3).
