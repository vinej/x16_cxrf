/* =====================================================================
 * CXRF :: apps/paint/paint.c -- CXRF Paint (llvm-mos)
 * =====================================================================
 * A full paint program at 320x240 in 256 colours (CX_MODE_BMPLOW, 8bpp),
 * feature-matched to the community's cx16paint: freehand draw, line,
 * rectangle, filled box, circle, filled disc, erase, flood fill, a
 * 256-colour palette picker, one-level undo, clear, and BMX v1 image
 * save/load. The left button paints, the middle button erases, and the
 * RIGHT BUTTON opens the menu (TAB and Esc do too) -- so `x` swaps the
 * two paint colours instead. Every tool and command has a hotkey.
 *
 * Immediate-mode, the way a canvas app should be under CXRF: it polls
 * raw events with cx_poll, owns its own hit-testing, and draws through
 * the ABI (cx_line/rect/circle/disc/flood). Mode-1 mouse coordinates
 * arrive as 320x240 pixels. Bulk pixel work -- the undo snapshot, the
 * menu band save-under, BMX file streaming -- goes straight through
 * VERA's data port with interrupts masked (the event IRQ reads GETIN
 * and moves the mouse sprite; neither may run mid-transfer), with the
 * banked side in the CXRF app banks:
 *
 *   banks 20-29  the undo snapshot (240 rows x 320 B = 76,800 B)
 *   banks 30-33  the overlay band save-under (100 rows)
 *
 * The palette: entries 0-15 the VERA defaults, 16-31 a gray ramp,
 * 32-255 an 8x7x4 RGB cube -- written at startup via cx_pal_set and
 * kept in a RAM shadow, so a BMX save writes the palette that is really
 * on screen (VERA palette RAM does not read back reliably).
 * ===================================================================== */

#include <cbm.h>
#include "sdk/include_llvm/cxrf.h"
#include "csdk/cxsdk.h"

#define W 320
#define H 240

/* the overlay band: full width, the top BAND_H rows */
#define BAND_H     100
#define UNDO_BANK  20            /* 10 banks: 20-29 */
#define BAND_BANK  30            /* 4 banks: 30-33 */

#define P_RAM_BANK (*(volatile unsigned char *)0x0000)
#define V_ADDR_L   (*(volatile unsigned char *)0x9F20)
#define V_ADDR_M   (*(volatile unsigned char *)0x9F21)
#define V_ADDR_H   (*(volatile unsigned char *)0x9F22)
#define V_DATA0    (*(volatile unsigned char *)0x9F23)
#define V_CTRL     (*(volatile unsigned char *)0x9F25)

/* tools */
enum { T_DRAW, T_LINE, T_RECT, T_BOX, T_CIRC, T_DISC, T_ERASE, T_FILL,
       T_TEXT, T_NUM };
static const char *tool_names[T_NUM] =
 { "Draw", "Line", "Rect", "Box", "Circle", "Disc", "Erase", "Fill",
   "Text" };
static const char  tool_keys[T_NUM] =
 { 'w','l','r','b','c','d','e','f','a' };

static unsigned char tool = T_DRAW;
#define PAPER  1                      /* the sheet: palette 1 = white  */

static unsigned char color1 = 0;      /* the paint colour (black)      */
static unsigned char color2 = 2;      /* the swap colour  (dark red)   */
static unsigned char pal_shadow[512]; /* GB, R -- VERA's own layout    */
static char          fname[17] = "";   /* the prompt starts empty */

/* =====================================================================
 * VRAM streaming: full rows <-> banked RAM
 * ===================================================================== */
static void vseek(unsigned x, unsigned y) {
    unsigned long off = (unsigned long)y * W + x;
    V_CTRL   = 0;
    V_ADDR_L = (unsigned char)off;
    V_ADDR_M = (unsigned char)(off >> 8);
    V_ADDR_H = ((unsigned char)(off >> 16) & 0x0F) | 0x10;   /* +1 */
}

