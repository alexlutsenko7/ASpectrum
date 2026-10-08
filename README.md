# ASpectrum

A ZX Spectrum 128K in an FPGA: an Intel/Altera Cyclone IV E (EP4CE15F23C8) on a QMTECH core board, with the RAM and
ROMs in the board's SDRAM, VGA output, AY sound, a USB keyboard, and a built-in SD card tape loader that plays
unmodified `.tap` / `.tzx` files and saves programs back to the card.

Status: working on hardware (October 2026).

## Features

- **ZX Spectrum 128K**: T80 Z80 core at the exact 3.5469 MHz, or 28 MHz turbo; 128 KB RAM with 7FFD paging; 128K
  ROM set and DiagROM; AY-3-8912 (JT49); beeper; Kempston joystick; 50 Hz interrupt.
- **Memory in SDRAM**: own 112 MHz controller for the W9825G6KH (open-row, CAS latency 2); the CPU is stepped by a
  clock enable and simply waits when the SDRAM is busy. The screen is mirrored in block RAM for the video.
- **Video**: VGA 720x576@50 (576p) or 640x480@60, 2 bits per colour, switchable at run time.
- **USB keyboard** through a CH9350-style UART module, with machine keys: DiagROM, 50/60 Hz, reset.
- **SD card tape loader** (RISC-V PicoRV32 soft CPU with firmware in C):
  - on-screen browser (folders, long names, up to 400 entries), FAT16 / FAT32;
  - plays TAP and TZX (incl. turbo blocks, pure tones, pulse sequences, direct recordings, loops, jumps, calls,
    stop blocks) T-state exact, in turbo (8x) or at normal speed;
  - saves: everything the Spectrum `SAVE`s goes into a `.tap` file on the card;
  - pause, back one block, stop.
- **Fully constrained timing**: every clock and I/O constrained, timing met at all corners.

## Hardware

| Part | Notes |
|---|---|
| QMTECH Cyclone IV core board | EP4CE15F23C8N, 50 MHz oscillator, W9825G6KH-6 SDRAM (32 MB), W25Q64 configuration flash |
| I/O adapter (own design) | VGA resistor DAC, audio (AY + beeper) to an amplifier, Kempston DB9, USB keyboard module (UART, 3.3 V), tape input, turbo input, 50/60 switch |
| microSD | Adafruit 5683 "MicroSD Card BFF" (bare socket, SPI), 10 uF + 100 nF added |

Pin assignments: `docs/BOARD_PINOUT.md`. Adapter: `docs/QM_ATRIX_ADAPTER.md`.

## Repository layout

| Folder | Contents |
|---|---|
| `ASpectrum/` | **The Spectrum**: Quartus project, `rtl/` (Verilog), `fw/` (tape loader firmware), `sim/` (Questa testbenches), `output_files/ASpectrum.jic` (ready-to-program image) |
| `T80/` | Z80 core (VHDL), from the MiSTer ZX Spectrum core, unchanged (`T80/SOURCE.md`) |
| `DDR_TEST/` | stand-alone SDRAM controller + memory test (the controller used by ASpectrum) |
| `VGA_TEST/` | stand-alone VGA test (colour bars, both video modes) |
| `docs/` | design notes, user documents, data sheets (see below) |

## Building

Tools: Quartus Prime 25.1std Lite (Windows), xPack GNU RISC-V Embedded GCC (`riscv-none-elf-gcc`) for the
firmware. The scripts are written for WSL on Windows and call the Windows tools; paths are at the top of each script.

```
cd ASpectrum
bash fw/build.sh                                 # firmware -> fw/build/fw0..3.hex (part of the bitstream)
quartus_sh --flow compile ASpectrum              # -> output_files/ASpectrum.sof
quartus_cpf -c ASpectrum.cof                     # -> output_files/ASpectrum.jic (bitstream + ROMs)
```

Run `fw/build.sh` before compiling whenever the firmware changes. The ROM images (`roms48k.hex`) are added to the
`.jic` at flash offset 0x100000 and copied into SDRAM at every reset.

## Programming

Quartus Programmer, JTAG, add `ASpectrum/output_files/ASpectrum.jic`, tick Program/Configure, program, then
power-cycle the board. After that, `.sof` loads over JTAG are enough during development (the ROMs stay in the flash).

## Using it

| Key | Function |
|---|---|
| F12 | tape browser (Enter loads a file; first line *[Save to this folder]* starts saving) |
| F12 while saving | stop saving and close the file |
| Keypad 5 / F11 | pause / continue the tape |
| Keypad - | back one block |
| F7 | stop the tape |
| F6 | tape speed: turbo (default) / normal |
| F8 | 50 / 60 Hz video |
| F1 held at start | DiagROM instead of the 128K ROM |
| Ctrl+Alt+Del | reset the Spectrum |
| KEY0 (board) | reset everything |

Loading: `LOAD ""` (or *Tape Loader* in the 128K menu), F12, choose the file, Enter.
Saving: F12, *[Save to this folder]*, type a name, Enter, then `SAVE` on the Spectrum as often as you like; F12 ends.
SD card: FAT32 or FAT16 (not exFAT).

The complete key list with step-by-step usage is in `docs/ASpectrum_Keys.docx`.

## Testing

```
bash ASpectrum/fw/test/run_host_test.sh          # PC: FAT reading/writing, every TAP/TZX signal vs a Python reference
bash ASpectrum/sim/run_loader_sim.sh             # RTL: tape loader with an SD card model (play, stop, save)
bash ASpectrum/sim/run_sim.sh                    # RTL: whole machine boots the 128K ROM
bash ASpectrum/sim/run_tapeload_sim.sh           # RTL: the 128K ROM loads a program from the SD card (~70 min)
```

The PC tests need a Windows gcc (w64devkit); the simulations need Questa (Intel FPGA Starter Edition).

## Documentation

| Document | Contents |
|---|---|
| `docs/ASpectrum_Architecture.docx` | architecture of the whole machine: block diagram, clocks, memory, video, tape loader, pins, timing |
| `docs/ASpectrum_Keys.docx` | all keys and usage cases |
| `docs/SD_TAPE_LOADER.md` | SD tape loader: design, registers, firmware, saving |
| `docs/SDRAM_CONTROLLER.md`, `docs/SDRAM_TUTORIAL.md` | the SDRAM controller in detail, and an SDRAM tutorial |
| `docs/T80_CEN_ANALYSIS.md` | running the T80 from a clock enable at 112 MHz |
| `docs/BOARD_PINOUT.md`, `docs/QM_ATRIX_ADAPTER.md` | board headers and the I/O adapter |
| `docs/KNOWN_ISSUES.md` | open issues and limitations |
| `docs/PLAN.md` | design decisions and development log |

## Licences

The project's own files are under the MIT licence (`LICENSE`). Third-party parts keep their own licences:

| Part | Licence |
|---|---|
| `T80/` (Z80 core, Daniel Wallner; Sorgelig) | BSD-style, see the file headers |
| `ASpectrum/rtl/jt49/` (AY-3-8910 core, Jose Tejada) | **GPL-3**: a bitstream that includes it is a GPL-3 work |
| `ASpectrum/rtl/picorv32/` (PicoRV32, Claire Xenia Wolf) | ISC (`COPYING`) |
| ROM images in `ASpectrum/roms48k.hex` and `ASpectrum/sim/roms.mem` | ZX Spectrum 128 ROMs (c) Amstrad, distributed for emulator use with permission, copyright messages unchanged; DiagROM by its authors |
