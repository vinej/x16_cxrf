; ca65
; =====================================================================
; CXRF :: kernel/resident/banks.inc -- the bank ledger, as constants
; =====================================================================
; Values only, no bytes: included by the kernel, both boot stubs and
; the test runner alike. docs/memory-map.md is the prose ledger; this
; file is the one the assembler enforces. Change them together.

; The kernel build word. Bumped whenever any shipped kernel file
; changes shape (each restructure phase, each release). Stage-0
; compares it across CXKERNEL.PRG ($815C), CXBANKS.BIN (2:$A040) and
; CXBANKS2.BIN (16..19:$A000), so a hand-copied card carrying
; yesterday's file refuses loudly instead of crashing strangely.
CX_KBUILD = $0603

; RAM banks 16-19: the second banked-code file, CXBANKS2.BIN, one
; theme per bank. Empty banks hold their signature and an anchor until
; the restructure phase that fills them lands.
CX_WG_BANK   = 16               ; widgets (code + state)
CX_GFXX_BANK = 17               ; base shapes / tiles machinery / dirty rects
CX_FS_BANK   = 18               ; dir / dos / loaders + system cold half + audio + sprites
CX_AUD_BANK  = 18               ; PSG + YM audio, sprites (share the fs bank)
CX_SHPX_BANK = 19               ; the extra shapes (polygon/rrect/arc/pie/bezier + math)

; The first bank an app may use; cx_bload refuses anything below it.
; (Was 16 before CXBANKS2 claimed 16-19 -- a pre-1.0 contract break,
; noted in the README.)
CX_APP_BANK_FLOOR = 20
