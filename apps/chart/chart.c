/* =====================================================================
 * CXRF :: apps/chart/chart.c -- CXRF Chart (llvm-mos)
 * =====================================================================
 * Charts a table from the rest of the suite: it reads the SHEET file
 * format (`.SHT`) -- so it plots a CXRF Sheet save directly, and a CXRF
 * Data table through Data's "export to sheet". One importer, both
 * sources.
 *
 * The Sheet format is a keystroke replay (apps/sheet/README.md): 'z'
 * homes the cursor, '"' starts a label and '=' a value (text then a
 * newline), 'd'/'a' step the cursor right/left and 's'/'w' down/up.
 * import() walks those commands with a virtual cursor and fills a small
 * grid of strings -- everything Chart needs, without a spreadsheet
 * engine.
 *
 * Canvas: CX_MODE_BMPLOW at 8bpp -- 320x240 in 256 colours. Charts want
 * colour more than pixels, and the toolkit (menu bar, dialogs, prompts)
 * draws through the port in mode 1 just as in mode 0.
 *
 * Chart types: vertical bars, a line graph, and a pie (the kernel's
 * cx_pie wedges). Axes are auto-scaled to the data with a rounded top,
 * and every chart can be saved as a BMX image -- so a chart lands in
 * CXRF Paint or any community viewer.
 * ===================================================================== */

#include <cbm.h>
#include "sdk/include_llvm/cxrf.h"
#include "csdk/cxsdk.h"

#define W 320
#define H 240

/* the imported grid: rows x columns of short strings */
#define MAX_ROWS 24
#define MAX_COLS 8
#define CELL_LEN 13

static char  grid[MAX_ROWS][MAX_COLS][CELL_LEN];
static unsigned char n_rows, n_cols;
static unsigned char lab_col = 0;      /* the label column   */
static unsigned char val_col = 1;      /* the value column   */
static unsigned char has_head = 1;     /* row 0 is a header  */
static char  fname[17] = "";
static char  title[24] = "";

/* chart types */
enum { C_BAR, C_LINE, C_PIE };
static unsigned char kind = C_BAR;

/* the series palette: eight readable hues from the 8bpp cube we set up */
#define SER0 32
static const unsigned ser_rgb[8] = {
    0x28C, 0xC42, 0x2A4, 0xCC2, 0x84C, 0x2CC, 0xC82, 0x888
};
#define BG    16                        /* paper (near-white)  */
#define INK   17                        /* text/axis (black)   */
#define GRID_C 18                       /* grid lines (gray)   */

#define P_RAM_BANK (*(volatile unsigned char *)0x0000)
#define V_ADDR_L   (*(volatile unsigned char *)0x9F20)
#define V_ADDR_M   (*(volatile unsigned char *)0x9F21)
#define V_ADDR_H   (*(volatile unsigned char *)0x9F22)
#define V_DATA0    (*(volatile unsigned char *)0x9F23)
#define V_CTRL     (*(volatile unsigned char *)0x9F25)

static unsigned char pal_shadow[512];

static void pal_write(unsigned char i, unsigned rgb) {
    cx_pal_set(i, rgb);
    pal_shadow[(unsigned)i << 1]       = (unsigned char)rgb;
    pal_shadow[((unsigned)i << 1) + 1] = (unsigned char)(rgb >> 8);
}

static void pal_init(void) {
    unsigned char i;
    pal_write(BG,     0xEEE);
    pal_write(INK,    0x000);
    pal_write(GRID_C, 0xAAA);
    for (i = 0; i < 8; i++) pal_write((unsigned char)(SER0 + i), ser_rgb[i]);
}

/* ---- the importer ----------------------------------------------------- */
static char dosname[26];

static void mkname(const char *pre, const char *suf) {
    unsigned char i = 0, j;
    char c;
    for (j = 0; pre[j]; j++) dosname[i++] = pre[j];
    for (j = 0; fname[j] && j < 16; j++) {
        c = fname[j];
        if (c >= 'a' && c <= 'z') c -= 32;      /* PETSCII for DOS */
        dosname[i++] = c;
    }
    for (j = 0; suf[j]; j++) dosname[i++] = suf[j];
    dosname[i] = 0;
}

