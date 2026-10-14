// esp_hw.cpp -- the platform under the SD tape loader firmware: SPI link to the FPGA
// (rtl/esp_link.v), register proxies (hw.h), pulse FIFO
// bursts (hal.h), OSD text (osd.h), SD card sectors (hal.h / sd.h) and the loader task.
//
// Link: HSPI, mode 0, 8 MHz. SCK GPIO14 -> U7.9, MOSI GPIO13 -> U7.10, CS GPIO33 -> U7.11,
// MISO GPIO35 <- U7.7, IRQ GPIO34 <- U7.8 (not used). SD card: VSPI, SCK 18, MISO 19, MOSI 23, CS 5.
//
// Writes that come in streams are collected and sent as one link frame before any other register
// access: pulse FIFO commands, OSD text, Spectrum memory writes. Spectrum memory reads (snapshot
// saving) are fetched 256 bytes at a time. Everything else is one link frame per access.
#include <Arduino.h>
#include <SPI.h>
#include <SD.h>
#include <driver/gpio.h>
#include <esp_heap_caps.h>
#include "hw.h"
#include "hal.h"
#include "osd.h"
#include "sd.h"
#include "loader.h"

int loader_main(void);

static const int L_SCK = 14, L_MOSI = 13, L_CS = 33, L_MISO = 35, L_IRQ = 34;
static const int SD_SCK = 18, SD_MISO = 19, SD_MOSI = 23, SD_CS = 5;
static const uint32_t LINK_HZ = 8000000;
static const uint32_t CORE_ID = 0x5A580001;      // ASpectrum ("ZX"), link version 1

enum { CMD_WR = 1, CMD_RD = 2, CMD_OSD = 3, CMD_FIFO = 4, CMD_MWR = 5, CMD_MRD = 6, CMD_STAT = 7 };
enum { R_ID = 0x00, R_IRQ = 0x04, R_FIFO = 0x0C, R_TIMER = 0x18, R_SNAPCTL = 0x2C, R_SNAPCMD = 0x30, R_SNAPDAT = 0x34 };
enum { C_MRD = 1, C_MWR = 2 };                    // snapshot port commands (snap.cpp)
static const uint32_t SPEC_MEM = 0x40000;         // 18-bit Spectrum memory address space

static SPIClass linkspi(HSPI);
static SPIClass sdspi(VSPI);
static bool link_up, running;

//-----------------------------------------------------------------------------
// link frames
//-----------------------------------------------------------------------------
static uint8_t ftx[1100], frx[1100];

static void frame(size_t n)
{
    linkspi.beginTransaction(SPISettings(LINK_HZ, MSBFIRST, SPI_MODE0));
    digitalWrite(L_CS, LOW);
    delayMicroseconds(1);                         // >= 100 ns CS -> first SCK
    linkspi.transferBytes(ftx, frx, n);
    delayMicroseconds(1);
    digitalWrite(L_CS, HIGH);
    linkspi.endTransaction();
    delayMicroseconds(1);
}

static void link_wr(uint8_t r, uint32_t v)
{
    ftx[0] = CMD_WR; ftx[1] = r;
    ftx[2] = v >> 24; ftx[3] = v >> 16; ftx[4] = v >> 8; ftx[5] = v;
    frame(6);
}

static uint32_t link_rd(uint8_t r)
{
    ftx[0] = CMD_RD; ftx[1] = r;
    memset(ftx + 2, 0, 5);
    frame(7);
    return (uint32_t)frx[3] << 24 | (uint32_t)frx[4] << 16 | (uint32_t)frx[5] << 8 | frx[6];
}

//-----------------------------------------------------------------------------
// collected writes
//-----------------------------------------------------------------------------
static uint32_t fifo_buf[200];
static int      fifo_n;
static uint8_t  osd_sh[OSD_COLS * OSD_ROWS];
static int      osd_lo = OSD_COLS * OSD_ROWS, osd_hi;      // dirty range [lo, hi)
static uint8_t  mwr_buf[1024];
static uint32_t mwr_a;
static int      mwr_n;
static uint8_t  mrd_buf[256];
static uint32_t mrd_a;
static int      mrd_n;                                     // 0 = cache empty

static void flush_fifo()
{
    if (!fifo_n) return;
    ftx[0] = CMD_FIFO;
    for (int i = 0; i < fifo_n; i++) {
        uint32_t c = fifo_buf[i];
        ftx[1 + 4 * i] = c >> 24; ftx[2 + 4 * i] = c >> 16; ftx[3 + 4 * i] = c >> 8; ftx[4 + 4 * i] = c;
    }
    frame(1 + 4 * fifo_n);
    fifo_n = 0;
}

