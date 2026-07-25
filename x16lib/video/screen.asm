;ACME
; =====================================================================
; x16lib :: video/screen.asm -- screen mode, text output, cursor
; =====================================================================
; This file EMITS CODE. Source it exactly once (x16_code.asm does).
;
; ---------------------------------------------------------------------
; THE KERNAL REQUIRES ADDRSEL = 0.
;
; Several KERNAL screen routines write VERA_ADDR_L/M/H *before* they set
; ADDRSEL, taking it on faith that port 0 is already selected. The screen
; scroller is the clearest case (x16-rom-r49 kernal/drivers/x16/screen.s):
;
;       lda pnt : sta VERA_ADDR_L   ; destination -- ADDRSEL assumed 0
;       ...
;       lda #1  : sta VERA_CTRL     ; only now switch to port 1
;       lda sal : sta VERA_ADDR_L   ; source
;
; Call that with ADDRSEL = 1 and the destination lands in port 1, where
; the source promptly overwrites it. The screen corrupts.
;
; screen_set_char is worse still: it writes all three ADDR registers and
; then `sta VERA_DATA0` without ever touching VERA_CTRL. With ADDRSEL = 1
; the address goes to port 1 while the character goes out of port 0, at
; whatever stale address port 0 happened to hold.
;
; So every routine here that enters a KERNAL routine which touches VERA
; forces ADDRSEL = 0 first. If you call CHROUT / CINT yourself after
; touching port 1 -- and +vera_addr 1 and vera_copy both leave it
; selected -- either go through screen_chrout, or emit +vera_addrsel 0
; beforehand.
;
; Note also that the KERNAL leaves DCSEL = 0, so do not expect a DCSEL
; selection to survive a call into it.
; =====================================================================

; (zone: file scope in ca65)

; ---------------------------------------------------------------------
; screen_set_mode
;   in:  A = mode  ($00 80x60, $01 80x30, $02 40x60, $03 40x30,
;                   $04 40x15, $05 20x30, $06 20x15, $07 22x23,
;                   $08 64x50, $09 64x25, $0A 32x50, $0B 32x25,
;                   $80 320x240@256c + 40x30 text)
;   out: carry clear on success, set if the mode is unsupported
;
; KERNAL SCREEN_MODE takes carry clear to mean "set".
; ---------------------------------------------------------------------
screen_set_mode
    pha
    vera_addrsel 0
    pla
    clc
    jmp SCREEN_MODE

; The query/border/cursor/charset/puts helpers below are behind
; X16_USE_SCREEN_EXTRA: a program that just sets a mode and prints does
; not need them, so the core (set_mode/reset/cls/chrout/color/locate)
; can stand alone. X16_USE_SCREEN pulls them, for compat.
.ifdef X16_USE_SCREEN_EXTRA
; ---------------------------------------------------------------------
; screen_get_mode
;   out: A = current mode
; ---------------------------------------------------------------------
screen_get_mode
    vera_addrsel 0
    sec
    jmp SCREEN_MODE

; ---------------------------------------------------------------------
; screen_get_size -- the live text grid, after any screen_set_mode
;   out: X = columns, Y = rows
; ---------------------------------------------------------------------
screen_get_size
    jmp SCREEN
.endif

; ---------------------------------------------------------------------
; screen_reset -- restore the default text mode (KERNAL CINT)
; ---------------------------------------------------------------------
screen_reset
    vera_addrsel 0
    jmp CINT

; ---------------------------------------------------------------------
; screen_cls -- clear the text screen
; ---------------------------------------------------------------------
screen_cls
    vera_addrsel 0
    lda #PETSCII_CLS
    jmp CHROUT

; ---------------------------------------------------------------------
; screen_chrout -- CHROUT with the ADDRSEL precondition established
;   in:  A = character
; ---------------------------------------------------------------------
screen_chrout
    pha
    vera_addrsel 0
    pla
    jmp CHROUT

; ---------------------------------------------------------------------
; screen_color
;   in:  A = foreground (0-15), X = background (0-15)
;
; Sets the colour used by every subsequent CHROUT. Writes the KERNAL's
; editor colour byte directly -- there is no jump-table entry for this.
; Touches no VERA state.
; ---------------------------------------------------------------------
screen_color
    and #$0F
    sta X16_T0
    txa
    and #$0F
    asl
    asl
    asl
    asl                         ; background into the high nibble
    ora X16_T0
    sta KERNAL_COLOR
    rts

.ifdef X16_USE_SCREEN_EXTRA
; ---------------------------------------------------------------------
; screen_border
;   in:  A = colour (0-15)
;
; DC_BORDER is only visible when DCSEL = 0, so select that bank first.
; Does not enter the KERNAL.
; ---------------------------------------------------------------------
screen_border
    pha
    vera_dcsel 0
    pla
    sta VERA_DC_BORDER
    rts
.endif

; ---------------------------------------------------------------------
; screen_locate -- move the text cursor
;   in:  X = row, Y = column
; screen_get_cursor -- read it back
;   out: X = row, Y = column
;
; KERNAL PLOT takes carry clear to mean "set".
;
; No ADDRSEL guard here: PLOT only moves the cursor variables (it lands
; in screen_set_position, which just writes `pnt`) and never touches
; VERA. Adding one would cost a clobbered A for nothing.
; ---------------------------------------------------------------------
screen_locate
    clc
    jmp PLOT

.ifdef X16_USE_SCREEN_EXTRA
screen_get_cursor
    sec
    jmp PLOT

; ---------------------------------------------------------------------
; screen_charset
;   in:  A = charset (1 = ISO, 2 = PET upper/graphics,
;                     3 = PET upper/lower, ... 12 = Katakana)
; ---------------------------------------------------------------------
screen_charset
    pha
    vera_addrsel 0
    pla
    jmp SCREEN_SET_CHARSET

; ---------------------------------------------------------------------
; screen_puts -- print a NUL-terminated string
;   in:  A = address low, X = address high
;   Strings longer than 255 bytes are truncated at 255.
; ---------------------------------------------------------------------
screen_puts
    sta X16_TPTR0
    stx X16_TPTR0+1
    vera_addrsel 0
    ldy #0
@loop
    lda (X16_TPTR0),y
    beq @done
    jsr CHROUT
    iny
    bne @loop
@done
    rts
.endif

; (end zone)