/* copy `rows` full screen rows (a multiple of 4, so rows*320 is whole
 * 256-byte pages) between VRAM row y0 and banked RAM at `bank`,
 * starting `skip` bytes into it (a multiple of 8K/256 works out too).
 * dir 0 = VRAM -> bank, 1 = bank -> VRAM. The inner do-while moves 256
 * bytes with byte-indexed addressing -- an order of magnitude faster
 * than the byte-at-a-time walk this replaced, which made every stroke
 * start with a visible hitch. Interrupts masked throughout. */
static void rows_bank(unsigned char y0, unsigned char bank,
                      unsigned long skip, unsigned rows,
                      unsigned char dir) {
    unsigned pages = (rows * (W / 4)) >> 6;   /* rows*320/256 */
    unsigned char *p;
    unsigned char save, b;
    CX_SEI();
    save = P_RAM_BANK;
    P_RAM_BANK = bank + (unsigned char)(skip >> 13);
    p = (unsigned char *)(0xA000 + (unsigned)(skip & 0x1FFF));
    vseek(0, y0);
    while (pages--) {
        if (dir) { b = 0; do { V_DATA0 = p[b]; } while (++b); }
        else     { b = 0; do { p[b] = V_DATA0; } while (++b); }
        p += 256;
        if (p == (unsigned char *)0xC000) {
            p = (unsigned char *)0xA000;
            P_RAM_BANK = P_RAM_BANK + 1;
        }
    }
    P_RAM_BANK = save;
    CX_CLI();
}

static void undo_snap(void)    { rows_bank(0, UNDO_BANK, 0, H, 0); }
static void undo_restore(void) { rows_bank(0, UNDO_BANK, 0, H, 1); }
static void band_save(void)    { rows_bank(0, BAND_BANK, 0, BAND_H, 0); }
static void band_restore(void) { rows_bank(0, BAND_BANK, 0, BAND_H, 1); }

/* restore rows [y0, y0+rows) of the screen from the undo snapshot --
 * the shape preview's eraser. Bounds are widened to the 4-row grain
 * the fast copy wants. */
static void undo_rows(unsigned y0, unsigned y1) {
    unsigned rows;
    if (y1 >= H) y1 = H - 1;
    y0 &= ~3U;
    rows = ((y1 - y0) + 4) & ~3U;
    if (y0 + rows > H) rows = H - y0;
    rows_bank((unsigned char)y0, UNDO_BANK, (unsigned long)y0 * W,
              rows, 1);
}

/* =====================================================================
 * the palette: defaults + gray ramp + RGB cube, shadowed for BMX
 * ===================================================================== */
static const unsigned pal16[16] = {   /* the VERA default 16, 12-bit RGB */
    0x000, 0xFFF, 0x800, 0xAFE, 0xC4C, 0x0C5, 0x00A, 0xEE7,
    0xD85, 0x640, 0xF77, 0x333, 0x777, 0xAF6, 0x08F, 0xBBB
};

static void pal_write(unsigned char i, unsigned rgb) {
    cx_pal_set(i, rgb);
    pal_shadow[(unsigned)i << 1]       = (unsigned char)rgb;        /* GB */
    pal_shadow[((unsigned)i << 1) + 1] = (unsigned char)(rgb >> 8); /* R  */
}

static void pal_init(void) {
    unsigned char i = 32;
    unsigned char n, r, g, b;
    for (n = 0; n < 16; n++) pal_write(n, pal16[n]);
    for (n = 16; n < 32; n++) {           /* a 16-step gray ramp */
        g = (unsigned char)(n - 16);
        pal_write(n, ((unsigned)g << 8) | ((unsigned)g << 4) | g);
    }
    for (r = 0; r < 8; r++)               /* 224 entries: 8 x 7 x 4 cube */
        for (g = 0; g < 7; g++)
            for (b = 0; b < 4; b++) {
                pal_write(i, ((unsigned)(r * 15 / 7) << 8) |
                             ((unsigned)(g * 15 / 6) << 4) |
                              (unsigned)(b * 15 / 3));
                i++;
            }
}

/* =====================================================================
 * BMX v1 (the exact layout: x16lib/storage/bmx.asm)
 * ===================================================================== */
