# esp32 — the ASpectrum system controller (ESP32)

`esp32.ino` runs on an ESP32-WROOM-32 dev board (CP2102, USB-C) next to the FPGA board. It does two jobs:

- **SD tape loader** (`src/`): owns the SD card and runs the browser, TAP/TZX playback, recording, .z80 load/save
  and the F3 menu, driving the FPGA's loader hardware (`rtl/tape_loader.v`) over an SPI link (`rtl/esp_link.v`).
- **Bluetooth audio**: an A2DP **source**, like a phone, streaming 44.1 kHz audio to a Bluetooth speaker or
  headphones. The audio comes from the FPGA over I2S (`rtl/bt_i2s.v`); a built-in test tone can be used instead
  (`src tone`).

## Wiring (FPGA board header U7 ↔ ESP32 dev board, SD card on the ESP32)

| U7 pin | FPGA pin | Signal | Direction | ESP32 |
|---|---|---|---|---|
| 7 | R1 | ESP_MISO (link data) | FPGA → ESP32 | GPIO35 (input only) |
| 8 | R2 | ESP_IRQ (not used yet) | FPGA → ESP32 | GPIO34 (input only) |
| 9 | P1 | ESP_SCK (link clock, 8 MHz) | ESP32 → FPGA | GPIO14 |
| 10 | P2 | ESP_MOSI (link data) | ESP32 → FPGA | GPIO13 |
| 11 | N1 | ESP_CS_N (link select) | ESP32 → FPGA | GPIO33 |
| 17 | H1 | BT_BCLK | ESP32 → FPGA | GPIO26 (I2S BCLK, 1.4112 MHz) |
| 18 | H2 | BT_LRCK | ESP32 → FPGA | GPIO25 (I2S WS, 44.1 kHz) |
| 19 | F1 | BT_DATA | FPGA → ESP32 | GPIO22 (I2S DIN) |
| 20 | F2 | BT_TX (UART, F3 menu) | FPGA → ESP32 | GPIO16 (RX2) |
| 21 | E1 | BT_RX (UART, answers) | ESP32 → FPGA | GPIO17 (TX2) |
| 1 / 2 | — | GND | | GND (required) |

SD card (Adafruit MicroSD BFF): SCK GPIO18, MISO GPIO19, MOSI GPIO23, CS GPIO5, 3V3, GND. FAT16/FAT32.

All 3.3 V, no level shifting. Power the ESP32 from its own USB or from 5 V into its VIN (U7.63/64 = VIN 5 V).
The ESP32 is the I2S master, so BT and I2S run from the same clock. The FPGA has weak pull-ups on BCLK/LRCK, and
the ESP32 a pull-down on DIN: with either side unplugged the result is silence, not noise. Full wiring:
`docs/ASpectrum_Connection.docx`; a wiring test: `tests/Test_wires/`.

Sound sent: AY + beeper, the same as the analog outputs, mono in both channels, low-passed and DC-free (silence = 0).

## Build / flash

- Arduino core **esp32 3.3.2**, board **ESP32 Dev Module** (`esp32:esp32:esp32`), default partition scheme
  (the sketch is 1.16 MB of 1.25 MB).
- Library **ESP32-A2DP v1.8.11** (Phil Schatzmann). It is not in the Library Manager, so it was copied from the
  GitHub tag into `C:\Users\alxla\OneDrive\Documentos\Arduino\libraries\ESP32-A2DP`.
- Library **AAudioLinkFix** (in this folder, `libraries/AAudioLinkFix`): copy it into the sketchbook `libraries`
  folder too. It holds no code; it only makes the linker wrap an ESP-IDF function (see Notes).
- CLI (in `ASpectrum/`): `arduino-cli compile -b esp32:esp32:esp32 -u -p COM10 esp32`
- PC tests of the loader code (FAT, TAP/TZX, saving, .z80): `test/run_host_test.sh` (w64devkit gcc; card images
  made by `tools/`).

## SD tape loader

- `src/main.cpp` (browser, keys, player), `tape.cpp` (TAP/TZX -> pulse commands), `save.cpp` (recording),
  `snap.cpp` (.z80), `bt.cpp` (F3 menu), `fat.cpp` (FAT16/32 on raw sectors), `util.cpp` are portable C (built as
  C++ here, as C for the PC tests). `src/hw.h` gives the FPGA's registers as proxy objects; `src/esp_hw.cpp`
  implements them over the link, plus SD sectors, the OSD and the loader task.
- At start the ESP32 looks for core ID 5A580001 on the link for 3 s, then every 2 s. Found: the loader runs as a
  task on core 1 (`loader: ... running` on USB). Pulse commands, OSD text and Spectrum memory writes go as bursts;
  snapshot memory reads are fetched 256 bytes at a time.
