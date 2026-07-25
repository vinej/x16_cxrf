; ca65
; =====================================================================
; CXRF :: apps/word/word.asm -- CXRF Word: the X16 Edit host wrapper
; =====================================================================
; CXRF Word IS X16 Edit (Stefan Jakobsson, BSD-2-Clause -- LICENSE),
; vendored beside this file and hosted as a CXRF app. The editor was
; built for this: its entry points take the RAM bank range in X/Y (the
; CXRF app banks, 20-63), its custom IRQ handler CHAINS to the one it
; found and restores it at exit, its scancode hook and zero page and
; golden RAM are backed up at init and restored at shutdown, and its
; text screen is the same KERNAL 80x60 grid CXRF mode 3 programs.
;
; The wrapper is the whole port: enter mode 3, hand the editor the app
; banks, and when it returns (Ctrl+X), restore the desktop's mode and
; exit. The editor never touches the CXRF ABI, and CXRF's event system
; is never started -- the KERNAL GETIN/mouse the editor drives itself
; would fight it. Three vendored-source deviations, each marked CXRF:
; the zero page rides the app window ($60-$7F, was $22 upstream -- the
; printer-driver assert moves with it), and the help .incbins load
; beside the sources.
; =====================================================================

.include "sdk/include_ca65/cxrf.inc"

.import main_loadfile_entry

r1 = $04                        ; KERNAL r1: file name length (0 = none)

.segment "LOADADDR"
    .word $0801

.segment "EXEHDR"
    .word $080B                 ; 10 SYS 2061
    .word 10
    .byte $9E, "2061", $00
    .word $0000

    ldx #0                      ; the boot-smoke marker, via CHROUT
@mk:
    lda s_up,x
    beq @mkd
    jsr $FFD2
    inx
    bra @mk
@mkd:

    lda #3                      ; the KERNAL text screen under the editor:
    ldx #0                      ; CX_MODE_TEXT, the 80x60 default
    jsr cx_gfx_mode

    stz r1                      ; no file on the command line
    ldx #20                     ; the CXRF app banks: the editor's work
    ldy #63                     ; area in 20, the text buffer in 21-63
    jsr main_loadfile_entry     ; returns on Ctrl+X

    lda #0                      ; the desktop's mode BEFORE leaving, so
    ldx #2                      ; the shell reload never crosses a mode
    jsr cx_gfx_mode             ; change
    jmp cx_exit

s_up: .byte "WORD UP", $0D, 0