static char dosname[24];

static void mkname(const char *pre, const char *suf) {
    unsigned char i = 0, j;
    char c;
    for (j = 0; pre[j]; j++) dosname[i++] = pre[j];
    for (j = 0; fname[j] && j < 16; j++) {
        c = fname[j];
        if (c >= 'a' && c <= 'z') c -= 32;    /* PETSCII letters for DOS */
        dosname[i++] = c;
    }
    for (j = 0; suf[j]; j++) dosname[i++] = suf[j];
    dosname[i] = 0;
}

static unsigned char bmx_save(void) {
    unsigned char hdr[16];
    unsigned y, i;
    unsigned char px;
    mkname("S:", "");                     /* drop any old file first */
    cx_dos(dosname);
    mkname("", ",S,W");
    cbm_k_setnam(dosname);
    cbm_k_setlfs(3, 8, 3);
    if (cbm_k_open()) { cbm_k_close(3); return 1; }
    CX_SEI();
    cbm_k_chkout(3);
    hdr[0]='B'; hdr[1]='M'; hdr[2]='X'; hdr[3]=1;
    hdr[4]=8;  hdr[5]=3;                              /* 8bpp, depth 3  */
    hdr[6]=(unsigned char)W;  hdr[7]=(unsigned char)(W>>8);
    hdr[8]=(unsigned char)H;  hdr[9]=(unsigned char)(H>>8);
    hdr[10]=0; hdr[11]=0;                             /* 256 entries @0 */
    hdr[12]=(unsigned char)(16+512);                  /* data offset    */
    hdr[13]=(unsigned char)((16+512)>>8);
    hdr[14]=0; hdr[15]=0;                             /* raw; border 0  */
    for (i = 0; i < 16; i++) cbm_k_chrout(hdr[i]);
    for (i = 0; i < 512; i++) cbm_k_chrout(pal_shadow[i]);
    for (y = 0; y < H; y++) {
        vseek(0, y);
        for (i = 0; i < W; i++) { px = V_DATA0; cbm_k_chrout(px); }
    }
    cbm_k_clrch();
    cbm_k_close(3);
    CX_CLI();
    return 0;
}

static unsigned char bmx_load_file(void) {
    unsigned char hdr[16];
    unsigned i, count, first;
    unsigned w, h, y;
    unsigned long skip;
    mkname("", ",S,R");
    cbm_k_setnam(dosname);
    cbm_k_setlfs(2, 8, 2);
    if (cbm_k_open()) { cbm_k_close(2); return 1; }
    CX_SEI();
    cbm_k_chkin(2);
    for (i = 0; i < 16; i++) hdr[i] = cbm_k_basin();
    if (cbm_k_readst() || hdr[0]!='B' || hdr[1]!='M' || hdr[2]!='X' ||
        hdr[3]!=1 || hdr[4]!=8 || hdr[14]!=0) {
        cbm_k_clrch(); cbm_k_close(2); CX_CLI(); return 2;
    }
    w = hdr[6] | ((unsigned)hdr[7] << 8);
    h = hdr[8] | ((unsigned)hdr[9] << 8);
    count = hdr[10] ? hdr[10] : 256;
    first = hdr[11];
    for (i = 0; i < count; i++) {         /* palette -> the shadow */
        unsigned char idx = (unsigned char)(first + i);
        pal_shadow[(unsigned)idx << 1]       = cbm_k_basin();
        pal_shadow[((unsigned)idx << 1) + 1] = cbm_k_basin();
    }
    skip  = hdr[12] | ((unsigned)hdr[13] << 8);
    skip -= 16 + ((unsigned long)count << 1);
    while (skip--) cbm_k_basin();         /* padding to the pixel data */
    if (w > W) w = W;
    if (h > H) h = H;
    for (y = 0; y < h; y++) {
        vseek(0, y);
        for (i = 0; i < w; i++) V_DATA0 = cbm_k_basin();
    }
    cbm_k_clrch();
    cbm_k_close(2);
    CX_CLI();
    for (i = 0; i < count; i++) {         /* the shadow -> VERA, via ABI */
        unsigned char idx = (unsigned char)(first + i);
        cx_pal_set(idx, (unsigned)pal_shadow[(unsigned)idx << 1] |
                       ((unsigned)pal_shadow[((unsigned)idx << 1) + 1] << 8));
    }
    return 0;
}

