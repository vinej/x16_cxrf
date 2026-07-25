/* =====================================================================
 * CXRF :: apps/data/data.c -- CXRF Data, the record manager (llvm-mos)
 * =====================================================================
 * A flat-file database for the CXRF desktop, on the 640x480 GUI
 * (CX_MODE_BMPHIGH at bpp 2) with the toolkit: a menu bar, modal panels
 * for editing, dialogs for confirmation, and a hand-drawn table grid.
 *
 * Data model: FIXED-LENGTH records so record n is a pure offset, which
 * is what keeps browsing and sorting cheap. A schema of up to DB_FIELDS
 * fields, each a name + type + display width; a record is REC_LEN bytes
 * of field values laid out in schema order. Types:
 *
 *   F_TEXT    a NUL-padded string
 *   F_NUM     an ASCII decimal (parsed on demand; keeps edit/display
 *             trivial and sorts numerically via ordkey below)
 *   F_DATE    YYYYMMDD as text -- sorts correctly as a string
 *   F_FLAG    'y' or 'n', shown as a checkbox in the form
 *
 * Storage: the records live in the CXRF app banks from DB_BANK up, one
 * 8 KB window at a time (RECS_PER_BANK records each), never in low RAM.
 * A parallel ORDER array (in low RAM) holds record indices, so sorting
 * and filtering permute pointers and the records themselves never move.
 *
 * Files: .CXR -- a 16-byte header (magic "CXDB"), the schema block, then
 * the records verbatim, as a SEQ file over CMDR-DOS. "Export to Sheet"
 * writes the keystroke-replay format CXRF Sheet loads (see
 * apps/sheet/README.md), so a table opens in the spreadsheet natively.
 * ===================================================================== */

#include <cbm.h>
#include "sdk/include_llvm/cxrf.h"
#include "csdk/cxsdk.h"

/* ---- the schema ------------------------------------------------------ */
#define F_TEXT 0
#define F_NUM  1
#define F_DATE 2
#define F_FLAG 3

#define DB_FIELDS   6
#define NAME_LEN    9             /* field names: 8 chars + NUL          */
#define REC_LEN     96
#define DB_BANK     20
#define RECS_PER_BANK (8192 / REC_LEN)     /* 85 */
#define MAX_RECS    1200          /* 15 banks; the ORDER array bounds it */

typedef struct {
    char          name[NAME_LEN];
    unsigned char type;
    unsigned char off;            /* byte offset inside a record        */
    unsigned char len;            /* bytes reserved                     */
    unsigned char cols;           /* display width, in characters       */
} field_def;

/* The v1 schema: an address-book shape, general enough to be useful and
 * fixed so there is no schema editor yet (the file header carries it, so
 * a later version can vary it without breaking files). */
static field_def fields[DB_FIELDS] = {
    { "name",    F_TEXT,  0, 24, 18 },
    { "company", F_TEXT, 24, 24, 16 },
    { "phone",   F_TEXT, 48, 14, 12 },
    { "amount",  F_NUM,  62, 10,  9 },
    { "date",    F_DATE, 72,  9,  8 },
    { "paid",    F_FLAG, 81,  1,  4 },
};

/* ---- the store ------------------------------------------------------- */
#define P_RAM_BANK (*(volatile unsigned char *)0x0000)

static unsigned n_recs;                    /* records in the table      */
static unsigned order[MAX_RECS];           /* view order (record ids)    */
static unsigned n_view;                    /* rows in the current view   */
static unsigned cur;                       /* the selected VIEW row      */
static unsigned top;                       /* first visible view row     */
static char     dirty;
static char     filtered;
static char     dbname[17] = "";

/* record id -> its bank window address; selects the bank as a side
 * effect, so the returned pointer is only valid until the next call */
static char *rec_ptr(unsigned id) {
    P_RAM_BANK = (unsigned char)(DB_BANK + id / RECS_PER_BANK);
    return (char *)(0xA000 + (id % RECS_PER_BANK) * REC_LEN);
}

/* field f of record id, copied into a low-RAM scratch buffer (the caller
 * must not hold a bank pointer across another rec_ptr) */
static char fbuf[32];

