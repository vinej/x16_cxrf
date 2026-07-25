/* =====================================================================
 * CXRF :: apps/sheet/sheet.c -- CXRF Sheet, the spreadsheet
 * =====================================================================
 * An adaptation of X16Cell by Thomas DiModica (BSD-3-Clause; the
 * upstream sources ride alongside unmodified -- see LICENSE) to a CXRF
 * app: the engine (8-digit BCD decimal floats, a shunting-yard formula
 * parser with SUM/AVERAGE/COUNT/MIN/MAX/ROUND/TRUNC/ABS and ranges,
 * banked cell store, 100 rows x 26 columns) is X16Cell's, verbatim;
 * the platform layer (machina_cxrf.c) speaks the CXRF C SDK -- text
 * mode 3, EV_KEY input, banks 20+ for the store.
 *
 * Keys (X16Cell's): arrows/WASD move, = starts a formula, " a label,
 * E edits, X clears, ] / [ widen/narrow the column, ! recalculates,
 * G goto, F file save / load, Q quits (back to the desktop).
 *
 * One translation unit: llvm-mos builds a single .c per app.
 * ===================================================================== */
#include <cbm.h>
#include "sdk/include_llvm/cxrf.h"
#include "csdk/cxsdk.h"

/* llvm-mos has no <strings.h>; shunting.c only compares function names,
 * which its tokenizer has already upcased or kept ASCII, so a tiny
 * case-folding compare here covers it */
static int strncasecmp (const char* a, const char* b, unsigned n)
 {
   unsigned char ca, cb;
   while (n--)
    {
      ca = (unsigned char)*a++;
      cb = (unsigned char)*b++;
      if (ca >= 'a' && ca <= 'z') ca -= 32U;
      if (cb >= 'a' && cb <= 'z') cb -= 32U;
      if (ca != cb) return (int)ca - (int)cb;
      if ('\0' == ca) return 0;
    }
   return 0;
 }

#include "machina_cxrf.c"
#include "floats.c"
#include "shunting.c"
#include "store.c"
#include "ui.c"

int main (void)
 {
   byte command;

   cx_print("SHEET UP");          /* the boot-smoke marker */
   cx_ev_init();

   initializeScreen();
   do
    {
      updateScreen();
      command = getNextCommand();
    }
   while (0 == interpretCommand(command));
   closeScreen();

   cx_mode(CX_MODE_BMPHIGH, 2U);  /* the desktop's mode BEFORE leaving */
   cx_exit();                     /* never returns */
   return 0;
 }