/* walk the replay commands, filling grid[][] */
static unsigned char import(void) {
    unsigned char r = 0, c = 0, i;
    int ch;
    unsigned char any = 0;
    mkname("", ".SHT,S,R");
    cbm_k_setnam(dosname);
    cbm_k_setlfs(2, 8, 2);
    if (cbm_k_open()) { cbm_k_close(2); return 1; }
    CX_SEI();
    cbm_k_chkin(2);
    for (r = 0; r < MAX_ROWS; r++)
        for (c = 0; c < MAX_COLS; c++) grid[r][c][0] = 0;
    n_rows = 0;
    n_cols = 0;
    r = 0;
    c = 0;
    for (;;) {
        ch = cbm_k_basin();
        if (cbm_k_readst()) break;
        switch (ch) {
        case 'z': case 'Z': r = 0; c = 0; break;
        case 'd': case 'D': if (c + 1 < MAX_COLS) c++; break;
        case 'a': case 'A': if (c) c--; break;
        case 's': case 'S': if (r + 1 < MAX_ROWS) r++; break;
        case 'w': case 'W': if (r) r--; break;
        case '"': case '\'': case '=': case '+':
            i = 0;
            for (;;) {                       /* the cell text, to newline */
                ch = cbm_k_basin();
                if (cbm_k_readst()) break;
                if (ch == '\n' || ch == '\r') break;
                if (i < CELL_LEN - 1) grid[r][c][i++] = (char)ch;
            }
            grid[r][c][i] = 0;
            if (i) {
                any = 1;
                if (r + 1 > n_rows) n_rows = (unsigned char)(r + 1);
                if (c + 1 > n_cols) n_cols = (unsigned char)(c + 1);
            }
            break;
        default: break;                      /* every other key: ignored */
        }
    }
    cbm_k_clrch();
    cbm_k_close(2);
    CX_CLI();
    if (!any) return 2;
    if (n_cols < 2) val_col = 0;
    else if (val_col >= n_cols) val_col = (unsigned char)(n_cols - 1);
    return 0;
}

/* a cell as a number (leading digits, ignoring anything else) */
static unsigned cell_num(unsigned char r, unsigned char c) {
    const char *s = grid[r][c];
    unsigned long v = 0;
    unsigned char i;
    for (i = 0; s[i]; i++)
        if (s[i] >= '0' && s[i] <= '9') {
            v = v * 10 + (unsigned)(s[i] - '0');
            if (v > 65000) return 65000;
        } else if (s[i] == '.') break;         /* whole units only */
    return (unsigned)v;
}

static unsigned char first_data_row(void) { return has_head ? 1 : 0; }

static unsigned char n_points(void) {
    unsigned char f = first_data_row();
    return (unsigned char)(n_rows > f ? n_rows - f : 0);
}

static unsigned data_max(void) {
    unsigned char r, f = first_data_row();
    unsigned m = 0, v;
    for (r = f; r < n_rows; r++) { v = cell_num(r, val_col); if (v > m) m = v; }
    return m ? m : 1;
}

/* the menu bar is declared with the other descriptors below; drawing
 * re-sets it after each clear, so it needs the name early */
static void menu_reset(void);

/* ---- drawing --------------------------------------------------------- */
#define PX 40                              /* plot area */
#define PY 44
#define PW 260
#define PH 160

static char nbuf[8];

static void num_str(unsigned v, char *out) {
    char t[6];
    unsigned char n = 0, i = 0;
    if (!v) { out[0] = '0'; out[1] = 0; return; }
    while (v) { t[n++] = (char)('0' + v % 10); v /= 10; }
    while (n) out[i++] = t[--n];
    out[i] = 0;
}

static void say_ink(const char *s, unsigned x, unsigned y, unsigned char c) {
    cx_ink(c);
    cx_say(s, x, y);
}