static char *rec_field(unsigned id, unsigned char f) {
    char *r = rec_ptr(id) + fields[f].off;
    unsigned char i, n = fields[f].len;
    if (n > 31) n = 31;
    for (i = 0; i < n; i++) fbuf[i] = r[i];
    fbuf[n] = 0;
    return fbuf;
}

static void rec_set(unsigned id, unsigned char f, const char *s) {
    char *r = rec_ptr(id) + fields[f].off;
    unsigned char i, n = fields[f].len;
    for (i = 0; i < n; i++) r[i] = s[i] ? s[i] : 0;
}

static void rec_clear(unsigned id) {
    char *r = rec_ptr(id);
    unsigned i;
    for (i = 0; i < REC_LEN; i++) r[i] = 0;
}

/* ---- the view -------------------------------------------------------- */
static void view_all(void) {
    unsigned i;
    for (i = 0; i < n_recs; i++) order[i] = i;
    n_view = n_recs;
    filtered = 0;
    if (cur >= n_view) cur = n_view ? n_view - 1 : 0;
    top = 0;
}

/* ---- layout ---------------------------------------------------------- */
#define GRID_X    12
#define GRID_Y    52
#define ROW_H     14
#define ROWS      26              /* visible table rows                  */
#define CH_W      8               /* the grid's per-character step       */

static unsigned col_x[DB_FIELDS + 1];

static void layout(void) {
    unsigned char f;
    unsigned x = GRID_X + 4;
    for (f = 0; f < DB_FIELDS; f++) {
        col_x[f] = x;
        x += (unsigned)fields[f].cols * CH_W + 8;
    }
    col_x[DB_FIELDS] = x;
}

/* ---- drawing --------------------------------------------------------- */
static char line[80];

static void num_str(unsigned v, char *out) {   /* small unsigned -> text */
    char t[6];
    unsigned char n = 0, i = 0;
    if (!v) { out[0] = '0'; out[1] = 0; return; }
    while (v) { t[n++] = (char)('0' + v % 10); v /= 10; }
    while (n) out[i++] = t[--n];
    out[i] = 0;
}

static void draw_status(void) {
    char n1[6], n2[6];
    unsigned char i = 0, j;
    cx_rect(GRID_X, 30, 616, 16, CX_PAPER);
    num_str(n_view ? cur + 1 : 0, n1);
    num_str(n_view, n2);
    for (j = 0; n1[j]; j++) line[i++] = n1[j];
    line[i++] = '/';
    for (j = 0; n2[j]; j++) line[i++] = n2[j];
    line[i] = 0;
    cx_ink(CX_FRAME);
    cx_say(line, GRID_X + 4, 32);
    if (filtered) cx_say("filtered", GRID_X + 90, 32);
    if (dirty)    cx_say("modified", GRID_X + 170, 32);
    if (dbname[0]) cx_say(dbname, GRID_X + 260, 32);
}

static void draw_row(unsigned vrow) {          /* vrow = a VIEW index */
    unsigned y = GRID_Y + 18 + (vrow - top) * ROW_H;
    unsigned char f;
    unsigned char sel = (vrow == cur);
    if (vrow < top || vrow >= top + ROWS || vrow >= n_view) return;
    cx_rect(GRID_X + 1, y, 614, ROW_H, sel ? CX_HI : CX_PAPER);
    cx_ink(CX_FRAME);
    for (f = 0; f < DB_FIELDS; f++) {
        char *v = rec_field(order[vrow], f);
        v[fields[f].cols] = 0;                 /* clip to the column */
        cx_say(v, col_x[f], y + 2);
    }
}

static void draw_grid(void) {
    unsigned char f;
    unsigned vrow;
    cx_rect(GRID_X, GRID_Y, 616, 18 + ROWS * ROW_H, CX_PAPER);
    cx_frame(GRID_X, GRID_Y, 616, 18 + ROWS * ROW_H, CX_FRAME);
    cx_rect(GRID_X + 1, GRID_Y + 1, 614, 16, CX_HI);
    cx_ink(CX_FRAME);
    for (f = 0; f < DB_FIELDS; f++)
        cx_say(fields[f].name, col_x[f], GRID_Y + 3);
    for (vrow = top; vrow < top + ROWS; vrow++) draw_row(vrow);
}