/* =====================================================================
 * overlays: the menu, the palette picker, the filename prompt
 * =====================================================================
 * Each runs a little modal loop on raw events over the saved top band,
 * so the canvas underneath is never lost. */

static char ev_key(cx_event *ev) {        /* PETSCII -> ASCII lowercase */
    unsigned char k = ev->detail;
    if (k >= 0x41 && k <= 0x5A) return (char)(k + 32);
    if (k >= 0xC1 && k <= 0xDA) return (char)(k - 128);
    return (char)k;
}

static void say_ink(const char *s, unsigned x, unsigned y, unsigned char c) {
    cx_ink(c);
    cx_say(s, x, y);
}

/* the filename prompt, drawn inside the saved band: 1 = go, 0 = Esc */
static unsigned char prompt_name(const char *title) {
    cx_event ev;
    unsigned char len = 0, redraw = 1;
    char k;
    while (fname[len]) len++;
    for (;;) {
        if (redraw) {
            cx_rect(40, 30, 240, 44, 11);
            cx_frame(40, 30, 240, 44, 1);
            say_ink(title, 48, 36, 1);
            cx_rect(48, 48, 224, 12, 0);   /* the field: dark */
            say_ink(fname, 52, 50, 1);
            /* the caret sits exactly where the next glyph lands: ask the
             * engine how wide the text really is (a fixed 8 px a
             * character put it one cell too far right) */
            cx_rect(52 + cx_measure(fname), 50, 8, 8, 12);
            redraw = 0;
        }
        if (!cx_poll(&ev)) continue;
        if (ev.type == CX_ET_DOWN && (ev.detail & 2))
            return 0;                    /* right click cancels */
        if (ev.type != CX_ET_KEY) continue;
        if (ev.detail == CX_K_DEL) {
            if (len) fname[--len] = 0;
            redraw = 1;
            continue;
        }
        k = ev_key(&ev);
        if (k == 0x1B) return 0;                        /* Esc    */
        if (k == 0x0D) return len != 0;                 /* Enter  */
        if (len < 16 &&
            ((k >= 'a' && k <= 'z') || (k >= '0' && k <= '9') ||
             k == '.' || k == '-' || k == '@' || k == ':')) {
            fname[len++] = k;
            fname[len] = 0;
            redraw = 1;
        }
    }
}

/* the palette picker: a 16x16 grid. Left click sets colour 1, right
 * click colour 2; Esc/TAB closes. Runs inside the saved band. */
static void palette_picker(void) {
    cx_event ev;
    unsigned char row, col, swatches;
    const unsigned gx = 12, gy = 14;
    cx_rect(0, 0, W, BAND_H, 11);
    cx_frame(0, 0, W, BAND_H, 1);
    say_ink("palette: left=col1 right=col2 esc=ok", 8, 3, 1);
    for (row = 0; row < 16; row++)
        for (col = 0; col < 16; col++)
            cx_rect(gx + (unsigned)col * 6, gy + (unsigned)row * 5, 6, 5,
                    (unsigned char)((row << 4) | col));
    cx_frame(gx - 1, gy - 1, 98, 82, 1);
    say_ink("1", 170, 28, 1);
    say_ink("2", 170, 62, 1);
    swatches = 1;
    for (;;) {
        if (swatches) {              /* only on entry and after a pick --
                                      * redrawing every poll made them
                                      * flicker */
            cx_rect(140, 20, 24, 24, color1);
            cx_frame(140, 20, 24, 24, 1);
            cx_rect(140, 54, 24, 24, color2);
            cx_frame(140, 54, 24, 24, 1);
            swatches = 0;
        }
        if (!cx_poll(&ev)) continue;
        if (ev.type == CX_ET_KEY) {
            char k = ev_key(&ev);
            if (k == 0x1B || k == 0x09 || k == 0x0D) return;
        } else if (ev.type == CX_ET_DOWN || ev.type == CX_ET_DBL) {
            unsigned x = ev.x, y = ev.y;
            if (x >= gx && x < gx + 96 && y >= gy && y < gy + 80) {
                unsigned char c =
                    (unsigned char)((((y - gy) / 5) << 4) + ((x - gx) / 6));
                if (ev.detail & 2) color2 = c;   /* right          */
                else              color1 = c;    /* left or middle */
                swatches = 1;
            } else {
                return;              /* a click off the grid closes it */
            }
        }
    }
}

