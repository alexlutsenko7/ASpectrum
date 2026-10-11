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

- Memory contention is emulated at Level 1 (2026-10-09: memory and I/O cycles, 128K timing; F5 switches it off);
  not the internal contended T-states of some instructions (DJNZ, PUSH, INC rr, ...). Floating bus emulated
  (2026-10-09, 128K timing, with contention; read point corrected 2026-10-11 to Fuse 1.6's: start of the I/O
  cycle's 4th T-state after its contention. Sidewize, Arkanoid and Cobra, which sync with it, work on the hardware). Not emulated: ULA snow (I register in 40-7F); DiagROM's snow test fails. The 50 Hz
  frame interrupt sits at VGA line 24, pixel 166, measured with Aquaplane's horizon stripe (calculated for a real
  128K: line 12.7; the ~11.5 lines between are most likely the missing Level-2 contention). Other border-effect
  games may need Page Up / Page Down (1/8 line steps, browser closed). In 60 Hz mode border effects cannot line up.
- AY output is mono; MIC is not output (no tape saving).
- Tape loader: TZX 0x19 (generalized data), 0x18 (CSW) and 0x28 (select block) are not played; text/message blocks
  are not shown; `LOAD ""` is not typed automatically; at most 350 entries per folder; long names cut to 27 characters;
  exFAT cards are not supported (format FAT32).
- Saving: only the ROM's standard format/speed is decoded (custom turbo savers are not); new files get 8.3 names;
  an existing name is refused (no overwrite); no file dates (no clock); switching off during a save can leave a lost
  cluster (a disk check on the PC fixes it).
- Block RAM is now 55 of 56 M9K: little room for further block-RAM features.
- Loader CPU RAM (32 KB) is full since the snapshots (2026-10-09): built with `-msave-restore`, the browser holds 350
  entries per folder (was 400), ~1.7 KB left for the stack (deepest use measured ~0.75 KB). More firmware features
  need code savings first (or one more M9K, which would be the last).
- Snapshots (.z80): the position inside the video frame is not saved (after a load the next interrupt comes at a
  different point of the frame); no .sna; an existing name is refused (no overwrite); 48K snapshots run on the
  128's 48 BASIC ROM with paging locked; +3 / Pentagon extras (1FFD, ...) are ignored.
- Tape loader in turbo: long runs of TZX 0x13 pulse sequences shorter than ~300 T-states could underrun (not seen
  in real files).
- Turbo stays on until the pause after the last block has played (TZX files with a long final pause keep the game
  at 28 MHz for a moment after loading). Possible fix: cut the final pause to 1 ms.
- At power-up the CPU waits up to 1.5 s for the first keyboard packet (so F1 is seen); with no keyboard attached the
  machine always starts after 1.5 s.

## Monitor compatibility (VGA output)

| Display | 640x480@60 | 576p50 (F8) | Notes |
|---|---|---|---|
| User's LCD monitor | works | works, shown as "800x600@50" | 576p centred vertically, sharp (2026-10-06) |
| User's home TV (CVT Electronics "LCD TV", 2010, 40") | works | **not possible** | EDID (2026-10-09): analog input, EDID 1.3, no extension blocks; range limits V **59-71 Hz**, H 30-80 kHz, max pixel clock 150 MHz. The TV refuses any 50 Hz input. |

- 50 Hz needs a display whose VGA input accepts 50 Hz. Many TVs and PC monitors only take 60 Hz on VGA: their EDID lists
  only PC modes, with no CEA block (576p50 = VIC 17/18 is usually only offered on HDMI inputs).
- Hence the power-up default is 640x480@60 (since 2026-10-09). At 60 Hz the 50 Hz Spectrum frames are shown with every
  5th output frame repeated (slight judder in smooth scrollers; border effects cannot line up).
- Our 640x480 uses a 25.000 MHz pixel clock (59.52 Hz), not 25.175 MHz (59.94 Hz): this is just inside the TV's 59 Hz
  minimum. Do not lower the 60 Hz mode's frame rate any further.

## Resolved

- Saving split header and data into two files (2026-10-08, first save version): the automatic end-of-save after 3 s
  of tape time was hit by the ROM's 1 s pause between blocks (counted in real-time interrupts, 8x longer in turbo
  T-states). Replaced by recording mode, started and stopped explicitly (browser line, F12).
- "Ramparts (1988)(Go!).tzx" failed to load (2026-10-08): the downloaded file was broken; a copy from another site
  loads fine.