static void flush_osd()
{
    if (osd_lo >= osd_hi) return;
    int n = osd_hi - osd_lo;
    ftx[0] = CMD_OSD; ftx[1] = osd_lo >> 8; ftx[2] = osd_lo;
    memcpy(ftx + 3, osd_sh + osd_lo, n);
    frame(3 + n);
    osd_lo = OSD_COLS * OSD_ROWS;
    osd_hi = 0;
}

static void flush_mwr()
{
    if (!mwr_n) return;
    ftx[0] = CMD_MWR; ftx[1] = mwr_a >> 16; ftx[2] = mwr_a >> 8; ftx[3] = mwr_a;
    memcpy(ftx + 4, mwr_buf, mwr_n);
    frame(4 + mwr_n);
    delayMicroseconds(2);                         // the last byte's write finishes after the frame
    mwr_n = 0;
}

static void flush_all()
{
    flush_fifo();
    flush_osd();
    flush_mwr();
}

//-----------------------------------------------------------------------------
// register proxies (hw.h)
//-----------------------------------------------------------------------------
static uint32_t snap_dat, snap_res;
static bool     snap_done;                        // a command finished here: the next SNAPCTL read is not busy
static uint32_t t_yield, t_check;

static uint32_t timer56() { return (uint32_t)(esp_timer_get_time() * 56); }

// The loader polls registers in tight loops: let the other tasks on this core run now and then.
// Every 0.5 s it also checks that the FPGA was not reset (KEY0 resets the loader hardware: the
// IRQ mask set at start reads 0 again); the firmware's state would then not match, so restart.
static void housekeeping()
{
    uint32_t now = millis();
    if (now - t_yield >= 20) { vTaskDelay(1); t_yield = millis(); }
    if (now - t_check >= 500) {
        t_check = now;
        uint32_t id = link_rd(R_ID), irq = link_rd(R_IRQ);
        if (id != CORE_ID || !(irq & 0xF00)) {
            Serial.printf("\r\nloader: FPGA reset or reconfigured (id %08lx, irq %08lx): restarting the ESP32\r\n",
                          (unsigned long)id, (unsigned long)irq);
            delay(50);
            esp_restart();
        }
    }
}

static void snap_command(uint32_t v)
{
    uint32_t c = v >> 28, a = v & (SPEC_MEM - 1);
    snap_done = true;
    if (c == C_MWR) {
        mrd_n = 0;
        if (mwr_n && (a != mwr_a + (uint32_t)mwr_n || mwr_n == (int)sizeof mwr_buf)) flush_mwr();
        if (!mwr_n) mwr_a = a;
        mwr_buf[mwr_n++] = (uint8_t)snap_dat;
        snap_res = 0;
        return;
    }
    flush_all();
    if (c == C_MRD) {
        if (!mrd_n || a < mrd_a || a >= mrd_a + (uint32_t)mrd_n) {
            int n = SPEC_MEM - a < sizeof mrd_buf ? SPEC_MEM - a : sizeof mrd_buf;
            ftx[0] = CMD_MRD; ftx[1] = a >> 16; ftx[2] = a >> 8; ftx[3] = a; ftx[4] = 0;
            memset(ftx + 5, 0, n);
            frame(5 + n);
            memcpy(mrd_buf, frx + 5, n);
            mrd_a = a;
            mrd_n = n;
        }
        snap_res = mrd_buf[a - mrd_a];
        return;
    }
    mrd_n = 0;                                    // registers, LOAD, AY, ports: done in the FPGA
    link_wr(R_SNAPDAT, snap_dat);
    link_wr(R_SNAPCMD, v);
    uint32_t t0 = millis();
    while ((link_rd(R_SNAPCTL) & SNAP_BUSY) && millis() - t0 < 100) {}
    snap_res = link_rd(R_SNAPDAT);
}

uint32_t hw_rd(uint8_t r)
{
    if (r == R_TIMER) return timer56();
    if (r == R_SNAPCTL && snap_done) { snap_done = false; return SNAP_FROZEN; }
    if (r == R_SNAPDAT) return snap_res;
    housekeeping();
    flush_all();
    return link_rd(r);
}

void hw_wr(uint8_t r, uint32_t v)
{
    if (r == R_SNAPDAT) { snap_dat = v; return; }
    if (r == R_SNAPCMD) { snap_command(v); return; }
    flush_all();
    if (r == R_SNAPCTL) mrd_n = 0;                // the Spectrum runs again / stops: memory may change
    link_wr(r, v);
}

