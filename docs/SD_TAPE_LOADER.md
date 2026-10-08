# Internal SD tape loader (TAP/TZX)

Status (2026-10-08, end of day): **loading, saving (recording mode), the 400-entry browser, Stop (F7) and the speed
switch (F6) all work on hardware** (user). PC tests and RTL simulations pass; Quartus build timing clean.

Replaces the user's external loader (small MCU + 2 buttons + LCD, PC-preprocessed TAP format, pulls TURBO_N low
while playing at 8x). The loader lives inside the FPGA and plays **unmodified .tap and .tzx** files from an SD card,
in turbo (28 MHz CPU = 8x), T-state exact.

## Decisions (user, 2026-10-08)

- Embedded soft CPU, **not Nios** (no vendor lock-in for the loader subsystem) -> **PicoRV32** (ISC licence, single
  Verilog file, unmodified in `ASpectrum/rtl/picorv32/`, pinned commit in SOURCE.md). Alternatives considered:
  NEORV32 (heavier), SERV (tiny but ~30x slower), second T80 + SDCC, DivMMC/esxDOS (rejected: trap loading).
- Clock: **56 MHz** (sys_pll c2, edges aligned with the 112 MHz system clock; user left 56 vs 112 to us). Code and
  data in block RAM only. 56 MHz gives +4.9 ns slack; crossings to the 112 MHz domain are normal timed paths.
- **No PC preprocessing**: the C firmware parses TAP/TZX directly from the card.
- UI: **USB keyboard** (numpad, F-key fallback, arrows/Enter/Esc in the browser); the LCD is replaced by an **OSD**
  (32 x 24 characters, Spectrum font, white on blue). No long/short-press dual use: one function per key.
- Machine keys: DiagROM = F1 held at start, 50/60 = F8, Ctrl+Alt+Del = reset; **KEY1 no longer used**.
- Toolchain (Windows, called from WSL): xPack `riscv-none-elf-gcc` 15.2 in `C:\Tools\xpack-riscv-none-elf-gcc`
  (needs `GCC_EXEC_PREFIX`, see `fw/build.sh`), w64devkit gcc in `C:\Tools\w64devkit\w64devkit` for the PC tests.

## Hardware

- microSD in SPI mode: CS, SCK, MOSI, MISO. 3.3 V direct. SCK 400 kHz for card init, then 14 MHz (56 / 4).
- The external `TAPE_IN` / `TURBO_N` inputs keep working (old loader, real tape); turbo = TURBO_N low OR loader.

### Prototype SD adapter: Adafruit 5683 "MicroSD Card BFF"

Adafruit schematic (2023-01-31): bare microSD socket, no regulator, no level shifter, no decoupling caps, no
pull-ups, no card detect, DAT1/DAT2 floating. CS = TX via solder jumper SJ2 (factory default, confirmed unmodified).
RX, A0-A3, SDA, SCL are only QT Py pass-through header pins: unconnected. 5V pin: unconnected.

**Wired (user, 2026-10-08)**, 5 mm pins, CS by a 25 mm wire, 10 uF + 100 nF fitted at the BFF:

| BFF pin | Signal | FPGA pin | U8 pin | Notes |
|---|---|---|---|---|
| JP3.4 MOSI | SD_MOSI | AA13 | 7 | |
| JP3.3 MISO | SD_MISO | AA14 | 9 | weak pull-up ON |
| JP3.2 SCK | SD_SCK | AA15 | 11 | |
| JP1.7 TX | SD_CS_N | AA16 | 13 | weak pull-up ON |
| JP3.5 3.3V / JP3.6 GND | | | 3-4 / 1-2 | core board supply |

For a final socket on the daughter card: 47 kOhm pull-ups on MISO, DAT1, DAT2; 10 uF + 100 nF.

## Using it

