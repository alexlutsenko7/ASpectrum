/* main.c -- ASpectrum SD tape loader: file browser on the OSD + TAP/TZX player
 *
 * Keys (zx_keyboard.v, see hw.h and docs/SD_TAPE_LOADER.md):
 *   browser closed: F12 / keypad / / NumLock opens it; F11 / keypad 5 pause or
 *                   continue the tape; keypad - goes back one block.
 *   browser open:   up/down (keypad 8/2, F9/F10, arrows), page (keypad 4/6, Left/Right, PgUp/PgDn),
 *                   Enter / keypad Enter / F11 loads a file or opens a folder,
 *                   Esc / Backspace goes to the parent folder, F12 closes.
 *                   Keypad 5 and keypad - work as above.
 *   browser closed: Page Up / Page Down move the 50 Hz frame interrupt 1/8 VGA line
 *                   (108 pixels) earlier / later, to line up border effects with the
 *                   picture; "Frame INT: line.eighth" (default 24.1) for 4 s.
 *   F5:             memory contention on (default) / off; "Contention: on/off" for 4 s.
 *   always:         F7 / keypad * stops the tape: EAR and speed back to normal,
 *                   no status row; the file has to be chosen again.
 *                   F6 switches loading and saving between turbo (default) and
 *                   normal speed; "Speed: normal" / "Speed: turbo" for 2 s.
 * Playing a file switches the CPU to turbo (28 MHz) and feeds EAR from the
 * pulse player; both are released at the end of the tape or at a stop block.
 *
 * Saving (save.c): the first browser line, [Save to this folder], asks for an
 * 8.3 name and starts recording mode: everything the Spectrum saves goes into
 * that .tap file until F12 (or F7) is pressed.
 *
 * Snapshots (snap.c): F2 stops the Spectrum and asks for a name; the whole
 * machine is saved as NAME.Z80 in the browser's current folder (the root after
 * power-up), then it runs on. Choosing a .z80 file in the browser loads it.
 *
 * All mutable state is zero-initialised (.bss) and set in code: the RAM image
 * is loaded once with the bitstream, so .data would not be restored by a reset.
 */
#include "hw.h"
#include "hal.h"
#include "fat.h"
#include "tape.h"
#include "sd.h"
#include "osd.h"
#include "util.h"
#include "save.h"
#include "snap.h"

#define MAXE       350
#define LIST_ROW   2
#define LIST_LINES 20
#define REP_DELAY  (400 * CLK_PER_MS)
#define REP_RATE   (60 * CLK_PER_MS)

#define ENT_NAME   27                  /* characters kept per list entry (36-byte entries: 350 fit) */

typedef struct {
    uint32_t clus;
    uint32_t size : 24, dir : 1, tzx : 1, z80 : 1;
    char     name[ENT_NAME + 1];
} ENT;

enum { P_IDLE, P_RUN, P_DRAIN, P_STOPPED, P_PAUSED, P_END, P_ERR };

static ENT      ent[MAXE];
static int      nent, cur, top, truncated, mounted, menu, closing, list_folders, list_stale;
static uint32_t dir_clus;
static char     path[64];
static char     came_from[NAME_MAX + 1];

static FFILE    tf;
static int      p_state, p_tzx, p_stop;
static uint32_t p_block;
static char     p_name[NAME_MAX + 1];

static uint32_t kprev, t_rep;
static char     err_line[33];
static uint32_t speed_t;                    /* "Speed: ..." shown until then */
static char     note_line[33];
static uint32_t note_t;                     /* note_line shown until then */

#define TURBO_BIT (slow_mode ? 0u : TAPE_TURBO)
static int speed_text(char *s);
static int note_text(char *s);

/*----------------------------------------------------------------------------
 * platform functions for fat.c / tape.c
 *--------------------------------------------------------------------------*/
uint32_t fifo_free(void)        { return FIFO_DEPTH - (FIFO & 0x3FFu); }