static void draw_frame_common(void) {
    cx_clear(BG);
    menu_reset();                 /* the clear takes the bar's pixels with
                                   * it, so re-set it -- menu_set replaces
                                   * its own region instead of stacking a
                                   * second (kernel rg_remove) */
    /* clear of the menu bar (its own rows at the top) */
    if (title[0]) say_ink(title, PX, 22, INK);
    else if (has_head && n_rows) say_ink(grid[0][val_col], PX, 22, INK);
    say_ink(fname[0] ? fname : "F1 open  1 bar  2 line  3 pie", 4, 228,
            GRID_C);
}

/* the value axis: four gridlines with rounded labels */
static void draw_axis(unsigned top) {
    unsigned char i;
    for (i = 0; i <= 4; i++) {
        unsigned y = PY + PH - (unsigned)i * (PH / 4);
        unsigned v = (unsigned)((unsigned long)top * i / 4);
        cx_line(PX, y, PX + PW, y, i ? GRID_C : INK);
        num_str(v, nbuf);
        say_ink(nbuf, 4, y - 3, INK);
    }
    cx_line(PX, PY, PX, PY + PH, INK);
}

static void draw_bars(void) {
    unsigned char n = n_points(), i, f = first_data_row();
    unsigned top = data_max(), bw;
    if (!n) return;
    draw_axis(top);
    bw = PW / n;
    for (i = 0; i < n; i++) {
        unsigned v = cell_num((unsigned char)(f + i), val_col);
        unsigned h = (unsigned)((unsigned long)v * PH / top);
        unsigned x = PX + 2 + (unsigned)i * bw;
        if (h) cx_rect(x, PY + PH - h, bw > 4 ? bw - 4 : 2, h,
                       (unsigned char)(SER0 + (i & 7)));
        if (bw >= 24)                       /* room for a label */
            say_ink(grid[f + i][lab_col], x, PY + PH + 6, INK);
    }
}

static void draw_line(void) {
    unsigned char n = n_points(), i, f = first_data_row();
    unsigned top = data_max(), step;
    unsigned px = 0, py = 0;
    if (!n) return;
    draw_axis(top);
    step = n > 1 ? PW / (n - 1) : PW;
    for (i = 0; i < n; i++) {
        unsigned v = cell_num((unsigned char)(f + i), val_col);
        unsigned x = PX + (unsigned)i * step;
        unsigned y = PY + PH - (unsigned)((unsigned long)v * PH / top);
        if (i) cx_line(px, py, x, y, SER0);
        cx_rect(x > 1 ? x - 1 : 0, y > 1 ? y - 1 : 0, 3, 3, SER0 + 1);
        px = x;
        py = y;
        if (step >= 24) say_ink(grid[f + i][lab_col], x, PY + PH + 6, INK);
    }
}

static void draw_pie(void) {
    unsigned char n = n_points(), i, f = first_data_row();
    unsigned long total = 0;
    unsigned char a0 = 0;
    unsigned cx0 = 110, cy0 = 120;
    if (!n) return;
    for (i = 0; i < n; i++) total += cell_num((unsigned char)(f + i), val_col);
    if (!total) return;
    for (i = 0; i < n; i++) {
        unsigned v = cell_num((unsigned char)(f + i), val_col);
        unsigned char span = (unsigned char)((unsigned long)v * 256 / total);
        unsigned char c = (unsigned char)(SER0 + (i & 7));
        if (!span) continue;
        cx_pie(cx0, cy0, 80, a0, (unsigned char)(a0 + span), c);
        a0 = (unsigned char)(a0 + span);
        /* the legend, to the right */
        cx_rect(210, 40 + (unsigned)i * 12, 10, 8, c);
        say_ink(grid[f + i][lab_col], 224, 40 + (unsigned)i * 12, INK);
    }
}

static void draw_chart(void) {
    draw_frame_common();
    if (!n_rows) {
        say_ink("no data -- File > open a .SHT", PX, PY + 40, INK);
        return;
    }
    switch (kind) {
    case C_BAR:  draw_bars(); break;
    case C_LINE: draw_line(); break;
    case C_PIE:  draw_pie();  break;
    }
}