static void scroll_to_cur(void) {
    if (cur < top) top = cur;
    else if (cur >= top + ROWS) top = cur - ROWS + 1;
}

static void repaint(void) {
    scroll_to_cur();
    draw_grid();
    draw_status();
}

/* ---- editing a record ------------------------------------------------
 * One labelled modal line editor per field (cx_prompt), in schema order,
 * pre-filled with the current value. Esc at any field abandons the whole
 * edit -- values are written back only after the last field is accepted.
 *
 * Why not one big panel of fields? A panel's box goes through the mode's
 * SAVE-UNDER, which in mode 0 is banks 14-15 = about 102 pixel rows. A
 * taller box runs off the end of bank 15 into bank 16 -- the widget
 * engine's own bank -- and the panel then jumps into the pixels that
 * overwrote it (a crash to the monitor at $A009, bank 16). Anything
 * modal here stays within the dialog metric's 96 rows.
 * -------------------------------------------------------------------- */
static char e_val[DB_FIELDS][25];
static char e_lbl[16];

static unsigned char edit_fields(unsigned id) {
    unsigned char f, i, j;
    for (f = 0; f < DB_FIELDS; f++) {
        char *v = rec_field(id, f);
        for (i = 0; v[i] && i < 24; i++) e_val[f][i] = v[i];
        e_val[f][i] = 0;
        for (j = 0; fields[f].name[j]; j++) e_lbl[j] = fields[f].name[j];
        if (fields[f].type == F_FLAG) {
            e_lbl[j++] = ' ';
            e_lbl[j++] = '(';
            e_lbl[j++] = 'y';
            e_lbl[j++] = '/';
            e_lbl[j++] = 'n';
            e_lbl[j++] = ')';
        }
        e_lbl[j++] = ':';
        e_lbl[j] = 0;
        /* the prompt's CAPACITY is the buffer size, and it allows
         * capacity-1 characters -- so len+1 lets a field be typed to
         * its full width. (len-1 made the 1-byte flag field a capacity
         * of 0, which the prompt refuses outright: it returned
         * "cancelled" and silently abandoned every add.) */
        if (cx_prompt(e_lbl, e_val[f],
                      (unsigned char)(fields[f].len + 1)) < 0)
            return 0;                        /* Esc: abandon the edit */
    }
    for (f = 0; f < DB_FIELDS; f++) {
        if (fields[f].type == F_FLAG) {
            char yn[2];
            yn[0] = (e_val[f][0] == 'y' || e_val[f][0] == 'Y') ? 'y' : 'n';
            yn[1] = 0;
            rec_set(id, f, yn);
        } else {
            rec_set(id, f, e_val[f]);
        }
    }
    dirty = 1;
    return 1;
}

/* ---- sorting: an insertion sort over the ORDER array ----------------- */
/* the key of a record's sort field, as a comparable byte string. Numbers
 * are right-aligned into a fixed width so a plain string compare orders
 * them numerically. */
static unsigned char sort_field;
static char keya[24], keyb[24];

static void ordkey(unsigned id, char *out) {
    char *v = rec_field(id, sort_field);
    unsigned char n = fields[sort_field].cols;
    unsigned char i, l = 0;
    while (v[l]) l++;
    if (fields[sort_field].type == F_NUM) {
        for (i = 0; i + l < n; i++) out[i] = ' ';   /* right-align */
        for (l = 0; v[l]; l++) out[i++] = v[l];
        out[i] = 0;
    } else {
        for (i = 0; i < n && v[i]; i++)
            out[i] = (v[i] >= 'A' && v[i] <= 'Z') ? (char)(v[i] + 32) : v[i];
        out[i] = 0;
    }
}

static void sort_view(unsigned char f) {
    unsigned i, j;
    unsigned id;
    sort_field = f;
    for (i = 1; i < n_view; i++) {
        id = order[i];
        ordkey(id, keya);
        j = i;
        while (j) {
            unsigned char k = 0, less = 0;
            ordkey(order[j - 1], keyb);
            while (keya[k] == keyb[k] && keya[k]) k++;
            less = (unsigned char)keya[k] < (unsigned char)keyb[k];
            if (!less) break;
            order[j] = order[j - 1];
            j--;
        }
        order[j] = id;
    }
    cur = 0;
    top = 0;
}

