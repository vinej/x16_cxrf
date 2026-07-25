/* CXRF :: test/geosmoke/filesmoke.c -- exercise the CBM-channel file
 * shim CXRF Sheet uses (machina_cxrf.c): write a SEQ file, read it
 * back, compare. Prints FILESMOKE OK / FILESMOKE FAIL <step>. */
#include <cbm.h>
#include "sdk/include_llvm/cxrf.h"
#include "csdk/cxsdk.h"

typedef unsigned char byte;
typedef unsigned short word;

#include "apps/sheet/machina_cxrf_files.h"

static const char* msg = "HELLO SHEET 123";

int main (void)
 {
   FILE* f;
   int ch;
   byte i;

   cx_print("FILESMOKE UP");

   f = fopen("SHEETTEST", "wb");
   if (0 == f) { cx_print("FILESMOKE FAIL OPENW"); cx_exit(); }
   fputs(msg, f);
   fputc('\n', f);
   fclose(f);

   f = fopen("SHEETTEST", "rb");
   if (0 == f) { cx_print("FILESMOKE FAIL OPENR"); cx_exit(); }
   for (i = 0U; msg[i] != '\0'; ++i)
    {
      ch = fgetc(f);
      if (ch != msg[i]) { cx_print("FILESMOKE FAIL DATA"); cx_exit(); }
    }
   ch = fgetc(f);                 /* the newline */
   if (ch != '\n') { cx_print("FILESMOKE FAIL NL"); cx_exit(); }
   fgetc(f);                      /* past the end: arms EOF */
   if (!feof(f)) { cx_print("FILESMOKE FAIL EOF"); cx_exit(); }
   fclose(f);

   cx_print("FILESMOKE OK");
   cx_exit();
   return 0;
 }
