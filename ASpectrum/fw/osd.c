/* osd.c -- 32 x 24 text overlay on the Spectrum picture */
#include "hw.h"
#include "osd.h"

void osd_clear(void)
{
    int i;
    for (i = 0; i < OSD_COLS * OSD_ROWS; i++) OSD_RAM[i] = ' ';
}

void osd_text(int row, int col, const char *s, int width, int inv)
{
    volatile uint8_t *p = OSD_RAM + row * OSD_COLS + col;
    uint8_t m = inv ? 0x80 : 0x00;
    int i;
    for (i = 0; i < width && col + i < OSD_COLS; i++) {
        uint8_t c = (uint8_t)(*s ? *s++ : ' ');
        if (c < 0x20 || c > 0x7F) c = '?';
        p[i] = c | m;
    }
}

void osd_show(int full) { OSDC = OSD_ON | (full ? OSD_FULL : 0); }
void osd_hide(void)     { OSDC = 0; }