/* ---- find and filter ------------------------------------------------- */
static char pat[24];

static char contains(const char *hay, const char *needle) {
    unsigned char i, j;
    if (!needle[0]) return 1;
    for (i = 0; hay[i]; i++) {
        for (j = 0; needle[j]; j++) {
            char a = hay[i + j], b = needle[j];
            if (a >= 'A' && a <= 'Z') a += 32;
            if (b >= 'A' && b <= 'Z') b += 32;
            if (a != b) break;
        }
        if (!needle[j]) return 1;
    }
    return 0;
}

static char rec_matches(unsigned id) {
    unsigned char f;
    for (f = 0; f < DB_FIELDS; f++)
        if (contains(rec_field(id, f), pat)) return 1;
    return 0;
}

static void do_filter(void) {
    unsigned i, n = 0;
    for (i = 0; i < n_recs; i++)
        if (rec_matches(i)) order[n++] = i;
    n_view = n;
    filtered = 1;
    cur = 0;
    top = 0;
}

static void do_find(void) {
    unsigned i;
    for (i = cur + 1; i < n_view; i++)
        if (rec_matches(order[i])) { cur = i; return; }
    for (i = 0; i <= cur && i < n_view; i++)
        if (rec_matches(order[i])) { cur = i; return; }
}

/* ---- files ----------------------------------------------------------- */
static char dosname[26];

static void mkname(const char *pre, const char *suf) {
    unsigned char i = 0, j;
    char c;
    for (j = 0; pre[j]; j++) dosname[i++] = pre[j];
    for (j = 0; dbname[j] && j < 16; j++) {
        c = dbname[j];
        if (c >= 'a' && c <= 'z') c -= 32;     /* PETSCII for DOS */
        dosname[i++] = c;
    }
    for (j = 0; suf[j]; j++) dosname[i++] = suf[j];
    dosname[i] = 0;
}

static unsigned char db_save(void) {
    unsigned char hdr[16];
    unsigned i;
    unsigned char f, j;
    mkname("S:", ".CXR");                      /* replace any old file */
    cx_dos(dosname);
    mkname("", ".CXR,S,W");
    cbm_k_setnam(dosname);
    cbm_k_setlfs(3, 8, 3);
    if (cbm_k_open()) { cbm_k_close(3); return 1; }
    CX_SEI();
    cbm_k_chkout(3);
    hdr[0]='C'; hdr[1]='X'; hdr[2]='D'; hdr[3]='B';
    hdr[4]=1;                                   /* version            */
    hdr[5]=DB_FIELDS;
    hdr[6]=REC_LEN;
    hdr[7]=(unsigned char)n_recs;
    hdr[8]=(unsigned char)(n_recs >> 8);
    for (i = 9; i < 16; i++) hdr[i] = 0;
    for (i = 0; i < 16; i++) cbm_k_chrout(hdr[i]);
    for (f = 0; f < DB_FIELDS; f++) {           /* the schema block   */
        for (j = 0; j < NAME_LEN; j++) cbm_k_chrout((unsigned char)fields[f].name[j]);
        cbm_k_chrout(fields[f].type);
        cbm_k_chrout(fields[f].off);
        cbm_k_chrout(fields[f].len);
        cbm_k_chrout(fields[f].cols);
    }
    for (i = 0; i < n_recs; i++) {              /* the records        */
        char *r = rec_ptr(i);
        for (j = 0; j < REC_LEN; j++) cbm_k_chrout((unsigned char)r[j]);
    }
    cbm_k_clrch();
    cbm_k_close(3);
    CX_CLI();
    dirty = 0;
    return 0;
}