//-----------------------------------------------------------------------------
// hal.h / osd.h / sd.h
//-----------------------------------------------------------------------------
void fifo_push(uint32_t cmd)
{
    if (fifo_n == (int)(sizeof fifo_buf / sizeof fifo_buf[0])) flush_fifo();
    fifo_buf[fifo_n++] = cmd;
}

void osd_clear(void)
{
    osd_text(0, 0, "", OSD_COLS, 0);
    for (int r = 1; r < OSD_ROWS; r++) osd_text(r, 0, "", OSD_COLS, 0);
}

void osd_text(int row, int col, const char *s, int width, int inv)
{
    if (row < 0 || row >= OSD_ROWS || col < 0 || col >= OSD_COLS) return;
    uint8_t m = inv ? 0x80 : 0x00;
    int a = row * OSD_COLS + col, i;
    for (i = 0; i < width && col + i < OSD_COLS; i++) {
        uint8_t c = (uint8_t)(*s ? *s++ : ' ');
        if (c < 0x20 || c > 0x7F) c = '?';
        c |= m;
        if (osd_sh[a + i] != c) {
            osd_sh[a + i] = c;
            if (a + i < osd_lo) osd_lo = a + i;
            if (a + i + 1 > osd_hi) osd_hi = a + i + 1;
        }
    }
}

void osd_show(int full) { OSDC = OSD_ON | (full ? OSD_FULL : 0); }
void osd_hide(void)     { OSDC = 0; }

static bool sd_ok;

int sd_init(void)
{
    static const uint32_t hz[] = {20000000, 4000000};
    SD.end();
    sd_ok = false;
    for (uint32_t f : hz) {
        sdspi.end();
        sdspi.begin(SD_SCK, SD_MISO, SD_MOSI, SD_CS);
        gpio_pullup_en((gpio_num_t)SD_MISO);
        if (SD.begin(SD_CS, sdspi, f)) {
            sd_ok = true;
            Serial.printf("loader: SD card %llu MB at %lu MHz\r\n", SD.cardSize() >> 20, (unsigned long)(f / 1000000));
            return 0;
        }
        SD.end();
    }
    Serial.print("loader: no SD card\r\n");
    return -1;
}

int sd_ready(void) { return sd_ok; }

int sd_read(uint32_t lba, uint8_t *buf)
{
    if (!sd_ok) return -1;
    if (SD.readRAW(buf, lba)) return 0;
    sd_ok = false;
    return -1;
}

int sd_write(uint32_t lba, const uint8_t *buf)
{
    if (!sd_ok) return -1;
    if (SD.writeRAW(const_cast<uint8_t *>(buf), lba)) return 0;
    sd_ok = false;
    return -1;
}

//-----------------------------------------------------------------------------
// loader.h
//-----------------------------------------------------------------------------
static uint32_t t_probe;

static void loader_task(void *)
{
    t_yield = t_check = millis();
    loader_main();                                // never returns
    vTaskDelete(nullptr);
}

static bool probe()
{
    uint32_t id = link_rd(R_ID);
    if (id != CORE_ID) return false;
    link_wr(R_IRQ, 0x100);                        // mask bit for the FPGA reset check (housekeeping)
    return (link_rd(R_IRQ) & 0xF00) != 0;
}

static void start_if_found()
{
    if (running || !probe()) return;
    running = true;
    Serial.printf("loader: ASpectrum found, SD tape loader running (F12 on the Spectrum), free heap %u bytes, largest block %u\r\n", (unsigned)ESP.getFreeHeap(),
                  (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_8BIT));
    xTaskCreatePinnedToCore(loader_task, "loader", 16384, nullptr, 1, nullptr, 1);
}

void loader_begin(void)
{
    pinMode(L_CS, OUTPUT);
    digitalWrite(L_CS, HIGH);
    pinMode(L_IRQ, INPUT);
    linkspi.begin(L_SCK, L_MISO, L_MOSI, -1);
    link_up = true;
    uint32_t t0 = millis();
    while (!running && millis() - t0 < 3000) {    // the FPGA may still be configuring / loading ROMs
        start_if_found();
        if (!running) delay(100);
    }
    if (!running) Serial.print("loader: no ASpectrum on the link yet (FPGA not configured?): retrying every 2 s\r\n");
    t_probe = millis();
}

void loader_poll(void)
{
    if (!link_up || running || millis() - t_probe < 2000) return;
    t_probe = millis();
    start_if_found();
}

bool loader_running(void) { return running; }
