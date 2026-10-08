# ASpectrum — ZX Spectrum 128K on the QMTECH Cyclone IV (EP4CE15) board

Prototype hardware: QMTECH EP4CE15F23C8N core board + the user's QM_Atrix I/O adapter
(adapter J2 plugged into U8, J1 wired to U7; pin tables in `../docs/BOARD_PINOUT.md`).
Architecture and decisions: `../docs/PLAN.md`, CPU clock-enable analysis: `../docs/T80_CEN_ANALYSIS.md`.

## What it is

| Part | Implementation |
|---|---|
| CPU | T80 (MiSTer @af0e6723, `../T80/`) in `cpu_t80` (single clock enable), 3.5469 MHz, or 28 MHz while TURBO_N is low |
| System clock | 112 MHz (sys_pll); CPU stepped by a phase accumulator; SDRAM stalls hold the clock enable (turbo only) |
| RAM + ROM | W9825G6KH SDRAM via `sdram_ram` (DDR_TEST, proven at 112 MHz): RAM pages 0-7, ROM 0/1, DiagROM |
| ROMs | in the configuration flash at 0x100000 (in the .jic), copied to SDRAM at power-up/reset by `rom_loader` (~14 ms) |
| Video | 640x480@60 (25 MHz) or 720x576@50 (27 MHz) VGA, 2-bit RGB, from block-RAM shadows of pages 5/7 |
| Sound | AY-3-8912 (JT49, GPL-3) at 1.7734 MHz -> sigma-delta on AUDIO_AY; beeper on AUDIO_BEEPER |
| Keyboard | USB keyboard via the CH9350-style UART module (115200), packet format as the DE10-Lite reference |
| Joystick | Kempston (port 1F) |
| Tape | TAPE_IN on the EAR bit (port FE bit 6), as the reference |
| SD tape loader | PicoRV32 (RV32IMC) at 56 MHz + firmware in `fw/`: OSD file browser (400 entries), plays .tap/.tzx from a microSD card T-state exact, records SAVE output into .tap files; turbo or normal speed (`../docs/SD_TAPE_LOADER.md`) |

## Controls

| Control | Function |
|---|---|
| KEY0 (W13) | reset: CPU, ports, ROM reload, tape loader. The video mode is kept. |
| Ctrl+Alt+Del | reset of the Spectrum only (the tape loader keeps running) |
| F1 | **held while the CPU starts** (power-up, KEY0, Ctrl+Alt+Del): DiagROM instead of the 128K ROM |
| F8 | swap 50/60 Hz video |
| F12 / keypad / / NumLock | SD tape loader browser (keys: `../docs/SD_TAPE_LOADER.md`); keypad 5 / F11 pause-continue, keypad - back one block, F7 / keypad * stop. First browser line [Save to this folder]: name, then recording until F12 |
| F6 | tape speed for loading and saving: turbo (default) / normal |
| KEY1 (Y13) | not used |
| S1 50/60 | default video mode (high = 50 Hz). Not wired yet: weak pull-up -> 50 Hz. |
| TURBO_N | low = 28 MHz CPU (external tape simulator; pull-up = normal speed). The SD loader sets turbo itself while playing or saving a block (unless F6 chose normal speed). |
| LED | on = turbo; fast blink = no ROM image in the flash (program the .jic) |

Keyboard: letters, digits, Enter, Space; Left Shift = CAPS SHIFT; Right Shift / Ctrl = SYMBOL SHIFT;
Backspace = DELETE, arrows = cursor keys, Esc = BREAK. While the tape browser is open the Spectrum sees no keys.
At power-up the CPU waits for the first keyboard packet (at most 1.5 s) so a held F1 is seen.

## Files

