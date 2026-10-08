# ASpectrum — known issues

Open problems seen on the hardware, plus design limitations. Not being fixed now (user, 2026-10-08).

## Seen on the hardware

| # | Date | Issue | How often | Workaround | Probable cause (not confirmed) | Possible fix |
|---|---|---|---|---|---|---|
| 1 | 2026-10-08 | The SD card was not recognised ("No SD card, or not FAT16/FAT32") | once, not reproducible | Enter in the browser ("try again") | Card not ready yet when the firmware initialised it right after FPGA configuration (some cards need up to ~250 ms after power-up; CMD0 is retried only for a few ms). Or one failed sector read, which marks the card absent until a manual retry. | Firmware only (`fw/sd.c`, `fw/main.c`): retry the full init 3-5 times over ~0.5 s before reporting no card; after a failed read, re-initialise and retry once. |
| 2 | 2026-10-08 | The keyboard did not work, from power-up: the 128K start menu was shown but ignored all keys | once, not reproducible | **KEY0 fixed it** (Ctrl+Alt+Del was not tried) | KEY0 resets the machine and the tape loader (ROM copy flash -> SDRAM again, CPU restart) but **not** the keyboard decoder (power-up reset only) and not the USB keyboard module, so the keyboard path was most likely fine. Candidates: (a) a bad ROM copy at power-up — the menu still draws but its keyboard code is damaged; `rom_loader` only checks the first byte; (b) a power-up-only start condition (CPU waits <= 1.5 s for the keyboard, SDRAM/video starting together); the 128K menu reads the keys from the 50 Hz interrupt, so a missing interrupt would also look like this (less likely: the picture, hence vsync, was there). | Next time, **before KEY0** try Ctrl+Alt+Del and F12: both are decoded by the FPGA, not the Spectrum software. They work = Spectrum side (a/b); they do not = keyboard path. Possible improvement: `rom_loader` verifies a checksum of the whole 48 KB copy and repeats the copy if it is wrong. |

If either happens again, note: power-up or after a reset, card type/size, keyboard model, whether Ctrl+Alt+Del / F12
still worked, whether KEY0 or only a power cycle helped, and what the screen/LED showed.

## Design limitations (by design or not done yet)

- No memory contention and no floating bus: timing-critical demos and border effects are not exact (the VGA picture
  is not locked to the Spectrum frame).
- AY output is mono; MIC is not output (no tape saving).
- Tape loader: TZX 0x19 (generalized data), 0x18 (CSW) and 0x28 (select block) are not played; text/message blocks
  are not shown; `LOAD ""` is not typed automatically; at most 400 entries per folder; long names cut to 27 characters;
  exFAT cards are not supported (format FAT32).
- Saving: only the ROM's standard format/speed is decoded (custom turbo savers are not); new files get 8.3 names;
  an existing name is refused (no overwrite); no file dates (no clock); switching off during a save can leave a lost
  cluster (a disk check on the PC fixes it).
- Block RAM is now 55 of 56 M9K: little room for further block-RAM features.
- Tape loader in turbo: long runs of TZX 0x13 pulse sequences shorter than ~300 T-states could underrun (not seen
  in real files).
- Turbo stays on until the pause after the last block has played (TZX files with a long final pause keep the game
  at 28 MHz for a moment after loading). Possible fix: cut the final pause to 1 ms.
- At power-up the CPU waits up to 1.5 s for the first keyboard packet (so F1 is seen); with no keyboard attached the
  machine always starts after 1.5 s.

## Resolved

- Saving split header and data into two files (2026-10-08, first save version): the automatic end-of-save after 3 s
  of tape time was hit by the ROM's 1 s pause between blocks (counted in real-time interrupts, 8x longer in turbo
  T-states). Replaced by recording mode, started and stopped explicitly (browser line, F12).
- "Ramparts (1988)(Go!).tzx" failed to load (2026-10-08): the downloaded file was broken; a copy from another site
  loads fine.