Card: FAT32 or FAT16 (MBR-partitioned or not), 512-byte sectors. **Not exFAT** (most cards > 32 GB come exFAT:
reformat as FAT32). Folders are supported; the browser shows folders and `.tap` / `.tzx` files, sorted, folders
first, up to **400 entries per folder**; long names are shown (first 27 characters).

| Key | Browser closed | Browser open |
|---|---|---|
| F12, keypad /, NumLock | open the browser | close it |
| keypad 8 / 2, F9 / F10, Up / Down | (Up/Down go to the Spectrum) | move |
| keypad 4 / 6, Left / Right | | page up / down |
| Enter, keypad Enter, F11 | (F11: pause / continue) | load the file / open the folder |
| Esc, Backspace | (go to the Spectrum) | parent folder (root: close) |
| keypad 5 | pause / continue the tape | same |
| keypad - | back one block (pause first to rewind several) | same |
| **F7**, keypad * | **stop**: tape off, EAR and speed back to normal, no OSD; choose the file again to replay; while recording: stop recording | same |
| **F6** | **speed**: loading and saving in turbo (default) or at normal speed; "Speed: normal" / "Speed: turbo" for 2 s; a playing tape or a block being saved changes at once | same |
| F12 while recording | stop recording (the browser is not available while recording) | - |

While the browser is open the Spectrum keyboard is blocked (all keys released). Typical use: `LOAD ""` (or the 128K
menu "Tape Loader"), then F12, pick the file, Enter. Playing switches the CPU to 28 MHz (unless F6 chose normal speed) and feeds EAR from the
player; at the end of the tape, or at a TZX "stop the tape" block, turbo and EAR are released (stop: the bottom row
shows "Tape stopped (5=go on)"; keypad 5 continues — multi-load games). Pause also shows a status row.

| Machine key | Action |
|---|---|
| F6 | tape speed for loading and saving: turbo (default) / normal (see above) |
| F1 held while the CPU starts (power-up, KEY0, Ctrl+Alt+Del) | DiagROM instead of the 128K ROM |
| F8 | swap 50/60 Hz video |
| Ctrl+Alt+Del | reset the Spectrum (tape loader keeps running; ROMs reloaded) |
| KEY0 (W13) | reset everything incl. the tape loader |

At power-up the CPU waits for the first keyboard packet (at most 1.5 s), so F1 held during power-up is seen. If it
is missed anyway, hold F1 and press Ctrl+Alt+Del.

### Saving (recording mode)

1. F12, then choose the first line **[Save to this folder]** (the cursor starts on the first file, so go up one
   line). Go into the wanted folder first if needed.
2. Type a name (up to 8 letters, digits, `-`, `_`; `.TAP` is added). The default is the next free `SAVEnnnn`.
   Backspace deletes, Enter starts recording, Esc goes back. An existing name is refused.
3. Save on the Spectrum as often as you like (`SAVE "name"`, `CODE`, `SCREEN$`, `DATA`, machine code calling the ROM
   routine): **every block goes into this one file**, however many and however far apart. Each block is saved at
   28 MHz; in between the Spectrum runs at normal speed. The bottom row shows `Rec NAME.TAP: n F12=stop`.
4. **F12** (or F7) stops recording and closes the file ("Saved NAME.TAP (n blocks)"). If nothing was saved the
   empty file is removed. The tape browser is not available while recording.

Only the ROM's standard format is decoded (a block needs 64 pilot pulses; MIC clicks for sound are ignored).
History: the first version (8 October) asked for the name after the first block and ended a save after 3 s of tape
time; the ROM's 1 s pause between header and data (50 Hz interrupts, real time) is 8 times longer in turbo T-states,
so header and data ended up in two files. Hence the explicit start/stop.

## Implementation