/*----------------------------------------------------------------------------
 * keys: new presses, with auto-repeat for the movement keys
 *--------------------------------------------------------------------------*/
static uint32_t key_events(void)
{
    const uint32_t rep_keys = K_UP | K_DOWN | K_LEFT | K_RIGHT | K_PGUP | K_PGDN;
    uint32_t now = KEYS;
    uint32_t ev  = now & ~kprev;

    if (ev & rep_keys)
        t_rep = TIMER + REP_DELAY;
    else if ((now & rep_keys) && (int32_t)(TIMER - t_rep) >= 0) {
        ev |= now & rep_keys;
        t_rep = TIMER + REP_RATE;
    }
    kprev = now;
    return ev;
}

/*----------------------------------------------------------------------------
 * directory list
 *--------------------------------------------------------------------------*/
static int ent_less(const ENT *a, const ENT *b)
{
    if (a->name[0] == '.' && a->name[1] == '.') return 1;   /* ".." first */
    if (b->name[0] == '.' && b->name[1] == '.') return 0;
    if (a->dir != b->dir) return a->dir;                    /* folders before files */
    return u_stricmp(a->name, b->name) < 0;
}

static int list_cb(const DIRENT *d, void *ctx)
{
    ENT *e;
    int  is_dir = (d->attr & ATTR_DIR) != 0;
    int  tzx    = u_stricmp(d->ext, "TZX") == 0;
    int  z80    = u_stricmp(d->ext, "Z80") == 0;
    (void)ctx;

    if (d->name[0] == '.' && d->name[1] == 0) return 0;     /* "." */
    if (d->attr & (ATTR_HIDDEN | ATTR_SYSTEM)) return 0;
    if (!is_dir && (list_folders || (!tzx && !z80 && u_stricmp(d->ext, "TAP") != 0))) return 0;
    if (nent == MAXE) { truncated = 1; return 1; }
    e = &ent[nent++];
    e->clus = d->clus;
    e->size = d->size;
    e->dir  = (unsigned)is_dir;
    e->tzx  = (unsigned)tzx;
    e->z80  = (unsigned)z80;
    u_strncpy(e->name, d->name, ENT_NAME);
    return 0;
}

/* folder list into ent[], sorted; folders_only for the save dialog */
static int load_list(uint32_t clus, int folders_only)
{
    int i, j, gap;
    ENT t;

    nent = 0;
    truncated = 0;
    cur = top = 0;
    list_folders = folders_only;
    if (fat_list(clus, list_cb, 0) != FAT_OK) { mounted = 0; nent = 0; return -1; }
    for (gap = nent / 2; gap > 0; gap /= 2)                 /* shell sort */
        for (i = gap; i < nent; i++) {
            u_memcpy(&t, &ent[i], sizeof t);
            for (j = i; j >= gap && ent_less(&t, &ent[j - gap]); j -= gap)
                u_memcpy(&ent[j], &ent[j - gap], sizeof t);
            u_memcpy(&ent[j], &t, sizeof t);
        }
    return 0;
}

/* browser list: item 0 is [Save to this folder], items 1.. are ent[0..];
 * the cursor starts on the first file or folder */
static int load_dir(uint32_t clus)
{
    if (load_list(clus, 0) != 0) return -1;
    dir_clus = clus;
    list_stale = 0;
    cur = nent ? 1 : 0;
    return 0;
}

static void mount_card(void)
{
    mounted = 0;
    if (sd_init() != 0 || fat_mount() != FAT_OK) return;
    mounted = 1;
    path[0] = '/';
    path[1] = 0;
    load_dir(0);
}

/*----------------------------------------------------------------------------
 * player
 *--------------------------------------------------------------------------*/
static void play_from(uint32_t block)
{
    TAPE = TAPE_ON | TURBO_BIT | TAPE_FLUSH;
    tape_start(&tf, p_tzx, block);
    p_state = P_RUN;
}