- The F3 menu talks to the Bluetooth part through the FPGA's UART (U7.20/21), with the commands below.
- KEY0 resets the FPGA's loader hardware; the ESP32 notices it within 0.5 s and restarts itself (Bluetooth reconnects
  by itself a few seconds later).

## Control

Normal use: **F3 on the ASpectrum keyboard** opens the Bluetooth menu (scan, connect, disconnect, forget, PIN,
volume, Spectrum sound / test tone); the loader (`src/bt.cpp`) sends the commands below over UART2 (RX GPIO16, TX GPIO17).
The USB port takes the same commands, for debugging only (Serial Monitor: line ending New Line, not "No line
ending"). Input lines may end in CR, LF or CR+LF; every output line ends in CR+LF. Replies start with `OK` or `ERR`.
Unsolicited events start with `EV` and go to both ports.

| Command | Effect |
|---|---|
| `help`, `status` | command list; connection, target, PIN, audio source, I2S peak (since the last `status`) and underruns |
| `info` | one line for the menu: `OK info <state> <scan\|idle> <MAC> <vol> <pin> <i2s\|tone> <name>` |
| `scan` | drop the current link (if any) and search; each device found is reported as `EV found <n> <MAC> <rssi> <name>` |
| `list` | devices found so far |
| `connect <n\|MAC\|name>` | connect to entry n of the list, a MAC, or an exact name (case-insensitive); saved as the target |
| `disconnect` | drop the link and stop auto-connecting |
| `forget` | clear the target, the stored last peer and its pairing (bond) |
| `pin auto\|<code>` | PIN for legacy devices: `auto` (default) tries 0000, 1234, 8888, 1111; or a fixed code of up to 16 digits |
| `src i2s\|tone` | audio from the FPGA (default) or the test tone |
| `vol <0..127>` | A2DP volume: scales the samples and is sent to the speaker over AVRCP |
| `mute on\|off` | not saved |
| `tone <hz>`, `wave sine\|square`, `level <0..100>` | test tone: 20..20000 Hz (0 = silence), shape, amplitude in % |

Settings (target, PIN, source, tone, vol) are saved in NVS. At power-up the library first reconnects to the last
peer. If that fails, discovery runs and connects when it sees the saved target. Events: `EV connecting/connected/
disconnected <MAC> <name>`, `EV discovery on/off`, and the pairing events below.

Typical first use (F3 menu): put the speaker in pairing mode, Scan for devices, then Enter on its name.

## Pairing and PINs

A speaker has no screen, so it never shows a PIN prompt; the source (the ESP32) supplies the code.

- **Bluetooth 2.1 and later (almost every speaker)**: Secure Simple Pairing "Just Works", no PIN. Shown as
  `EV pairing confirm <number> (accepted)` then `EV paired <name>`.
- **Bluetooth 2.0 and older (PIN devices)**: the device asks for its fixed PIN, shown as `EV pairing pin <code>`.
  With `pin auto` a wrong code gives `EV pairing failed` and `EV pairing next try with pin <code>`; the next
  connection attempt (automatic, ~15-25 s later) uses the next code from 0000, 1234, 8888, 1111. For any other
  code, set it with `pin <code>`. A 16-digit request is padded with zeros.
- Such devices give their name only on a name request, not in the inquiry data; the scan reports them as soon as
  they are seen (as `(no name)` until the name arrives), and they can always be connected by index or MAC.
- After pairing, the link key is stored on both sides; later connections need no PIN.

## Notes

- Classic BT is needed, so only the original ESP32 works (S2/S3/C3 are BLE-only).
- The scan only reports devices whose Class of Device says audio/rendering/telephony.
- After it starts, the library waits about 10 s before it reconnects or starts discovery.
- **ESP-IDF 5.5 bug, worked around** (`IntegerDivideByZero` in `SBC_Encoder_Init`, seen with Bose headphones in
  38 of 40 connects): when the speaker opens the A2DP stream itself (it reconnects to its last source on its own,
  or answers our connect with its own) and sets the standard SBC configuration, Bluedroid never asks for the
  sink's capabilities, `bta_av_co_audio_set_codec()` fails, the encoder stays all-zero and the first stream start
  divides by 0 blocks. The sketch wraps that function at link time (`-Wl,--wrap`, via AAudioLinkFix) and reports
  success while a link is open; the encoder then uses Bluedroid's default SBC setup, which is the one the speaker
  chose. `status` shows `codec-fix=<n>` and `EV codec set up by the IDF fix` marks each use. (Arduino passes a
  library's `ldflags` only for a precompiled library, hence the stub archive in AAudioLinkFix.)
- The library's discovery loop would keep running while connected; the sketch stops it then.
- The ESP32's 16-bit I2S receive may swap left/right; irrelevant while the FPGA sends mono.