| Part | File | Size (Quartus, EP4CE15) |
|---|---|---|
| PicoRV32 RV32IMC (no IRQ/counters, register file in M9K) | `rtl/picorv32/picorv32.v` | 2,571 LEs (incl. multiplier/divider), 2 M9K |
| Loader: RAM 32 KB (4 byte lanes, `$readmemh` of `fw/build/fw0..3.hex`), registers, SPI, FIFO 512 x 32, pulse player, recorder | `rtl/tape_loader.v` | 972 LEs, 34 M9K (32 RAM + 2 FIFO) |
| Keyboard: loader keys (12, incl. F6/F7), raw report for typing, F1, F8 toggle, Ctrl+Alt+Del, first-packet flag, ZX key blocking | `rtl/zx_keyboard.v` | 534 LEs |
| OSD: text RAM (dual clock), font ROM (`rtl/osd_font.hex`, from the 48K ROM), overlay | `rtl/zx_video.v` | +25 LEs, 2 M9K |
| EAR from the player, T-state toggle `cen_tgl` | `rtl/zx_bus.v` | |
| MIC output (port FE bit 3), CPU hold input | `rtl/zx_bus.v` | |
| Firmware: browser, SD driver (read + write), FAT16/32 (read + create/delete files), TAP/TZX, recording, speed switch | `fw/*.c` | 12.9 KB code (RV32IMC), ~16.7 KB data |

Whole ASpectrum: 8,379 LEs (54 %), 55 / 56 M9K, 2 PLLs; worst setup slack +0.47 ns (112 MHz), 56 MHz +1.87 ns,
no unconstrained paths. The ROM-loader -> SDRAM owner switch (`rom_loader.done`) has a justified 2-clock multicycle in the SDC
(it once failed by 0.05 ns after an unrelated change).

### Loader CPU memory map (`fw/hw.h`)

| Address | Register |
|---|---|
| 0x0000_0000 | RAM 24 KB: code, data, stack (all mutable data in .bss: a reset does not reload the RAM) |
| 0x1000_0000 SPI_DATA | W: send byte, R: received byte |
| 0x1000_0004 SPI_CTRL | [0] card select, [15:8] half SCK period - 1, R [31] busy |
| 0x1000_0008 KEYS | loader keys (bits as `zx_keyboard` `lkeys`; bit 10 F7 / keypad *, bit 11 F6) |
| 0x1000_000C FIFO | W: push command, R: [9:0] used, [16] player idle |
| 0x1000_0010 TAPE | [0] EAR from player, [1] turbo, [2] flush |
| 0x1000_0014 OSD | [0] on, [1] full screen (else bottom row only; full also blocks the ZX keyboard) |
| 0x1000_0018 TIMER | 56 MHz counter |
| 0x1000_001C MARKER | block the player is in (last MARK executed) |
| 0x1000_0020 REC | recorder event, read clears it: [31] pending, [30] gap (8000 T without an edge), [29] edges lost, [23:0] T-states since the previous MIC edge |
| 0x1000_0024 RECCTL | W: [0] armed (hold the Spectrum while an event is unread), [1] hold; R: T-states since the last edge |
| 0x1000_0028 KEYRAW | last keyboard report {modifiers, key 1, key 2, key 3} (text input) |
| 0x2000_0000 | OSD text, 32 x 24 bytes, bit 7 = inverse |

### Pulse player

Commands (32 bit, `fw/hal.h`); durations in T-states = CPU clock-enable ticks, so the same file is exact at 3.5 MHz
and in turbo, and SDRAM stalls stretch the tape with the CPU:

| Command | Meaning |
|---|---|
| `PULSE n` | hold the level n T-states, then toggle |
| `LEVEL l, n` | set level l, hold n (n = 0: zero time) |
| `DATA b, k` | k bits of b MSB first, each 2 pulses of LEN0 / LEN1 |
| `SAMPLES b, k` | k bits of b MSB first, each sets the level for LEN0 (TZX 0x15) |
| `LEN0 n`, `LEN1 n`, `MARK n` | settings (zero time) |