/* the menu band. Returns an action code; A_NONE = just closed. */
enum { A_NONE, A_UNDO, A_CLEAR, A_LOAD, A_SAVE, A_PAL, A_QUIT };

static unsigned char menu_overlay(void) {
    cx_event ev;
    unsigned char i, act = A_NONE;
    static const char *cmd_names[5] =
        { "Undo", "New", "Open bmx", "Save bmx", "paletTe" };
    static const char cmd_keys[5] = { 'u', 'n', 'o', 's', 't' };
    cx_rect(0, 0, W, BAND_H, 11);
    cx_frame(0, 0, W, BAND_H, 1);
    say_ink("cxrf paint", 8, 3, 13);
    say_ink("tab/right: close  x: swap  q: quit", 120, 3, 12);
    for (i = 0; i < T_NUM; i++) {     /* 9 tools at a 9 px pitch fit the band */
        say_ink(tool_names[i], 16, 12 + (unsigned)i * 9,
                (unsigned char)(i == tool ? 13 : 1));
        if (i == tool) say_ink(">", 8, 12 + (unsigned)i * 9, 13);
    }
    for (i = 0; i < 5; i++)
        say_ink(cmd_names[i], 120, 12 + (unsigned)i * 10, 1);
    cx_rect(240, 14, 20, 20, color1);
    cx_frame(240, 14, 20, 20, 1);
    say_ink("1", 264, 20, 1);
    cx_rect(240, 44, 20, 20, color2);
    cx_frame(240, 44, 20, 20, 1);
    say_ink("2", 264, 50, 1);
    for (;;) {
        if (!cx_poll(&ev)) continue;
        if (ev.type == CX_ET_KEY) {
            char k = ev_key(&ev);
            if (k == 0x09 || k == 0x1B) return A_NONE;
            if (k == 'q') return A_QUIT;
            for (i = 0; i < 5; i++)
                if (k == cmd_keys[i]) return (unsigned char)(A_UNDO + i);
            for (i = 0; i < T_NUM; i++)
                if (k == tool_keys[i]) { tool = i; return A_NONE; }
        } else if (ev.type == CX_ET_DOWN) {
            unsigned x = ev.x, y = ev.y;
            if (ev.detail & 2) return A_NONE;   /* right click: close */
            if (y >= BAND_H) return A_NONE;
            if (x < 110 && y >= 12 && y < 12 + T_NUM * 9) {
                i = (unsigned char)((y - 12) / 9);
                if (i < T_NUM) { tool = i; return A_NONE; }
            } else if (x >= 110 && x < 230 && y >= 12 && y < 64) {
                i = (unsigned char)((y - 12) / 10);
                if (i < 5) return (unsigned char)(A_UNDO + i);
            } else if (x >= 240 && x < 260 && y >= 14 && y < 64) {
                return A_PAL;
            }
        }
    }
}

/* =====================================================================
 * the tools
 * ===================================================================== */
static unsigned ax, ay;               /* the drag anchor */
static unsigned lastx, lasty;
static unsigned char dragging = 0, dragbtn = 0;

/* The right button opens the menu (never paints), so colour 2 is
 * reached by swapping the two with `x`. Middle erases. */
static unsigned char btn_color(unsigned char buttons) {
    if (buttons & 4) return PAPER;    /* middle = erase to the sheet  */
    return color1;
}

