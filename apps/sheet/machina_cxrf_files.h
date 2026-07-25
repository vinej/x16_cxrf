/* --- the file layer --------------------------------------------------
 * ui.c's save/load speak stdio (fopen/fputc/fgetc/...). llvm-mos's
 * stdio FILE machinery pushed the app past the $8000 ceiling, so these
 * are the same names over bare CBM channels instead: one file open at
 * a time (all X16Cell ever does), logical file 2 on device 8, ",s,w"
 * appended for a write so CMDR-DOS creates a SEQ file. EOF follows
 * stdio: the status EOF bit arms a flag and the NEXT read reports it,
 * so the last real byte is still delivered. ui.c's #include <stdio.h>
 * is replaced by these (see sheet.c).
 * -------------------------------------------------------------------- */
typedef struct SHEET_FILE FILE;   /* opaque: the one CBM channel */

static byte f_eof, f_eofnext, f_err, f_write;
static char f_name [40];

FILE* fopen (const char* name, const char* mode)
 {
   byte i = 0U;
   f_eof = 0U;
   f_eofnext = 0U;
   f_err = 0U;
   f_write = ('w' == mode[0]) || ('w' == mode[1]);
   while (('\0' != *name) && (i < 32U))
    {
      char c = *name;
      /* DOS parses PETSCII: ASCII lowercase is PETSCII graphics, so
       * fold the name to the $41-$5A letters DOS understands */
      if ((c >= 'a') && (c <= 'z')) c -= 32;
      f_name[i] = c;
      ++i;
      ++name;
    }
   if (f_write)
    {
      f_name[i] = ','; f_name[i + 1U] = 'S'; f_name[i + 2U] = ',';
      f_name[i + 3U] = 'W';
      i += 4U;
    }
   f_name[i] = '\0';
   cbm_k_setnam(f_name);
   cbm_k_setlfs(2U, 8U, 2U);
   if (0U != cbm_k_open())
    {
      cbm_k_close(2U);
      return (FILE*)0;
    }
   if (0U != (cbm_k_readst() & 0x02U))   /* device timeout: no drive */
    {
      cbm_k_close(2U);
      return (FILE*)0;
    }
   /* redirect ONCE for the file's whole life: a save streams thousands
    * of single characters, and a CHKOUT/CLRCHN pair around each tripled
    * the KERNAL traffic. Nothing prints to the screen while a file is
    * open (the UI only repaints after save/load return), so the
    * redirection can safely stand until fclose. */
   if (f_write) cbm_k_chkout(2U);
   else cbm_k_chkin(2U);
   return (FILE*)2;
 }

int fputc (int ch, FILE* f)
 {
   (void)f;
   cbm_k_bsout((byte)ch);
   return ch;
 }

int fputs (const char* s, FILE* f)
 {
   (void)f;
   while ('\0' != *s)
    {
      cbm_k_bsout((byte)*s);
      ++s;
    }
   return 0;
 }

int fgetc (FILE* f)
 {
   byte ch, st;
   (void)f;
   if (0U != f_eofnext)
    {
      f_eof = 1U;
      return -1;
    }
   ch = cbm_k_basin();
   st = cbm_k_readst();
   if (0U != (st & 0x40U)) f_eofnext = 1U;
   if (0U != (st & 0x82U)) f_err = 1U;
   return ch;
 }

int feof (FILE* f)
 {
   (void)f;
   return f_eof;
 }

int ferror (FILE* f)
 {
   (void)f;
   return f_err;
 }

int fclose (FILE* f)
 {
   (void)f;
   cbm_k_close(2U);
   cbm_k_clrch();
   return 0;
 }