The next timed command starts in the clock where the running one ends (no gaps). Zero-time commands are taken in
while a command runs and take effect exactly at its end, so they never show on the line. If the CPU is late, the gap
is credited to the next command (up to 255 T-states), so edges stay on time; after a stop the first command starts
fresh.

### Recorder (saving)

MIC edges are timed in T-states like the player. While a save runs the recorder is **armed**: an event the CPU has
not read yet **holds the Z80** (the CEN stops, as for an SDRAM wait), so no edge can be lost however long the
firmware needs (SD writes, the dialog). Holding also stops the T-states, so the recorded timing is unchanged and the
Spectrum never notices. The firmware decodes ROM-format blocks (pilot 2168, sync 667 + 735, bits 2 x 855 / 1710;
each bit is decided by its first pulse because the ROM does not always end a block with an edge) into TAP blocks.
TAP lengths are written as 0 and patched when the block ends. New files get 8.3 names; the FAT is written to both
copies, the FAT32 free count is set to "unknown". No real dates (no clock on the board).

### Firmware (`fw/`)

- `main.c`: browser (load, sort, page, [Save to this folder]), keys with auto-repeat, player control
  (pause/continue/back, stop/end), OSD, name entry from the raw keyboard report.
- `save.c`: recording mode: recorder events -> ROM-format decoder -> blocks appended to one TAP file until F12.
- `sd.c`: SPI-mode init (CMD0, CMD8, ACMD41, CMD58, CMD16), CMD17 block reads, CMD24 block writes, SDSC/SDHC/SDXC.
- `fat.c`: FAT16/FAT32, MBR or not, long names, cluster chains (fragmented files), seek; creating files (free
  cluster search, write-back FAT cache to all copies, directory entry, growing a full folder).
- `tape.c`: TAP and TZX -> commands. TZX blocks played: 10 11 12 13 14 15 20 2B, control 21 22 23 24 25 26 27;
  skipped by length: 18 (CSW) 19 (generalized data) 28 (select) 2A (stop if 48K: this is a 128K) 30-35 40 5A and
  unknown blocks. Conventions: 100 ms low lead-in; a pause holds the level 1 ms if high, then low; TAP blocks =
  standard ROM timing with a 1 s pause.
- Throughput: ~8 pilot/tone pulses per FIFO burst, ~30 instructions per other command; `DATA`/`SAMPLES` cover 8 bits
  per command. Pulse sequences (0x13) shorter than ~300 T-states in long runs could underrun in turbo (not seen in
  real files).

## Build and test

```
ASpectrum/fw/build.sh                  # firmware -> fw/build/fw0..3.hex (needed by Quartus and the simulations)
quartus_sh --flow compile ASpectrum    # then quartus_cpf -c ASpectrum.cof for the .jic, as before
ASpectrum/fw/test/run_host_test.sh     # PC: FAT16/FAT32 images, listing + every TAP/TZX signal vs tools/tzxref.py;
                                       #     saving: ROM SAVE pulse trains -> decoder -> files, checked by tools/fatcheck.py
ASpectrum/sim/run_loader_sim.sh        # RTL: loader + SD card model: boot, browser, play short.tzx T-state exact, Stop;
                                       #     recording: start from the browser, ROM-style MIC signal with CPU hold, F12,
                                       #     file checked on the card image
ASpectrum/sim/run_tapeload_sim.sh      # RTL: whole machine, 128K ROM loads a BASIC program from the card (~40 min)
```

Test files are generated by `fw/tools/mktest.py` (TAP + a TZX with every handled block type incl. loops, jumps,
calls, stop, skipped and unknown blocks) and packed by `fw/tools/mkimg.py` (FAT16/FAT32 image builder, fragments
files on purpose). `fw/tools/tzxref.py` is an independent reference implementation of the signal.

Not covered yet: TZX 0x19 (generalized data), 0x18 (CSW), 0x28 (select block menu); text/message blocks are
not shown; no auto-typing of `LOAD ""`; saving only in ROM format, 8.3 names, no overwrite.