/* draw the current shape from the anchor to (x, y); also reports the
 * row span it touched (for the preview's restore) */
static unsigned shp_y0, shp_y1;

static void shape_draw(unsigned x, unsigned y, unsigned char c) {
    unsigned x0 = ax < x ? ax : x, x1 = ax < x ? x : ax;
    unsigned y0 = ay < y ? ay : y, y1 = ay < y ? y : ay;
    unsigned dx = x1 - x0, dy = y1 - y0;
    unsigned r = dx > dy ? dx : dy;
    if (r > 254) r = 254;
    switch (tool) {
    case T_LINE: cx_line(ax, ay, x, y, c); break;
    case T_RECT: cx_frame(x0, y0, dx + 1, dy + 1, c); break;
    case T_BOX:  cx_rect(x0, y0, dx + 1, dy + 1, c); break;
    case T_CIRC:
    case T_DISC:
        if (tool == T_CIRC) cx_circle(ax, ay, (unsigned char)r, c);
        else                cx_disc(ax, ay, (unsigned char)r, c);
        y0 = ay > r ? ay - r : 0;         /* the circle's true span */
        y1 = ay + r;
        break;
    }
    shp_y0 = y0;
    shp_y1 = y1;
}

/* =====================================================================
 * the text tool: click to place the pen, then type. Enter or Esc ends
 * the run; Backspace re-lays the line from the undo snapshot, so an
 * edit never leaves crumbs. The glyphs are the port's own 8x8 charset
 * in the paint colour (mode 1 renders cx_say through cx_ink).
 * ===================================================================== */
#define TXT_MAX 38
static unsigned char txt_on = 0;
static unsigned tx, ty;
static char txt_buf[TXT_MAX + 1];
static unsigned char txt_len;

static void txt_repaint(void) {
    undo_rows(ty, ty + 8);           /* the pre-text image back */
    if (txt_len) {
        cx_ink(color1);
        cx_say(txt_buf, tx, ty);
    }
    cx_rect(tx + cx_measure(txt_buf), ty, 8, 8, color2);   /* the caret */
}

static void txt_begin(unsigned x, unsigned y) {
    tx = x;
    ty = y > (H - 9) ? H - 9 : y;
    txt_len = 0;
    txt_buf[0] = 0;
    txt_on = 1;
    undo_snap();                     /* the whole run is one undo step */
    txt_repaint();
}

static void txt_end(void) {
    txt_on = 0;
    undo_rows(ty, ty + 8);           /* drop the caret... */
    if (txt_len) {
        cx_ink(color1);
        cx_say(txt_buf, tx, ty);     /* ...and lay the text down for good */
    }
}

static void erase_stamp(unsigned x, unsigned y) {
    unsigned x0 = x > 4 ? x - 4 : 0, y0 = y > 4 ? y - 4 : 0;
    cx_rect(x0, y0, 9, 9, PAPER);
}

static void run_action(unsigned char act) {
    switch (act) {
    case A_QUIT:
        cx_mode(CX_MODE_BMPHIGH, 2);  /* the desktop's mode, then out */
        cx_exit();
        break;
    case A_UNDO:
        undo_restore();
        break;
    case A_CLEAR:
        undo_snap();
        cx_clear(PAPER);
        break;
    case A_PAL:
        band_save();
        palette_picker();
        band_restore();
        break;
    case A_SAVE:
        band_save();
        if (prompt_name("save bmx as:")) { band_restore(); bmx_save(); }
        else band_restore();
        break;
    case A_LOAD:
        band_save();
        if (prompt_name("open bmx:")) {
            band_restore();
            undo_snap();
            bmx_load_file();
        } else band_restore();
        break;
    }
}