/* ---- BMX out (v1, 8bpp: the same format Paint reads) ----------------- */
static unsigned char bmx_save(void) {
    unsigned char hdr[16];
    unsigned y, i;
    unsigned char px;
    mkname("S:", ".BMX");
    cx_dos(dosname);
    mkname("", ".BMX,S,W");
    cbm_k_setnam(dosname);
    cbm_k_setlfs(3, 8, 3);
    if (cbm_k_open()) { cbm_k_close(3); return 1; }
    CX_SEI();
    cbm_k_chkout(3);
    hdr[0]='B'; hdr[1]='M'; hdr[2]='X'; hdr[3]=1;
    hdr[4]=8;  hdr[5]=3;
    hdr[6]=(unsigned char)W;  hdr[7]=(unsigned char)(W>>8);
    hdr[8]=(unsigned char)H;  hdr[9]=(unsigned char)(H>>8);
    hdr[10]=0; hdr[11]=0;
    hdr[12]=(unsigned char)(16+512);
    hdr[13]=(unsigned char)((16+512)>>8);
    hdr[14]=0; hdr[15]=0;
    for (i = 0; i < 16; i++) cbm_k_chrout(hdr[i]);
    for (i = 0; i < 512; i++) cbm_k_chrout(pal_shadow[i]);
    for (y = 0; y < H; y++) {
        unsigned long off = (unsigned long)y * W;
        V_CTRL   = 0;
        V_ADDR_L = (unsigned char)off;
        V_ADDR_M = (unsigned char)(off >> 8);
        V_ADDR_H = ((unsigned char)(off >> 16) & 0x0F) | 0x10;
        for (i = 0; i < W; i++) { px = V_DATA0; cbm_k_chrout(px); }
    }
    cbm_k_clrch();
    cbm_k_close(3);
    CX_CLI();
    return 0;
}

/* ---- the menu -------------------------------------------------------- */
CX_MENU_ITEMS(m_file, "open sheet...", "save picture", "quit");
CX_MENU_ITEMS(m_type, "bars", "line", "pie");
CX_MENU_ITEMS(m_data, "value column...", "label column...",
                      "title...", "header row on/off");
CX_MENU_BAR(bar, CX_MENU("File", &m_file), CX_MENU("Chart", &m_type),
                 CX_MENU("Data", &m_data));

static void menu_reset(void) { cx_menu_set(&bar); }



/* ---- local prompt / alert ---------------------------------------------
 * The kernel's cx_prompt and cx_alert size their box from the MODE's
 * dialog metrics, and mode 1's engine carries the 640x480 numbers -- a
 * 400-pixel-wide box overflows this 320x240 screen and draws clipped.
 * So Chart draws its own, the same way apps/paint does, and the whole
 * chart is redrawn afterward anyway.
 * -------------------------------------------------------------------- */
static char ui_key(cx_event *ev) {          /* PETSCII -> ASCII lower */
    unsigned char k = ev->detail;
    if (k >= 0x41 && k <= 0x5A) return (char)(k + 32);
    if (k >= 0xC1 && k <= 0xDA) return (char)(k - 128);
    return (char)k;
}

/* a modal line editor in a small box: 1 = accepted, 0 = cancelled */
static unsigned char ask(const char *msg, char *buf, unsigned char cap) {
    cx_event ev;
    unsigned char len = 0, redraw = 1;
    char k;
    while (buf[len]) len++;
    for (;;) {
        if (redraw) {
            cx_rect(30, 80, 260, 56, GRID_C);
            cx_frame(30, 80, 260, 56, INK);
            say_ink(msg, 38, 88, INK);
            cx_rect(38, 104, 244, 12, BG);
            say_ink(buf, 42, 106, INK);
            cx_rect(42 + cx_measure(buf), 106, 6, 8, SER0);
            redraw = 0;
        }
        if (!cx_poll(&ev)) continue;
        if (ev.type == CX_ET_DOWN && (ev.detail & 2)) return 0;
        if (ev.type != CX_ET_KEY) continue;
        if (ev.detail == CX_K_DEL) {
            if (len) buf[--len] = 0;
            redraw = 1;
            continue;
        }
        k = ui_key(&ev);
        if (k == 0x1B) return 0;
        if (k == 0x0D) return len != 0;
        if (len < cap && k >= ' ' && k < 0x7F) {
            buf[len++] = k;
            buf[len] = 0;
            redraw = 1;
        }
    }
}