static unsigned char db_load(void) {
    unsigned char hdr[16];
    unsigned i, count;
    unsigned char f, j;
    mkname("", ".CXR,S,R");
    cbm_k_setnam(dosname);
    cbm_k_setlfs(2, 8, 2);
    if (cbm_k_open()) { cbm_k_close(2); return 1; }
    CX_SEI();
    cbm_k_chkin(2);
    for (i = 0; i < 16; i++) hdr[i] = cbm_k_basin();
    if (cbm_k_readst() || hdr[0]!='C' || hdr[1]!='X' || hdr[2]!='D' ||
        hdr[3]!='B' || hdr[4]!=1 || hdr[5]!=DB_FIELDS || hdr[6]!=REC_LEN) {
        cbm_k_clrch(); cbm_k_close(2); CX_CLI(); return 2;
    }
    count = hdr[7] | ((unsigned)hdr[8] << 8);
    if (count > MAX_RECS) count = MAX_RECS;
    for (f = 0; f < DB_FIELDS; f++) {           /* skip the schema    */
        for (j = 0; j < NAME_LEN + 4; j++) cbm_k_basin();
    }
    for (i = 0; i < count; i++) {
        char *r = rec_ptr(i);
        for (j = 0; j < REC_LEN; j++) r[j] = (char)cbm_k_basin();
    }
    cbm_k_clrch();
    cbm_k_close(2);
    CX_CLI();
    n_recs = count;
    cur = 0;
    view_all();
    dirty = 0;
    return 0;
}

/* Export the view as a CXRF Sheet file: the keystroke replay Sheet's
 * loader interprets -- 'z' home, then per cell a '"' label or '=' value
 * with its text and a newline, 'd' to step right, 's' to start the next
 * row. Column A gets the first field, and so on. */
static unsigned char sheet_export(void) {
    unsigned v;
    unsigned char f, j;
    mkname("S:", ".SHT");
    cx_dos(dosname);
    mkname("", ".SHT,S,W");
    cbm_k_setnam(dosname);
    cbm_k_setlfs(3, 8, 3);
    if (cbm_k_open()) { cbm_k_close(3); return 1; }
    CX_SEI();
    cbm_k_chkout(3);
    cbm_k_chrout('z');                          /* home */
    for (f = 0; f < DB_FIELDS; f++) {           /* the header row */
        cbm_k_chrout('"');
        for (j = 0; fields[f].name[j]; j++)
            cbm_k_chrout((unsigned char)fields[f].name[j]);
        cbm_k_chrout('\n');
        cbm_k_chrout('d');
    }
    cbm_k_chrout('s');
    for (v = 0; v < n_view && v < 99; v++) {
        for (f = 0; f < DB_FIELDS; f++) {
            char *s = rec_field(order[v], f);
            if (s[0]) {
                cbm_k_chrout(fields[f].type == F_NUM ? '=' : '"');
                for (j = 0; s[j]; j++) cbm_k_chrout((unsigned char)s[j]);
                cbm_k_chrout('\n');
            }
            cbm_k_chrout('d');
        }
        cbm_k_chrout('s');
    }
    cbm_k_chrout('z');
    cbm_k_clrch();
    cbm_k_close(3);
    CX_CLI();
    return 0;
}

/* ---- totals ---------------------------------------------------------- */
/* count / sum / average of the first F_NUM field over the current view,
 * in whole units (the amounts are integers in this schema) */
static void totals_msg(char *out) {
    unsigned long sum = 0;
    unsigned v, n = 0;
    unsigned char f, i = 0, j;
    char t[12];
    for (f = 0; f < DB_FIELDS; f++) if (fields[f].type == F_NUM) break;
    if (f == DB_FIELDS) { out[0] = 0; return; }
    for (v = 0; v < n_view; v++) {
        char *s = rec_field(order[v], f);
        unsigned long val = 0;
        char any = 0;
        for (j = 0; s[j]; j++)
            if (s[j] >= '0' && s[j] <= '9') { val = val * 10 + (s[j] - '0'); any = 1; }
        if (any) { sum += val; n++; }
    }
    for (j = 0; fields[f].name[j]; j++) out[i++] = fields[f].name[j];
    out[i++] = ':'; out[i++] = ' ';
    num_str((unsigned)n, t);
    for (j = 0; t[j]; j++) out[i++] = t[j];
    out[i++] = ' '; out[i++] = 'v'; out[i++] = 'a'; out[i++] = 'l';
    out[i++] = 's'; out[i++] = ' '; out[i++] = 's'; out[i++] = 'u';
    out[i++] = 'm'; out[i++] = ' ';
    num_str((unsigned)(sum > 65535 ? 65535 : sum), t);
    for (j = 0; t[j]; j++) out[i++] = t[j];
    if (n) {
        out[i++] = ' '; out[i++] = 'a'; out[i++] = 'v'; out[i++] = 'g';
        out[i++] = ' ';
        num_str((unsigned)(sum / n), t);
        for (j = 0; t[j]; j++) out[i++] = t[j];
    }
    out[i] = 0;
}