int main(void) {
    cx_event ev, nx;
    unsigned char i, act;
    unsigned char have_nx = 0, preview = 0;
    unsigned pv_y0 = 0, pv_y1 = 0;
    char k;

    cx_print("PAINT UP");
    cx_mode(CX_MODE_BMPLOW, 8);
    pal_init();
    cx_clear(PAPER);
    cx_ev_init();
    cx_mouse_show(1);
    undo_snap();

    for (;;) {
        if (have_nx) { ev = nx; have_nx = 0; }
        else if (!cx_poll(&ev)) continue;
        if (ev.type == CX_ET_MOVE) {
            /* coalesce queued moves: preview/stroke work only needs the
             * LATEST position, and a burst of moves would lag behind */
            while (cx_poll(&nx)) {
                if (nx.type == CX_ET_MOVE) ev = nx;
                else { have_nx = 1; break; }
            }
        }
        switch (ev.type) {
        case CX_ET_KEY:
            k = ev_key(&ev);
            if (txt_on) {             /* typing into the canvas */
                if (k == 0x0D || k == 0x1B) { txt_end(); break; }
                if (ev.detail == CX_K_DEL) {
                    if (txt_len) txt_buf[--txt_len] = 0;
                    txt_repaint();
                    break;
                }
                if (k >= ' ' && k < 0x7F && txt_len < TXT_MAX) {
                    txt_buf[txt_len++] = k;
                    txt_buf[txt_len] = 0;
                    txt_repaint();
                }
                break;
            }
            act = A_NONE;
            if (k == 0x09 || k == 0x1B) {
                band_save();
                act = menu_overlay();
                band_restore();
            }
            else if (k == 'q') act = A_QUIT;
            else if (k == 'u') act = A_UNDO;
            else if (k == 'n') act = A_CLEAR;
            else if (k == 'o') act = A_LOAD;
            else if (k == 's') act = A_SAVE;
            else if (k == 't') act = A_PAL;
            else if (k == 'x') {      /* swap the two paint colours */
                i = color1; color1 = color2; color2 = i;
            }
            else for (i = 0; i < T_NUM; i++)
                if (k == tool_keys[i]) tool = i;
            if (act != A_NONE) run_action(act);
            break;
        case CX_ET_DOWN:
            if (txt_on) txt_end();    /* a click ends the current run */
            if (ev.detail & 2) {      /* right button: open the menu */
                band_save();
                act = menu_overlay();
                band_restore();
                if (act != A_NONE) run_action(act);
                break;
            }
            dragging = 1;
            dragbtn = ev.detail;
            ax = lastx = ev.x;
            ay = lasty = ev.y;
            undo_snap();              /* every stroke is one undo step */
            if (dragbtn & 4)          /* middle button always erases   */
                erase_stamp(ev.x, ev.y);
            else if (tool == T_DRAW)
                cx_pset(ev.x, ev.y, btn_color(dragbtn));
            else if (tool == T_ERASE)
                erase_stamp(ev.x, ev.y);
            else if (tool == T_FILL) {
                cx_flood(ev.x, ev.y, btn_color(dragbtn));
                dragging = 0;
            }
            else if (tool == T_TEXT) {
                dragging = 0;
                txt_begin(ev.x, ev.y);
            }
            break;
        case CX_ET_MOVE:
            if (!dragging) break;
            if ((dragbtn & 4) || tool == T_ERASE)
                erase_stamp(ev.x, ev.y);
            else if (tool == T_DRAW) {
                cx_line(lastx, lasty, ev.x, ev.y, btn_color(dragbtn));
                lastx = ev.x; lasty = ev.y;
            } else if (tool >= T_LINE && tool <= T_DISC) {
                /* the rubber band: put back the rows the previous
                 * preview touched (from the undo snapshot -- the
                 * pre-stroke image), then draw the shape at the new
                 * mouse position */
                if (preview) undo_rows(pv_y0, pv_y1);
                shape_draw(ev.x, ev.y, btn_color(dragbtn));
                pv_y0 = shp_y0;
                pv_y1 = shp_y1;
                preview = 1;
            }
            break;
        case CX_ET_UP:
            if (!dragging) break;
            dragging = 0;
            if (!(dragbtn & 4) && tool >= T_LINE && tool <= T_DISC) {
                if (preview) undo_rows(pv_y0, pv_y1);
                shape_draw(ev.x, ev.y, btn_color(dragbtn));
            }
            preview = 0;
            break;
        }
    }
}
