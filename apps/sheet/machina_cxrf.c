/* =====================================================================
 * CXRF :: apps/sheet/machina_cxrf.c -- the CXRF platform layer for
 * X16Cell (Thomas DiModica, BSD-3-Clause -- see LICENSE), implementing
 * the machina.h contract over the CXRF C SDK instead of cc65 conio.
 *
 * Screen: CX_MODE_TEXT (the KERNAL 80x60 grid). The UI writes a lot of
 * single characters, so output is batched: putch/puts accumulate a run
 * at the cursor in one colour pair, and the run flushes (paper rect +
 * ink + cx_say) when the cursor jumps, the pair changes, or input is
 * read. Colour pairs map to mode-3 attributes; note the kernel's text
 * engine substitutes the dialog paper for a colour-0 fill, so "black"
 * backgrounds are avoided.
 *
 * Store: X16Cell keeps the cell table + cell text in banked RAM. CXRF
 * apps own banks 20-63 (CX_APP_BANK_FLOOR): the reserved page (the
 * 5,200-byte cell table) is bank 20, the 41 text pages ride banks
 * 21-61.
 * ===================================================================== */
#include "machina.h"

#define SHEET_BANK_RESERVED 20U   /* the cell table's bank              */
#define SHEET_BANK_NORMAL   21U   /* cell text pages 0-40 -> banks 21-61 */

#define CX_RAM_BANK (*(volatile byte*)0)

void setStorePageReserved (byte pageNo)
 {
   CX_RAM_BANK = pageNo + SHEET_BANK_RESERVED;
 }

void setStorePage (byte pageNo)
 {
   CX_RAM_BANK = pageNo + SHEET_BANK_NORMAL;
 }

char* getStore (byte indexInCurrentPage)
 {
   word location = indexInCurrentPage;
   location <<= 7;
   location += 0xA000U;
   return (char*)location;
 }

/* --- the text console: direct VERA writes -----------------------------
 * A spreadsheet repaints thousands of cells; going through the mode-3
 * port (per-op PLOT + CHROUT in the KERNAL editor) was visibly slow
 * and inherited the editor's wrap/scroll behaviour, which corrupted
 * full-screen repaints. A conio layer on this machine IS the text map:
 * the KERNAL screen the kernel's mode 3 programs lives at VRAM $1B000,
 * 256 bytes a row (128 cells x char+attr) -- so runs go straight in
 * through VERA data port 1 (port 0 belongs to the mouse IRQ), with
 * interrupts masked across the address setup + stream. The mode is
 * still entered through cx_mode(3, 0), so the kernel owns the display
 * and cx_exit restores the desktop as usual.
 * -------------------------------------------------------------------- */
#define V_ADDR_L  (*(volatile byte*)0x9F20)
#define V_ADDR_M  (*(volatile byte*)0x9F21)
#define V_ADDR_H  (*(volatile byte*)0x9F22)
#define V_DATA1   (*(volatile byte*)0x9F24)
#define V_CTRL    (*(volatile byte*)0x9F25)

static byte m_x, m_y;             /* the cursor */
static byte m_pair = COLOR_NORMAL;
static byte m_bx, m_by, m_bpair;  /* the pending run's origin and pair */
static byte m_blen;
static char m_run [81];

/* pair -> attribute nibbles (VERA text colours): header black-on-gray,
 * normal gray-on-blue, highlight black-on-white (the upstream
 * blue-on-black read poorly on the current row/column markers) */
static const byte m_attr [4] = { 0x61U, 0xF0U, 0x6FU, 0x10U };

/* ASCII -> screen code, for the upper/lower charset mode 3 selects */
static byte m_screencode (byte ch)
 {
   if ((ch >= 97U) && (ch <= 122U)) return ch - 96U;   /* a-z -> 1-26  */
   if (ch == 64U) return 0U;                           /* @            */
   if ((ch >= 91U) && (ch <= 95U)) return ch - 64U;    /* [ \ ] ^ _    */
   return ch;                     /* space-'?' and A-Z map straight in */
 }

static void m_flush (void)
 {
   byte i, attr;
   if (0U == m_blen) return;
   attr = m_attr[m_bpair];
   if (COLOR_HIGHLIGHT == m_bpair)
    {
      /* HIGHLIGHT serves two masters upstream: the current row/column
       * markers (which always carry a letter or digit) and the dead
       * border right of the grid (all spaces) -- the border is black */
      for (i = 0U; i < m_blen; ++i)
       {
         if (' ' != m_run[i]) break;
       }
      if (i == m_blen) attr = 0x00U;
    }
   __asm__ volatile ("sei");
   V_CTRL |= 0x01U;               /* address port 1: the mouse owns 0 */
   V_ADDR_L = (byte)(m_bx << 1);
   V_ADDR_M = 0xB0U + m_by;       /* $1B000 + row * 256 */
   V_ADDR_H = 0x11U;              /* bank 1, stride +1 */
   for (i = 0U; i < m_blen; ++i)
    {
      V_DATA1 = m_screencode((byte)m_run[i]);
      V_DATA1 = attr;
    }
   V_CTRL &= 0xFEU;               /* ADDRSEL back to 0, the IRQ's world */
   __asm__ volatile ("cli");
   m_blen = 0U;
 }