static void player_open(const ENT *e)
{
    ff_open(&tf, e->clus, e->size);
    p_tzx = e->tzx;
    u_strncpy(p_name, e->name, NAME_MAX);
    play_from(0);
}

static void player_pause(void)
{
    if (p_state == P_RUN || p_state == P_DRAIN) {
        p_block = MARKER & 0xFFFFu;
        TAPE = TAPE_FLUSH;
        p_state = P_PAUSED;
    } else if (p_state == P_PAUSED) {
        play_from(p_block);
    } else if (p_state == P_STOPPED) {
        TAPE = TAPE_ON | TURBO_BIT;
        tape_continue();
        p_state = P_RUN;
    }
}

static void player_stop(void)
{
    TAPE = TAPE_FLUSH;                                      /* EAR from TAPE_IN, turbo off, FIFO empty */
    p_state = P_IDLE;
}

static void player_rewind(void)
{
    uint32_t b;
    if (p_state == P_RUN || p_state == P_DRAIN || p_state == P_STOPPED) {
        b = MARKER & 0xFFFFu;
        play_from(b ? b - 1 : 0);
    } else if (p_state == P_PAUSED) {
        if (p_block) p_block--;
    }
}

static void player_service(void)
{
    int r;
    if (p_state == P_RUN) {
        r = tape_pump();
        if (r == TS_ERR) { TAPE = TAPE_FLUSH; p_state = P_ERR; }
        else if (r != TS_RUN) { p_stop = (r == TS_STOP); p_state = P_DRAIN; }
    } else if (p_state == P_DRAIN && (FIFO & FIFO_IDLE)) {
        TAPE = 0;                                           /* EAR back to the tape input, turbo off */
        p_state = p_stop ? P_STOPPED : P_END;
    }
}

/* status line; returns 0 if there is nothing to say */
static int status_text(char *s)
{
    char *p = s;
    uint32_t b = MARKER & 0xFFFFu;
    switch (p_state) {
    case P_RUN: case P_DRAIN:
        p = u_strcpy(p, "Playing block "); p = u_utoa(p, b); break;
    case P_PAUSED:
        p = u_strcpy(p, "Paused, block "); p = u_utoa(p, p_block); p = u_strcpy(p, " (5=go)"); break;
    case P_STOPPED:
        p = u_strcpy(p, "Tape stopped (5=go on)"); break;
    case P_END:
        p = u_strcpy(p, "End of tape"); break;
    case P_ERR:
        p = u_strcpy(p, "Bad file or read error"); break;
    default:
        *p = 0; return 0;
    }
    *p = 0;
    return 1;
}

/*----------------------------------------------------------------------------
 * screen
 *--------------------------------------------------------------------------*/
static void draw_menu(void)
{
    char line[48];
    int  i, n;

    osd_text(0, 0, " ASpectrum tape loader", OSD_COLS, 1);
    n = u_strlen(path);
    osd_text(1, 0, n > OSD_COLS ? path + n - OSD_COLS : path, OSD_COLS, 0);
    for (i = 0; i < LIST_LINES; i++) {
        int k = top + i;
        line[0] = 0;
        if (mounted && k == 0)
            u_strcpy(line, " [Save to this folder]");
        else if (mounted && k <= nent) {
            char *p = line;
            *p++ = ' ';
            p = u_strcpy(p, ent[k - 1].name);
            if (ent[k - 1].dir) *p++ = '/';
            *p = 0;
        }
        osd_text(LIST_ROW + i, 0, line, OSD_COLS, mounted && k <= nent && k == cur);
    }
    if (!mounted) {
        osd_text(LIST_ROW + 1, 0, " No SD card, or not FAT16/FAT32", OSD_COLS, 0);
        osd_text(LIST_ROW + 3, 0, " Enter = try again", OSD_COLS, 0);
    } else if (nent == 0)
        osd_text(LIST_ROW + 2, 0, " (no .tap/.tzx/.z80 files here)", OSD_COLS, 0);
    else if (truncated)
        osd_text(LIST_ROW + LIST_LINES - 1, 0, " (only the first 350 entries)", OSD_COLS, 0);
    if (!speed_text(line) && !note_text(line) && !status_text(line)) u_strcpy(line, err_line);
    osd_text(22, 0, line, OSD_COLS, 0);
    osd_text(23, 0, "Ent=load Esc=up 5=stop F12=exit", OSD_COLS, 1);
}

