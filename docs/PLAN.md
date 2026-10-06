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