void platformInitializeScreen (void)
 {
   cx_mode(CX_MODE_TEXT, 0U);     /* the 80x60 default geometry */
   cx_clear(6U);
   cx_mouse_show(1U);             /* the pointer rides the text grid --
                                   * the kernel sizes its field to the
                                   * live mode-3 geometry */
   m_x = 0U;
   m_y = 0U;
   m_blen = 0U;
 }

void platformScreensize (byte* x, byte* y)
 {
   *x = 80U;
   *y = 60U;
 }

void platformGotoxy (byte x, byte y)
 {
   if ((x != m_x) || (y != m_y)) m_flush();
   m_x = x;
   m_y = y;
 }

void platformColors (byte pair)
 {
   if (pair != m_pair) m_flush();
   m_pair = pair;
 }

void platformPutch (byte ch)
 {
   if (0U == m_blen)
    {
      m_bx = m_x;
      m_by = m_y;
      m_bpair = m_pair;
    }
   m_run[m_blen] = (char)ch;
   ++m_blen;
   ++m_x;
   /* conio wraps at the right edge, and the UI paints whole screens on
    * that: one gotoxy(0,0), then a stream of characters */
   if (m_x >= 80U)
    {
      m_flush();
      m_x = 0U;
      if (m_y < 59U) ++m_y;
    }
 }

void platformPuts (char* s)
 {
   while ('\0' != *s)
    {
      platformPutch((byte)*s);
      ++s;
    }
 }

/* read-modify one attribute byte at the cursor cell: swap its nibbles
 * (reverse video) or write a saved value back. Stride 0, so the read
 * and the write land on the same byte. */
static byte m_curattr (byte restore, byte value)
 {
   byte a;
   __asm__ volatile ("sei");
   V_CTRL |= 0x01U;
   V_ADDR_L = (byte)((m_x << 1) + 1U);
   V_ADDR_M = 0xB0U + m_y;
   V_ADDR_H = 0x01U;              /* bank 1, stride 0 */
   a = V_DATA1;
   V_DATA1 = restore ? value : (byte)((a << 4) | (a >> 4));
   V_CTRL &= 0xFEU;
   __asm__ volatile ("cli");
   return a;
 }

/* CXRF mouse support: a click comes back from platformGetch as the
 * pseudo-command CXRF_CMD_CLICK with the clicked SCREEN CELL here --
 * ui.c owns the scroll state and column widths, so the mapping to a
 * sheet cell happens there. */
#define CXRF_CMD_CLICK 0xFEU
byte mouse_cx, mouse_cy;

byte platformGetch (void)
 {
   cx_event ev;
   byte saved, key;
   m_flush();                     /* everything pending shows first */
   /* the UI parks the cursor (its last gotoxy) where typing happens:
    * the EDIT LINE (row 1) while entering, the cell otherwise. Show a
    * reverse-video block only on the edit line -- the grid already
    * marks the current cell with the highlight band. */
   saved = 0U;
   if (1U == m_y) saved = m_curattr(0U, 0U);
   for (;;)
    {
      if (cx_poll(&ev))
       {
         if (CX_ET_KEY == ev.type)
          {
            key = ev.detail;
            break;
          }
         if (CX_ET_DOWN == ev.type)
          {
            mouse_cx = (byte)ev.x;    /* the kernel already shifts mode-3
                                       * mouse coords to CELLS (cx_cshift) */
            mouse_cy = (byte)ev.y;
            key = CXRF_CMD_CLICK;
            break;
          }
       }
      else
       {
         __asm__ volatile ("wai");   /* sleep to the next IRQ instead of
                                      * spinning -- kind to real silicon */
       }
    }
   if (1U == m_y) m_curattr(1U, saved);
   if (CX_K_DEL == key) return '\b';   /* PETSCII DEL -> backspace */
   /* PETSCII -> ASCII letters, so typing is mixed-case: unshifted keys
    * arrive as $41-$5A (PETSCII lowercase) and shifted as $C1-$DA */
   if ((key >= 0x41U) && (key <= 0x5AU)) return key + 32U;
   if ((key >= 0xC1U) && (key <= 0xDAU)) return key - 128U;
   return key;
 }

void platformCloseScreen (void)
 {
   m_flush();
 }

#include "machina_cxrf_files.h"