/* browser closed: show the bottom status row only while the tape waits for the user */
/* F6: toggle the speed; a playing tape or a block being saved changes at once */
static void speed_toggle(void)
{
    slow_mode = !slow_mode;
    if (p_state == P_RUN || p_state == P_DRAIN)
        TAPE = TAPE_ON | TURBO_BIT;
    rec_speed();
    speed_t = TIMER + 2000 * CLK_PER_MS;
}

/* a message for 4 s (bottom row, or line 22 of the browser) */
static void note(const char *a, const char *b)
{
    char *p = u_strncpy(note_line, a, 32);
    u_strncpy(p, b, 32 - (int)(p - note_line));
    note_t = TIMER + 4000 * CLK_PER_MS;
}

static int note_text(char *s)
{
    if (!note_t) return 0;
    if ((int32_t)(TIMER - note_t) >= 0) { note_t = 0; return 0; }
    u_strcpy(s, note_line);
    return 1;
}

static int speed_text(char *s)
{
    if (!speed_t) return 0;
    if ((int32_t)(TIMER - speed_t) >= 0) { speed_t = 0; return 0; }
    u_strcpy(s, slow_mode ? "Speed: normal" : "Speed: turbo");
    return 1;
}

static void draw_bar(void)
{
    char line[48];
    if (speed_text(line) || note_text(line) || rec_status(line) ||
        ((p_state == P_PAUSED || p_state == P_STOPPED || p_state == P_ERR) && status_text(line))) {
        osd_text(23, 0, line, OSD_COLS, 1);
        osd_show(0);
    } else
        osd_hide();
}

static void menu_open(void)
{
    menu = 1;
    if (!mounted) mount_card();
    else if (list_stale) load_dir(dir_clus);
    osd_clear();
    osd_show(1);
}

/* The browser goes away only when the key that closed it is released: the
 * Spectrum keyboard is unblocked at that moment and must not see Enter or
 * Esc (BREAK). */
#define CLOSE_KEYS (K_ENTER | K_F11 | K_MENU | K_BACK)

static void menu_close(void)
{
    closing = 1;
}

/* path ("/a/b/") after entering folder e; returns 1 if it was "..", with the folder left in from */
static int path_step(char *pth, int size, const ENT *e, char *from)
{
    int i, n;
    if (e->name[0] == '.' && e->name[1] == '.') {
        n = u_strlen(pth) - 1;                              /* path ends with '/' */
        for (i = n - 1; i > 0 && pth[i - 1] != '/'; i--) ;
        u_strncpy(from, pth + i, n - i);
        pth[i] = 0;
        return 1;
    }
    from[0] = 0;
    if (u_strlen(pth) + u_strlen(e->name) + 2 < size) {
        char *p = pth + u_strlen(pth);
        p = u_strcpy(p, e->name);
        p[0] = '/';
        p[1] = 0;
    }
    return 0;
}

static void enter_dir(const ENT *e)
{
    uint32_t clus = e->clus;
    int      i;

    path_step(path, (int)sizeof path, e, came_from);
    if (load_dir(clus) != 0) return;
    for (i = 0; came_from[0] && i < nent; i++)              /* cursor on the folder we left */
        if (u_stricmp(ent[i].name, came_from) == 0) {
            cur = i + 1;
            top = cur >= LIST_LINES ? cur - LIST_LINES / 2 : 0;
            break;
        }
}