/* a modal message: any key (or a click) dismisses it */
static void note(const char *msg) {
    cx_event ev;
    cx_rect(30, 90, 260, 40, GRID_C);
    cx_frame(30, 90, 260, 40, INK);
    say_ink(msg, 38, 100, INK);
    say_ink("[any key]", 38, 114, INK);
    for (;;) {
        if (!cx_poll(&ev)) continue;
        if (ev.type == CX_ET_KEY || ev.type == CX_ET_DOWN) return;
    }
}

/* ---- commands -------------------------------------------------------- */
static char pbuf[8];

static void cmd_open(void) {
    unsigned char e;
    if (!ask("open sheet file:", fname, 16)) { draw_chart(); return; }
    e = import();
    draw_chart();
    if (e == 1) { note("that file would not open."); draw_chart(); }
    else if (e == 2) { note("no table in that file."); draw_chart(); }
}

static void cmd_col(unsigned char which) {     /* 0 = value, 1 = label */
    unsigned char v;
    num_str(which ? lab_col + 1 : val_col + 1, pbuf);
    if (ask(which ? "label column (1-8):" : "value column (1-8):",
            pbuf, 2)) {
        v = (unsigned char)(pbuf[0] - '0');
        if (v >= 1 && v <= MAX_COLS) {
            if (which) lab_col = (unsigned char)(v - 1);
            else       val_col = (unsigned char)(v - 1);
        }
    }
    draw_chart();
}

static void cmd_title(void) {
    ask("chart title:", title, 22);
    draw_chart();
}

int main(void) {
    cx_event ev;

    cx_print("CHART UP");
    cx_mode(CX_MODE_BMPLOW, 8);
    pal_init();

    cx_ev_init();                 /* BEFORE menu_set: ev_init resets the
                                   * region stack, and the bar's click
                                   * region must survive */
    cx_menu_set(&bar);
    cx_mouse_show(1);
    draw_chart();

    for (;;) {
        if (!cx_next(&ev)) continue;
        switch (ev.type) {
        case CX_ET_MENU:
            if (ev.x == 0) {                        /* File */
                if (ev.detail == 0) cmd_open();
                else if (ev.detail == 1) {
                    if (!fname[0] && !ask("picture name:", fname, 16)) {
                        draw_chart();
                        break;
                    }
                    if (bmx_save()) { draw_chart(); note("could not write."); }
                    draw_chart();
                } else {
                    cx_mode(CX_MODE_BMPHIGH, 2);    /* the desktop's mode */
                    cx_exit();
                }
            } else if (ev.x == 1) {                 /* Chart */
                kind = ev.detail;
                draw_chart();
            } else {                                /* Data */
                switch (ev.detail) {
                case 0: cmd_col(0); break;
                case 1: cmd_col(1); break;
                case 2: cmd_title(); break;
                case 3: has_head = !has_head; draw_chart(); break;
                }
            }
            break;
        case CX_ET_KEY: {
            unsigned char k = ev.detail;
            if (k == '1') { kind = C_BAR;  draw_chart(); break; }
            if (k == '2') { kind = C_LINE; draw_chart(); break; }
            if (k == '3') { kind = C_PIE;  draw_chart(); break; }
            if (k == 'o' || k == 'O') { cmd_open(); break; }
            if (cx_menu_key(k)) break;
            if (k == CX_K_ESC) {
                cx_mode(CX_MODE_BMPHIGH, 2);
                cx_exit();
            }
            break;
        }
        }
    }
}
