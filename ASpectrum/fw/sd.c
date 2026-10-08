/* sd.c -- SD / SDHC / SDXC card in SPI mode (SPI master in rtl/tape_loader.v) */
#include "hw.h"
#include "hal.h"
#include "sd.h"

#define DIV_INIT  69u           /* 56 MHz / (2 * 70) = 400 kHz */
#define DIV_FAST  1u            /* 56 MHz / (2 * 2)  = 14 MHz  */

static uint32_t div;
static uint8_t  sdhc, ready;

static void cs(int on) { SPI_CTRL = (div << 8) | (on ? 1u : 0u); }

static uint8_t spi(uint8_t b)
{
    SPI_DATA = b;
    while (SPI_CTRL & SPI_BUSY) ;
    return (uint8_t)SPI_DATA;
}

static uint8_t cmd(uint8_t c, uint32_t arg, uint8_t crc)
{
    int i;
    uint8_t r;
    spi(0xFF);
    spi(0x40 | c);
    spi((uint8_t)(arg >> 24));
    spi((uint8_t)(arg >> 16));
    spi((uint8_t)(arg >> 8));
    spi((uint8_t)arg);
    spi(crc);
    for (i = 0; i < 10; i++) {
        r = spi(0xFF);
        if (!(r & 0x80)) return r;
    }
    return 0xFF;
}

static void release(void)
{
    cs(0);
    spi(0xFF);                  /* lets the card release MISO */
}

int sd_init(void)
{
    int      i, v2 = 0;
    uint8_t  r, b[4];
    uint32_t t0;

    ready = 0;
    div = DIV_INIT;
    cs(0);
    for (i = 0; i < 10; i++) spi(0xFF);         /* >= 74 clocks with CS high */
    cs(1);
    for (i = 0; ; i++) {                         /* CMD0: go idle */
        r = cmd(0, 0, 0x95);
        if (r == 0x01) break;
        if (i == 20) goto fail;
    }
    r = cmd(8, 0x1AA, 0x87);                     /* CMD8: interface condition (v2 cards) */
    if (r == 0x01) {
        for (i = 0; i < 4; i++) b[i] = spi(0xFF);
        if ((b[2] & 0x0F) != 0x01 || b[3] != 0xAA) goto fail;
        v2 = 1;
    } else if (!(r & 0x04))
        goto fail;
    t0 = TIMER;
    do {                                         /* ACMD41 until the card leaves idle (<= 1 s) */
        cmd(55, 0, 0x01);
        r = cmd(41, v2 ? 0x40000000u : 0, 0x01);
    } while (r == 0x01 && TIMER - t0 < 1000 * CLK_PER_MS);
    if (r != 0x00) goto fail;
    sdhc = 0;
    if (v2) {
        if (cmd(58, 0, 0x01) != 0x00) goto fail; /* OCR: CCS bit = block addressing */
        for (i = 0; i < 4; i++) b[i] = spi(0xFF);
        sdhc = (b[0] & 0x40) != 0;
    }
    if (!sdhc && cmd(16, 512, 0x01) != 0x00) goto fail;
    release();
    div = DIV_FAST;
    cs(0);
    ready = 1;
    return 0;
fail:
    release();
    return -1;
}

int sd_read(uint32_t lba, uint8_t *buf)
{
    int      i;
    uint8_t  t;
    uint32_t t0;

    if (!ready) return -1;
    cs(1);
    if (cmd(17, sdhc ? lba : lba << 9, 0x01) != 0x00) goto fail;
    t0 = TIMER;
    do t = spi(0xFF);                            /* data token (<= 200 ms) */
    while (t == 0xFF && TIMER - t0 < 200 * CLK_PER_MS);
    if (t != 0xFE) goto fail;
    for (i = 0; i < 512; i++) {
        SPI_DATA = 0xFF;
        while (SPI_CTRL & SPI_BUSY) ;
        buf[i] = (uint8_t)SPI_DATA;
    }
    spi(0xFF);                                   /* CRC, ignored */
    spi(0xFF);
    release();
    return 0;
fail:
    release();
    ready = 0;                                   /* re-initialise before the next access */
    return -1;
}

int sd_write(uint32_t lba, const uint8_t *buf)
{
    int      i;
    uint8_t  r;
    uint32_t t0;

    if (!ready) return -1;
    cs(1);
    if (cmd(24, sdhc ? lba : lba << 9, 0x01) != 0x00) goto fail;
    spi(0xFF);
    spi(0xFE);                                   /* start token */
    for (i = 0; i < 512; i++) {
        SPI_DATA = buf[i];
        while (SPI_CTRL & SPI_BUSY) ;
    }
    spi(0xFF);                                   /* CRC, not checked in SPI mode */
    spi(0xFF);
    r = spi(0xFF);                               /* data response: xxx0 0101 = accepted */
    if ((r & 0x1F) != 0x05) goto fail;
    t0 = TIMER;
    while (spi(0xFF) == 0x00)                    /* busy while programming (<= 500 ms) */
        if (TIMER - t0 > 500 * CLK_PER_MS) goto fail;
    release();
    return 0;
fail:
    release();
    ready = 0;
    return -1;
}

int sd_ready(void) { return ready; }