static void move_in(int d, int count, int lines)
{
    if (!count) return;
    cur += d;
    if (cur < 0) cur = 0;
    if (cur >= count) cur = count - 1;
    if (cur < top) top = cur;
    if (cur >= top + lines) top = cur - lines + 1;
}

static void move(int d) { move_in(d, nent + 1, LIST_LINES); }

static int  name_prompt(char n11[11], int snap);
static void snap_save_ui(void);

/* 8.3 name for messages */
static void name83(char *d, const char n11[11])
{
    int i;
    for (i = 0; i < 8 && n11[i] != ' '; i++) *d++ = n11[i];
    *d++ = '.';
    for (i = 8; i < 11 && n11[i] != ' '; i++) *d++ = n11[i];
    *d = 0;
}

static void snap_open(const ENT *e)
{
    int r;
    if (p_state != P_IDLE) player_stop();               /* the tape belongs to the old program */
    ff_open(&tf, e->clus, e->size);
    r = snap_load(&tf);
    if (r == 0)               note("Loaded ", e->name);
    else if (r == SNAP_ERUN)  note("Spectrum not running", "");
    else if (r == SNAP_EBAD)  note("Not a usable .z80: ", e->name);
    else                      note("Card error", "");
}

static void menu_keys(uint32_t k)
{
    if (k & K_MENU) { menu_close(); return; }
    if (!mounted) {
        if (k & (K_ENTER | K_F11)) mount_card();
        if (k & K_BACK) menu_close();
        return;
    }
    if (k & K_UP)    move(-1);
    if (k & K_DOWN)  move(1);
    if (k & (K_LEFT | K_PGUP))  move(-LIST_LINES);
    if (k & (K_RIGHT | K_PGDN)) move(LIST_LINES);
    if (k & (K_ENTER | K_F11)) {
        if (cur == 0) {                                     /* [Save to this folder] */
            char n11[11];
            int  r;
            if (!name_prompt(n11, 0)) return;
            if (p_state != P_IDLE) player_stop();
            r = rec_start(dir_clus, n11);
            list_stale = 1;
            if (r == FAT_OK) { menu_close(); return; }
            u_strcpy(err_line, r == FAT_EFULL ? "Card or folder full" : "Card error");
            return;
        }
        if (cur <= nent) {
            const ENT *e = &ent[cur - 1];
            if (e->dir) enter_dir(e);
            else if (e->z80) { snap_open(e); menu_close(); return; }
            else { player_open(e); menu_close(); return; }
        }
    }
    if (k & K_BACK) {
        if (nent && ent[0].dir && ent[0].name[0] == '.' && ent[0].name[1] == '.')
            enter_dir(&ent[0]);
        else
            menu_close();
    }
    if (k & K_KP5)   player_pause();
    if (k & K_REW)   player_rewind();
    if (k & K_STOP)  player_stop();
    if (k & K_SPEED) speed_toggle();
    if (k & K_SNAP)  { snap_save_ui(); menu_close(); }
}

static void play_keys(uint32_t k)
{
    if (k & K_SPEED) speed_toggle();
    if (rec_active()) {                                     /* recording: F12 (or F7) stops it */
        if (k & (K_MENU | K_STOP)) rec_end();
        if (k & K_SNAP) note("Recording: F12 first", "");
        return;
    }
    if (k & K_SNAP) { snap_save_ui(); return; }
    if (k & K_CONT) {                                       /* contention on / off */
        INTPOS ^= INT_NOCONT;
        note("Contention: ", (INTPOS & INT_NOCONT) ? "off" : "on");
        return;
    }
    if (k & (K_PGUP | K_PGDN)) {                            /* frame interrupt position */
        char t[12], *q;
        uint32_t r = INTPOS, p = (r & 0x3FFu) * 864u + (r >> 16 & 0x3FFu);   /* pixels after vsync */
        if ((k & K_PGUP) && p >= 108)        p -= 108;
        if ((k & K_PGDN) && p < 620u * 864u) p += 108;
        INTPOS = (r & INT_NOCONT) | (p % 864u) << 16 | p / 864u;
        q = u_utoa(t, p / 864u);
        *q++ = '.';
        u_utoa(q, p % 864u / 108u);
        note("Frame INT: line ", t);
        return;
    }
    if (k & K_MENU) { err_line[0] = 0; menu_open(); return; }
    if (k & (K_F11 | K_KP5)) player_pause();
    if (k & K_REW)  player_rewind();
    if (k & K_STOP) player_stop();
}