/* ---- the menu -------------------------------------------------------- */
CX_MENU_ITEMS(m_file,   "new", "open...", "save", "save as...",
                        "export to sheet", "quit");
CX_MENU_ITEMS(m_rec,    "add", "edit", "duplicate", "delete");
CX_MENU_ITEMS(m_view,   "sort by field...", "find...", "filter...",
                        "show all", "totals");
CX_MENU_BAR(bar, CX_MENU("File", &m_file), CX_MENU("Record", &m_rec),
                 CX_MENU("View", &m_view));

CX_DIALOG(dlg_del,  "delete this record?", "keep", "delete");
CX_DIALOG(dlg_new,  "discard the current table?", "keep", "discard");
CX_DIALOG(dlg_full, "the table is full.", "ok");
CX_DIALOG(dlg_err,  "that file would not open.", "ok");
CX_DIALOG(dlg_none, "no records yet -- Record > add.", "ok");

/* A sort-field chooser: six radios in TWO COLUMNS so the box stays
 * inside the save-under's ~102 rows (see edit_fields above). */
CX_WIDGETS(sort_wg,
    CX_RADIO(140, 208, 160, 1, 1, "name"),
    CX_RADIO(140, 230, 160, 0, 1, "company"),
    CX_RADIO(140, 252, 160, 0, 1, "phone"),
    CX_RADIO(330, 208, 160, 0, 1, "amount"),
    CX_RADIO(330, 230, 160, 0, 1, "date"),
    CX_RADIO(330, 252, 160, 0, 1, "paid")
);

static const struct CX_PACKED {
    unsigned int  x, y, w;
    unsigned char h;
    const void   *title;
    const void   *widgets;
    unsigned char nbtn;
    const void   *b[2];
} sort_panel = { 100, 180, 440, 96, "sort by", &sort_wg, 2,
                 { "sort", "cancel" } };

/* ---- commands -------------------------------------------------------- */
static char msgbuf[64];

static void cmd_add(void) {
    if (n_recs >= MAX_RECS) { cx_alert(&dlg_full); repaint(); return; }
    rec_clear(n_recs);
    if (edit_fields(n_recs)) {
        n_recs++;
        view_all();
        cur = n_view ? n_view - 1 : 0;
    }
    repaint();
}

static void cmd_edit(void) {
    if (!n_view) { cx_alert(&dlg_none); repaint(); return; }
    edit_fields(order[cur]);
    repaint();
}

static void cmd_dup(void) {
    unsigned char j;
    char *src, *dst;
    if (!n_view) { cx_alert(&dlg_none); repaint(); return; }
    if (n_recs >= MAX_RECS) { cx_alert(&dlg_full); repaint(); return; }
    for (j = 0; j < REC_LEN; j++) {             /* through fbuf-sized hops */
        src = rec_ptr(order[cur]);
        msgbuf[0] = src[j];
        dst = rec_ptr(n_recs);
        dst[j] = msgbuf[0];
    }
    n_recs++;
    view_all();
    cur = n_view - 1;
    dirty = 1;
    repaint();
}

static void cmd_delete(void) {
    unsigned id, i;
    unsigned char j;
    if (!n_view) { cx_alert(&dlg_none); repaint(); return; }
    if (cx_alert(&dlg_del) != 1) { repaint(); return; }
    id = order[cur];
    for (i = id; i + 1 < n_recs; i++) {         /* close the gap */
        for (j = 0; j < REC_LEN; j++) {
            char *s = rec_ptr(i + 1);
            msgbuf[0] = s[j];
            { char *d = rec_ptr(i); d[j] = msgbuf[0]; }
        }
    }
    n_recs--;
    view_all();
    if (cur >= n_view && cur) cur--;
    dirty = 1;
    repaint();
}

static void cmd_sort(void) {
    unsigned char f;
    if (cx_panel(&sort_panel) == 0) {
        for (f = 0; f < DB_FIELDS; f++)
            if (sort_wg.w[f].val) { sort_view(f); break; }
    }
    repaint();
}