| Path | Role |
|---|---|
| `ASpectrum.qpf/.qsf/.sdc` | Quartus project, pins, constraints (SDRAM I/O as DDR_TEST, CPU multicycles, clock groups) |
| `ASpectrum.cof`, `roms48k.hex` | `.jic` recipe: bitstream + ROMs (128K set + DiagROM, 48 KB) at flash 0x100000 |
| `sta_report.tcl` | `quartus_sta -t sta_report.tcl`: unconstrained ports, worst paths, CPU multicycle check |
| `rtl/ASpectrum.v` | top: PLLs, resets (power-up / machine / tape loader), SDRAM clock (DDIO) and DQ, video clock switch (as VGA_TEST), F8/S1 handling |
| `rtl/zx_system.v` | the machine without PLLs: SDRAM, loader, bus, AY, keyboard, video, LED |
| `rtl/zx_bus.v` | CPU clock enable, bus bridge (speculative read at T1, posted writes, stall), paging, ports, INT |
| `rtl/cpu_t80.v` | T80 wrapper (T80se-style, exports MC/TS/decode) |
| `rtl/zx_video.v` | Spectrum picture (2x2 pixels, borders, FLASH) + screen shadows + OSD overlay |
| `rtl/zx_keyboard.v` | UART + packet parser -> 8x5 key matrix, loader keys, F1, F8, Ctrl+Alt+Del |
| `rtl/tape_loader.v` | SD tape loader: PicoRV32, 32 KB RAM (firmware from `fw/build/fw0..3.hex`), SPI, command FIFO, pulse player, MIC recorder with CPU hold, OSD port |
| `rtl/picorv32/` | PicoRV32 (YosysHQ, ISC licence), unmodified, see SOURCE.md |
| `rtl/osd_font.hex` | OSD font (Spectrum character set, made by `fw/tools/mkfont.py` from `../roms/zx128.rom`) |
| `fw/` | loader firmware (C, RV32IMC): `build.sh`, browser `main.c`, `sd.c` (read/write), `fat.c` (read, create files), `tape.c` (TAP/TZX), `save.c` (recording); `test/` PC tests; `tools/` image/test generators, FAT checker |
| `rtl/rom_loader.v`, `rtl/flash_if.v` | flash READ -> SDRAM; bit-order auto-detect (the .jic stores the data bit-reversed) |
| `rtl/sd_dac.v` | sigma-delta audio DAC |
| `rtl/sdram_ram.v`, `rtl/sys_pll.v` | copies from DDR_TEST |
| `rtl/vga_pll.v`, `rtl/vga_clkmux.v`, `rtl/vga_timing.v` | copies from VGA_TEST |
| `rtl/jt49/` | JT49 AY core (Jose Tejada, GPL-3), as used in the reference |
| `sim/run_sim.sh [defines]` | whole-machine Questa simulation (flash model -> loader -> SDRAM model -> T80 boot); writes `screen.png` |
| `sim/run_loader_sim.sh` | tape loader alone with an SD card model (read/write): boot, browser, play a TZX T-state exact vs the reference, Stop, recording a ROM-style save, F6 |
| `sim/run_tapeload_sim.sh` | whole machine: 128K "Tape Loader", F12, Enter: the ROM loads a BASIC program from the card image (~40 min) |
| `releases/v1_2026-10-06/` | the first hardware-proven .sof/.jic (before the tape loader) |

## Build and program

```
fw/build.sh                                  # loader firmware -> fw/build/fw0..3.hex (xPack riscv-none-elf-gcc)
quartus_sh --flow compile ASpectrum
quartus_cpf -c ASpectrum.cof                 # -> output_files/ASpectrum.jic (bitstream + ROMs)
```
The firmware is part of the bitstream (block RAM contents): after changing `fw/`, run `fw/build.sh` and compile again.
Program `output_files/ASpectrum.jic` once (Programmer, JTAG, Program/Configure, power-cycle): it puts the
ROMs into the flash. After that, `.sof` loads over JTAG are enough during development (ROMs stay in flash).
If the LED blinks fast after loading a .sof, the flash has no ROM image: program the .jic.

## Known limitations (first version)

- Floating bus not emulated (unused ports read FF); no memory contention; border/multicolour effects are not
  T-state exact (VGA is not locked to the Spectrum frame). Same as the DE10-Lite reference.
- Keyboard module UART direction not confirmed: both lines are inputs with pull-ups, RX = KBD_A AND KBD_B
  (works whichever line carries the data). Nothing is sent to the module.
- Joystick, AY/beeper audio and S1 need the J1 -> U7 wiring.