/*----------------------------------------------------------------------------
 * name for a recording (modal, browser open)
 *--------------------------------------------------------------------------*/
static uint8_t rprev[3];

/* new key presses from the raw keyboard report (USB HID codes); returns the count */
static int raw_events(uint8_t ev[3], uint8_t *mods)
{
    uint32_t r, r2;
    uint8_t  now[3];
    int      i, j, n = 0;
    do { r = KEYRAW; r2 = KEYRAW; } while (r != r2);       /* 32 bits from another clock domain */
    now[0] = (uint8_t)(r >> 16); now[1] = (uint8_t)(r >> 8); now[2] = (uint8_t)r;
    *mods = (uint8_t)(r >> 24);
    for (i = 0; i < 3; i++) {
        if (!now[i]) continue;
        for (j = 0; j < 3 && rprev[j] != now[i]; j++) ;
        if (j == 3) ev[n++] = now[i];
    }
    for (i = 0; i < 3; i++) rprev[i] = now[i];
    return n;
}

static char key_char(uint8_t c, uint8_t mods)
{
    if (c >= 0x04 && c <= 0x1D) return (char)('A' + c - 0x04);
    if (c >= 0x1E && c <= 0x26) return (char)('1' + c - 0x1E);
    if (c == 0x27 || c == 0x62) return '0';
    if (c >= 0x59 && c <= 0x61) return (char)('1' + c - 0x59);
    if (c == 0x2D) return (mods & 0x22) ? '_' : '-';
    if (c == 0x56) return '-';
    return 0;
}

/* asks for an 8.3 name for a new file in the current folder: a .TAP for recording
 * (proposes the first free SAVEnnnn) or, if snap, a .Z80 snapshot (no proposal);
 * 1 = name in n11, 0 = Esc */
