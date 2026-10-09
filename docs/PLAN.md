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