static void cmd_find(char do_filt) {
    if (cx_prompt(do_filt ? "filter for:" : "find:", pat, 20) >= 0) {
        if (do_filt) do_filter();
        else         do_find();
    }
    repaint();
}

static void cmd_totals(void) {
    static const struct CX_PACKED {
        unsigned char n;
        const void *msg;
        const void *button[1];
    } d = { 1, msgbuf, { "ok" } };
    totals_msg(msgbuf);
    if (msgbuf[0]) cx_alert(&d);
    repaint();
}

static void cmd_save(char ask) {
    if (ask || !dbname[0]) {
        if (cx_prompt("save as:", dbname, 16) < 0) { repaint(); return; }
    }
    if (db_save()) cx_alert(&dlg_err);
    repaint();
}

static void cmd_open(void) {
    if (cx_prompt("open:", dbname, 16) < 0) { repaint(); return; }
    if (db_load()) cx_alert(&dlg_err);
    repaint();
}

static void cmd_new(void) {
    if (n_recs && cx_alert(&dlg_new) != 1) { repaint(); return; }
    n_recs = 0;
    cur = 0;
    dbname[0] = 0;
    dirty = 0;
    view_all();
    repaint();
}

static void cmd_export(void) {
    if (!dbname[0]) {
        if (cx_prompt("export name:", dbname, 16) < 0) { repaint(); return; }
    }
    if (sheet_export()) cx_alert(&dlg_err);
    repaint();
}

/* ---- main ------------------------------------------------------------ */
int main(void) {
    cx_event ev;

    cx_print("DATA UP");
    cx_gfx_init();                       /* the desktop's mode 0 */
    layout();
    view_all();

    cx_clear(CX_PAPER);
    cx_ink(CX_FRAME);
    cx_say("CXRF Data -- File / Record / View from the menu bar", GRID_X, 12);

    /* ev_init RESETS the region stack, so it must run BEFORE menu_set --
     * the other way round wiped the menu bar's click region and no pick
     * ever routed */
    cx_ev_init();
    cx_menu_set(&bar);
    cx_mouse_show(1);
    repaint();

    for (;;) {
        if (!cx_next(&ev)) continue;
        switch (ev.type) {
        case CX_ET_MENU:
            if (ev.x == 0) {                     /* File */
                switch (ev.detail) {
                case 0: cmd_new(); break;
                case 1: cmd_open(); break;
                case 2: cmd_save(0); break;
                case 3: cmd_save(1); break;
                case 4: cmd_export(); break;
                case 5: cx_exit();
                }
            } else if (ev.x == 1) {              /* Record */
                switch (ev.detail) {
                case 0: cmd_add(); break;
                case 1: cmd_edit(); break;
                case 2: cmd_dup(); break;
                case 3: cmd_delete(); break;
                }
            } else {                             /* View */
                switch (ev.detail) {
                case 0: cmd_sort(); break;
                case 1: cmd_find(0); break;
                case 2: cmd_find(1); break;
                case 3: view_all(); repaint(); break;
                case 4: cmd_totals(); break;
                }
            }
            break;
        case CX_ET_KEY: {
            unsigned char k = ev.detail;
            /* our own shortcuts first: cx_menu_key eats plain letters as
             * menu accelerators, so a letter handed to it never comes back */
            if (k == 'a' || k == 'A' || k == 0xC1) { cmd_add(); break; }
            if (cx_menu_key(k)) break;           /* then the menu bar */
            if (k == CX_K_DOWN) {
                if (n_view && cur + 1 < n_view) { cur++; repaint(); }
            } else if (k == CX_K_UP) {
                if (cur) { cur--; repaint(); }
            } else if (k == CX_K_ENTER) {
                cmd_edit();
            } else if (k == CX_K_ESC) {
                cx_exit();
            }
            break;
        }
        case CX_ET_DOWN:
        case CX_ET_DBL: {
            unsigned y = ev.y;
            if (y >= GRID_Y + 18 && y < GRID_Y + 18 + ROWS * ROW_H) {
                unsigned vrow = top + (y - GRID_Y - 18) / ROW_H;
                if (vrow < n_view) {
                    cur = vrow;
                    repaint();
                    if (ev.type == CX_ET_DBL) cmd_edit();
                }
            }
            break;
        }
        }
    }
}