static int name_prompt(char n11[11], int snap)
{
    const char *ext = snap ? "Z80" : "TAP";
    char    name[12], line[48], msg[33];
    int     len = 0, i, k, n, r;
    uint8_t ev[3], mods, c;

    name[0] = 0;
    for (k = 1; !snap && k < 10000; k++) {                  /* default: first free SAVEnnnn */
        name[0] = 'S'; name[1] = 'A'; name[2] = 'V'; name[3] = 'E';
        name[4] = (char)('0' + k / 1000); name[5] = (char)('0' + k / 100 % 10);
        name[6] = (char)('0' + k / 10 % 10); name[7] = (char)('0' + k % 10); name[8] = 0;
        for (i = 0; i < 8; i++) n11[i] = name[i];
        n11[8] = 'T'; n11[9] = 'A'; n11[10] = 'P';
        len = 8;
        if (fat_exists(dir_clus, n11) == 0) break;
    }
    msg[0] = 0;
    raw_events(ev, &mods);                                  /* keys already held do not count */
    osd_clear();
    for (;;) {
        osd_text(0, 0, snap ? " Save snapshot (.z80)" : " Save to SD card", OSD_COLS, 1);
        n = u_strlen(path);
        osd_text(1, 0, n > OSD_COLS ? path + n - OSD_COLS : path, OSD_COLS, 0);
        {
            char *p = u_strcpy(line, " Name: ");
            p = u_strcpy(p, name);
            p = u_strcpy(p, "_.");
            u_strcpy(p, ext);
        }
        osd_text(3, 0, line, OSD_COLS, 0);
        if (snap) {
            osd_text(5, 0, " The Spectrum is stopped. The", OSD_COLS, 0);
            osd_text(6, 0, " whole machine is saved; load", OSD_COLS, 0);
            osd_text(7, 0, " it again from the browser.", OSD_COLS, 0);
            osd_text(8, 0, "", OSD_COLS, 0);
        } else {
            osd_text(5, 0, " After Enter, save on the", OSD_COLS, 0);
            osd_text(6, 0, " Spectrum as often as you like;", OSD_COLS, 0);
            osd_text(7, 0, " all blocks go into this file.", OSD_COLS, 0);
            osd_text(8, 0, " F12 stops recording.", OSD_COLS, 0);
        }
        osd_text(22, 0, msg, OSD_COLS, 0);
        osd_text(23, 0, snap ? "Type name, Ent=save, Esc=cancel" : "Type name, Ent=start, Esc=back", OSD_COLS, 1);
        do n = raw_events(ev, &mods); while (!n);
        for (i = 0; i < n; i++) {
            c = ev[i];
            if (c == 0x29) { osd_clear(); return 0; }       /* Esc */
            {
                char ch = key_char(c, mods);
                if (ch && len < 8) { name[len++] = ch; name[len] = 0; msg[0] = 0; }
            }
            if (c == 0x2A && len) name[--len] = 0;          /* Backspace */
            if ((c == 0x28 || c == 0x58) && len) {          /* Enter */
                for (k = 0; k < 8; k++) n11[k] = k < len ? name[k] : ' ';
                n11[8] = ext[0]; n11[9] = ext[1]; n11[10] = ext[2];
                r = fat_exists(dir_clus, n11);
                if (r > 0) { u_strcpy(msg, " Already exists: another name"); continue; }
                if (r < 0) { u_strcpy(msg, " Card error"); continue; }
                osd_clear();
                return 1;
            }
        }
    }
}

/* F2: stop the Spectrum, ask for a name, save NAME.Z80 in the current folder */
static void snap_save_ui(void)
{
    char n11[11], fname[13];
    int  r;

    if (!mounted) mount_card();
    if (!mounted) { note("No SD card", ""); return; }
    if (snap_freeze() != 0) { note("Spectrum not running", ""); return; }
    snap_capture();
    osd_clear();
    osd_show(1);
    if (name_prompt(n11, 1)) {
        name83(fname, n11);
        osd_text(3, 0, " Saving ", OSD_COLS, 0);
        osd_text(3, 8, fname, 24, 0);
        r = snap_save(dir_clus, n11);
        list_stale = 1;
        if (r == FAT_OK)          note("Saved ", fname);
        else if (r == FAT_EFULL)  note("Card or folder full", "");
        else                      note("Card error", "");
    }
    while (KEYS & CLOSE_KEYS) ;                             /* the Spectrum must not see Enter / Esc */
    snap_resume();
    osd_clear();
    if (menu) osd_show(1); else osd_hide();
}

int main(void)
{
    uint32_t k, t_draw = 0;
    int      last_state = -1;

    TAPE = TAPE_FLUSH;
    osd_hide();
    osd_clear();
    mount_card();
    t_draw = TIMER;
    for (;;) {
        k = key_events();
        if (closing) {
            if (!(KEYS & CLOSE_KEYS)) {
                closing = 0;
                menu = 0;
                osd_clear();
                last_state = -1;                            /* redraw: status bar or nothing */
            }
        } else if (menu)
            menu_keys(k);
        else
            play_keys(k);
        player_service();
        rec_service();
        /* redraw on a key, on a player state change, and 5 times a second (block number) */
        if (k || p_state != last_state || TIMER - t_draw > 200 * CLK_PER_MS) {
            if (menu) draw_menu(); else draw_bar();
            last_state = p_state;
            t_draw = TIMER;
        }
    }
}
