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

## Controls

| Control | Function |
|---|---|
| KEY0 (W13) | reset: CPU, ports, ROM reload. The video mode is kept. |
| KEY1 (Y13) | **held while the CPU starts** (power-up, or while releasing KEY0): DiagROM instead of the 128K ROM. **Pressed while running**: swap 50/60 Hz video. |
| S1 50/60 | default video mode (high = 50 Hz). Not wired yet: weak pull-up -> 50 Hz. |
| TURBO_N | low = 28 MHz CPU (driven by the SD card loader; pull-up = normal speed) |
| LED | on = turbo; fast blink = no ROM image in the flash (program the .jic) |

Keyboard: letters, digits, Enter, Space; Left Shift = CAPS SHIFT; Right Shift / Ctrl = SYMBOL SHIFT;
Backspace = DELETE, arrows = cursor keys, Esc = BREAK.

## Files

| Path | Role |
|---|---|
| `ASpectrum.qpf/.qsf/.sdc` | Quartus project, pins, constraints (SDRAM I/O as DDR_TEST, CPU multicycles, clock groups) |
| `ASpectrum.cof`, `roms48k.hex` | `.jic` recipe: bitstream + ROMs (128K set + DiagROM, 48 KB) at flash 0x100000 |
| `sta_report.tcl` | `quartus_sta -t sta_report.tcl`: unconstrained ports, worst paths, CPU multicycle check |
| `rtl/ASpectrum.v` | top: PLLs, SDRAM clock (DDIO) and DQ, video clock switch (as VGA_TEST), KEY1/S1 handling |
| `rtl/zx_system.v` | the machine without PLLs: SDRAM, loader, bus, AY, keyboard, video, LED |
| `rtl/zx_bus.v` | CPU clock enable, bus bridge (speculative read at T1, posted writes, stall), paging, ports, INT |
| `rtl/cpu_t80.v` | T80 wrapper (T80se-style, exports MC/TS/decode) |
| `rtl/zx_video.v` | Spectrum picture (2x2 pixels, borders, FLASH) + screen shadows |
| `rtl/zx_keyboard.v` | UART + packet parser -> 8x5 key matrix |
| `rtl/rom_loader.v`, `rtl/flash_if.v` | flash READ -> SDRAM; bit-order auto-detect (the .jic stores the data bit-reversed) |
| `rtl/sd_dac.v` | sigma-delta audio DAC |
| `rtl/sdram_ram.v`, `rtl/sys_pll.v` | copies from DDR_TEST |
| `rtl/vga_pll.v`, `rtl/vga_clkmux.v`, `rtl/vga_timing.v` | copies from VGA_TEST |
| `rtl/jt49/` | JT49 AY core (Jose Tejada, GPL-3), as used in the reference |
| `sim/run_sim.sh [defines]` | whole-machine Questa simulation (flash model -> loader -> SDRAM model -> T80 boot); writes `screen.png` |

## Build and program

```
quartus_sh --flow compile ASpectrum
quartus_cpf -c ASpectrum.cof                 # -> output_files/ASpectrum.jic (bitstream + ROMs)
```
Program `output_files/ASpectrum.jic` once (Programmer, JTAG, Program/Configure, power-cycle): it puts the
ROMs into the flash. After that, `.sof` loads over JTAG are enough during development (ROMs stay in flash).
If the LED blinks fast after loading a .sof, the flash has no ROM image: program the .jic.

## Known limitations (first version)

- Floating bus not emulated (unused ports read FF); no memory contention; border/multicolour effects are not
  T-state exact (VGA is not locked to the Spectrum frame). Same as the DE10-Lite reference.
- Keyboard module UART direction not confirmed: both lines are inputs with pull-ups, RX = KBD_A AND KBD_B
  (works whichever line carries the data). Nothing is sent to the module.
- Joystick, AY/beeper audio and S1 need the J1 -> U7 wiring.
