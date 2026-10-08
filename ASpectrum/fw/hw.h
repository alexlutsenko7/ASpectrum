/* hw.h -- loader CPU registers (rtl/tape_loader.v). PicoRV32 at 56 MHz. */
#ifndef HW_H
#define HW_H

#include <stdint.h>

#define CLK_HZ      56000000u
#define CLK_PER_MS  56000u

#define IO(o)       (*(volatile uint32_t *)(0x10000000u + (o)))
#define SPI_DATA    IO(0x00)    /* W: send byte (starts a transfer)  R: received byte */
#define SPI_CTRL    IO(0x04)    /* W: [0] card selected (CS_N low), [15:8] half period - 1 (56 MHz clocks)
                                   R: same, [31] busy */
#define KEYS        IO(0x08)    /* R: loader keys, 1 = held (bits K_*) */
#define FIFO        IO(0x0C)    /* W: push a command  R: [9:0] entries used, [16] player idle */
#define TAPE        IO(0x10)    /* W: [0] EAR from player, [1] turbo, [2] flush (clears FIFO, level 0) */
#define OSDC        IO(0x14)    /* W: [0] OSD on, [1] full screen (else bottom row only; full also blocks the ZX keyboard) */
#define TIMER       IO(0x18)    /* R: free-running 56 MHz counter */
#define MARKER      IO(0x1C)    /* R: [15:0] argument of the last CMD_MARK the player executed */
#define REC         IO(0x20)    /* R: recorder event (reading clears it): [31] pending, [30] gap, [29] lost, [23:0] T-states */
#define RECCTL      IO(0x24)    /* W: [0] armed (hold the Spectrum while an event is unread), [1] hold the Spectrum
                                   R: T-states since the last MIC edge */
#define KEYRAW      IO(0x28)    /* R: last keyboard report {modifiers, key 1, key 2, key 3} (USB HID codes) */
#define OSD_RAM     ((volatile uint8_t *)0x20000000u)   /* 32 x 24 characters, bit 7 = inverse */

#define SPI_BUSY    0x80000000u
#define FIFO_DEPTH  512u
#define FIFO_IDLE   0x10000u
#define TAPE_ON     1u
#define TAPE_TURBO  2u
#define TAPE_FLUSH  4u
#define OSD_ON      1u
#define OSD_FULL    2u
#define REC_PEND    0x80000000u
#define REC_GAP     0x40000000u
#define REC_LOST    0x20000000u
#define REC_ARMED   1u
#define REC_HOLD    2u

/* KEYS bits (zx_keyboard.v): numpad / F-key / arrow keys */
#define K_MENU      (1u << 0)   /* F12, keypad /, NumLock */
#define K_UP        (1u << 1)   /* keypad 8, F9, Up       */
#define K_DOWN      (1u << 2)   /* keypad 2, F10, Down    */
#define K_LEFT      (1u << 3)   /* keypad 4, Left         */
#define K_RIGHT     (1u << 4)   /* keypad 6, Right        */
#define K_ENTER     (1u << 5)   /* keypad Enter, Enter    */
#define K_F11       (1u << 6)   /* F11                    */
#define K_KP5       (1u << 7)   /* keypad 5               */
#define K_REW       (1u << 8)   /* keypad -               */
#define K_BACK      (1u << 9)   /* Esc, Backspace         */
#define K_STOP      (1u << 10)  /* F7, keypad *           */
#define K_SPEED     (1u << 11)  /* F6                     */

#endif
