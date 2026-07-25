; ca65
; =====================================================================
; CXRF :: kernel/video/text.asm -- mode 3: KERNAL text (like BASIC)
; =====================================================================
; The fourth personality behind the graphics port, and the cheapest:
; the KERNAL's own text screen. 80x60 by default; cx_gfx_mode(3, X)
; picks any KERNAL screen_mode geometry ($00-$0B -- 80x30, 40x30,
; 20x15...), and ov3_init publishes the live grid in cx_minfo so
; cx_gfx_info, the bounds and the mouse field follow. It is a
; CHARACTER GRID, not a framebuffer, so the port's pixel calls are
; reinterpreted as CELL operations (cell coordinates, "colour" = a
; 16-colour text attribute). NOTE: the toolkit's metrics (menus,
; dialogs, panels) assume >= 64 columns / >= 25 rows -- on the
; narrower geometries apps draw their own UI with the calls below:
;
;   cx_clear   fill the screen with a colour (remembered as the paper)
;   cx_rect    fill a cell region with a colour (also sets the paper)
;   cx_frame   a box drawn with the PETSCII frame glyphs, in the colour
;              ink on the current paper
;   cx_hline   a run of horizontal-bar glyphs (a ruled line)
;   cx_vline   a column of vertical-bar glyphs
;   cx_line    horizontal or vertical only -- routed to the two above;
;              a diagonal has no grid meaning and refuses (carry)
;   cx_say     print a string at (col, row) -- routed here through the
;              port's 14th "text" entry (cxov_text); the cx_ink
;              attribute (white until an app sets one)
;
; pset/read/pattern/blit have no grid meaning and refuse (carry).
;
; The charset is PETSCII upper/lower -- the only set that has BOTH true
; mixed-case text and the box-drawing glyphs (ISO has neither box nor
; corner glyphs; they render as accented letters). Apps still hand
; cx_say plain ASCII: the printer maps a-z/A-Z to their PETSCII codes,
; so the case on screen is the case in the string.
;
; UNLIKE modes 1-2, this whole engine runs IN THE OVERLAY -- the port
; region is low RAM, always mapped, so the KERNAL console (resident
; video/screen.asm) can be called without a bank switch. That matters:
; the KERNAL screen routines do not preserve RAM_BANK, so running them
; from a kernel bank would corrupt the bank the code sits in (a crash to
; the monitor the first attempt earned). KERNAL text also assumes
; ADDRSEL=0 across sub-calls while the event IRQ touches VERA, so every
; op masks interrupts for its brief duration.
; =====================================================================

.ifndef CX_NO_OVERLAY

; the PETSCII box-drawing glyphs (upper/lower charset keeps them all)
T_TL = $B0                      ; 176  top-left corner
T_TR = $AE                      ; 174  top-right corner
T_BL = $AD                      ; 173  bottom-left corner
T_BR = $BD                      ; 189  bottom-right corner
T_HB = $C0                      ; 192  horizontal bar
T_VB = $DD                      ; 221  vertical bar

.segment "OV3CODE"

ov3_vector                      ; the 14 port entries, in slot order;
    jmp ov3_init                ; the 14th, text, is what cx_say reaches
    jmp ov3_clear
    jmp ov3_refuse              ; pset -- a cell is char+attr, not a pixel
    jmp ov3_refuse              ; read
    jmp ov3_hline
    jmp ov3_vline
    jmp ov3_rect
    jmp ov3_frame
    jmp ov3_line                ; line -- horizontal/vertical only
    jmp ov3_refuse              ; pattern set
    jmp ov3_refuse              ; pattern rect
    jmp ov3_refuse              ; blit
    jmp ov3_refuse              ; masked blit
    jmp ov3_say                 ; text: print a string at a cell
    jmp ov3_measure             ; measure: one cell per character
    jmp ov3_rsave               ; rsave/rrest: text-cell rows <-> a bank
    jmp ov3_rrest
    .byte 1                     ; cxov_ink -- cx_say's ink attribute
                                ; (0-15); every entry resets it to white
    ; the UI metrics, in CELLS (barh rowh barx airx barty bandpad
    ; boxwpad itemx itemdy) -- the menu laid out on the text grid
    .byte  1,  1,  1,  2,  0,  1,  2,  1,  0
    ; dialog metrics: dgw(word) dgh dgbw dgbh dgbsp dgpad dgfldy
    .word 44
    .byte 14, 10,  3, 12,  1,  4

.assert ov3_vector = CX_OVL, error, "OV3CODE must start at CX_OVL"

ov3_refuse
    sec
    rts

; ov3_init -- the KERNAL 80x60 text mode. CINT (screen_reset) does the
; FULL reinit -- VERA layers, the charset, the editor -- which
; screen_set_mode alone did not over CXRF's bitmap display (the text
; layer stayed dark). Then the upper/lower PETSCII charset: mixed case
; AND the box glyphs (ISO has no box glyphs at all).
ov3_init
    php
    sei
    jsr t_reset                 ; CINT: default 80x60 text, layers and all
    lda #$0E                    ; the CHR$(14) control code: the editor
    jsr t_chrout                ; leaves ISO (the X16 default) for PETSCII
                                ; upper/lower -- flag AND charset, the
                                ; exact switch BASIC uses
    lda cx_tgeo                 ; a geometry asked for (cx_gfx_mode(3, X))?
    beq @sized                  ; 0 = the CINT default, 80x60
    clc                         ; carry clear = SET the mode; an unknown
    jsr t_smode                 ; code returns carry set having changed
@sized                          ; nothing, so the CINT 80x60 stands -- the
                                ; same "native depth" rule as the bitmaps
    jsr SCREEN                  ; the LIVE grid (X = cols, Y = rows) into
    stx cx_minfo+24             ; the mode-3 minfo row, so cx_gfx_info,
    stz cx_minfo+25             ; the bounds and the mouse field all tell
    sty cx_minfo+26             ; the truth (cells fit a byte: max 80x60)
    stz cx_minfo+27
    jsr cx_ov_bounds            ; the bounds were copied BEFORE this init
                                ; ran (cx_do_gfx_mode's order) -- refresh
    lda #6                      ; CINT leaves white-on-blue: that is the
    sta t_bg                    ; paper until a clear/rect says otherwise
    plp
    clc
    rts

; t_fill -- A = colour: white ink on that paper, for the space fills
; (the paper is what shows). Remembers the paper for later ink drawing.
t_fill
    cmp #0                      ; th_paper is index 0, which is WHITE in the
    bne @op                     ; mode-0 palette but BLACK as a raw KERNAL
    lda #6                      ; colour -- so 0 means "the dialog paper",
@op                             ; opaque blue, the same substitution the
    sta t_bg                    ; mode-2 tile port makes (t3t_setfill). Keeps
    tax                         ; the widget background matching the dialog,
    lda #1                      ; not a black hole on the blue screen.
    jmp t_color

; t_ink -- A = colour: that ink on the current paper, for glyph drawing
t_ink
    ldx t_bg
    jmp t_color

; t_run -- print t_cnt copies of t_chr at the cursor; t_cnt = 0 prints none
t_run
    lda t_cnt
    beq @done
@go
    lda t_chr
    jsr t_chrout
    dec t_cnt
    bne @go
@done
    rts

; ov3_clear -- A = colour
ov3_clear
    php
    sei
    jsr t_fill
    jsr t_cls
    plp
    clc
    rts

; ov3_hline -- P0 = col, P2 = row, P4 = len, A = colour: a ruled line
ov3_hline
    php
    sei
    jsr t_ink
    ldx X16_P2                  ; row
    ldy X16_P0                  ; col
    jsr t_locate
    lda X16_P4                  ; len
    sta t_cnt
    lda #T_HB
    sta t_chr
    jsr t_run
    plp
    clc
    rts

; ov3_vline -- P0 = col, P2 = row, P4 = len, A = colour
ov3_vline
    php
    sei
    jsr t_ink
    lda #T_VB
    sta t_chr
    jsr t_col
    plp
    clc
    rts

; t_col -- a column of t_chr: P0 = col, P2 = row, P4 = len
t_col
    lda X16_P4
    beq @done
    sta t_h
    lda X16_P2
    sta t_row
@row
    ldx t_row
    ldy X16_P0
    jsr t_locate
    lda t_chr
    jsr t_chrout
    inc t_row
    dec t_h
    bne @row
@done
    rts

; ov3_rect -- P0 = col, P2 = row, P4 = w, P6 = h, A = colour: a filled
; panel of coloured cells (spaces); the colour becomes the paper
ov3_rect
    php
    sei
    jsr t_fill
    lda X16_P6                  ; h rows
    beq @done
    sta t_h
    lda X16_P2
    sta t_row
@row
    ldx t_row
    ldy X16_P0
    jsr t_locate
    lda X16_P4                  ; w spaces
    sta t_cnt
    lda #' '
    sta t_chr
    jsr t_run
    inc t_row
    dec t_h
    bne @row
@done
    plp
    clc
    rts

; ov3_frame -- P0 = col, P2 = row, P4 = w, P6 = h, A = colour: a box in
; the PETSCII frame glyphs. Degenerate sizes fall back honestly: h = 1
; is a ruled line, w = 1 a bar column.
ov3_frame
    php
    sei
    jsr t_ink

    lda X16_P4                  ; w < 2: a single column of bars
    cmp #2
    bcc @thin_w
    lda X16_P6                  ; h < 2: a single ruled row
    cmp #2
    bcc @thin_h

    ldx X16_P2                  ; the top edge: corner, bars, corner
    ldy X16_P0
    jsr t_locate
    lda #T_TL
    jsr t_chrout
    jsr t_bars                  ; w - 2 horizontal bars
    lda #T_TR
    jsr t_chrout

    lda X16_P2                  ; the bottom edge: row + h - 1
    clc
    adc X16_P6
    sec
    sbc #1
    tax
    ldy X16_P0
    jsr t_locate
    lda #T_BL
    jsr t_chrout
    jsr t_bars
    lda #T_BR
    jsr t_chrout

    lda X16_P6                  ; the sides: rows row+1 .. row+h-2
    sec
    sbc #2
    beq @sides_done
    sta t_h
    lda X16_P2
    inc a
    sta t_row
@side
    ldx t_row
    ldy X16_P0
    jsr t_locate
    lda #T_VB
    jsr t_chrout
    ldx t_row
    lda X16_P0                  ; col + w - 1
    clc
    adc X16_P4
    sec
    sbc #1
    tay
    jsr t_locate
    lda #T_VB
    jsr t_chrout
    inc t_row
    dec t_h
    bne @side
@sides_done
    plp
    clc
    rts

@thin_w                         ; w <= 1: a bar column, h tall
    lda X16_P6
    sta X16_P4
    lda #T_VB
    sta t_chr
    jsr t_col
    plp
    clc
    rts

@thin_h                         ; h <= 1 (w >= 2): one ruled row
    ldx X16_P2
    ldy X16_P0
    jsr t_locate
    lda X16_P4
    sta t_cnt
    lda #T_HB
    sta t_chr
    jsr t_run
    plp
    clc
    rts

; t_bars -- w - 2 horizontal bars at the cursor (w >= 2 guaranteed)
t_bars
    lda X16_P4
    sec
    sbc #2
    sta t_cnt
    lda #T_HB
    sta t_chr
    jmp t_run

; ov3_line -- P0 = x0, P2 = y0, P4 = x1, P6 = y1 (cells), A = colour.
; Horizontal or vertical only: sorted into a bar run; anything diagonal
; refuses with carry, the module policy for calls a grid cannot honour.
ov3_line
    php
    sei
    pha
    lda X16_P2
    cmp X16_P6
    beq @horiz
    lda X16_P0
    cmp X16_P4
    beq @vert
    pla
    plp
    sec
    rts

@horiz                          ; one row: col = min(x0,x1), len = |dx|+1
    lda X16_P0
    cmp X16_P4
    bcc @h_ord
    lda X16_P4                  ; swap so P0 is the left end
    ldx X16_P0
    sta X16_P0
    stx X16_P4
@h_ord
    lda X16_P4
    sec
    sbc X16_P0
    inc a
    sta X16_P4                  ; hline's len
    pla
    jsr t_ink
    ldx X16_P2
    ldy X16_P0
    jsr t_locate
    lda X16_P4
    sta t_cnt
    lda #T_HB
    sta t_chr
    jsr t_run
    plp
    clc
    rts

@vert                           ; one column: row = min(y0,y1)
    lda X16_P2
    cmp X16_P6
    bcc @v_ord
    lda X16_P6                  ; swap so P2 is the top end
    ldx X16_P2
    sta X16_P2
    stx X16_P6
@v_ord
    lda X16_P6
    sec
    sbc X16_P2
    inc a
    sta X16_P4                  ; t_col's len
    pla
    jsr t_ink
    lda #T_VB
    sta t_chr
    jsr t_col
    plp
    clc
    rts

; ov3_say -- A/X = string, P0 = col, P2 = row: print at the cell, white
; ink on the current paper. The string is ASCII; the upper/lower charset
; wants PETSCII, so letters are mapped ('a'-'z' -> $41, 'A'-'Z' -> $C1)
; and the case on screen matches the string.
ov3_say
    php
    sei
    sta t_sl                    ; park the string FIRST -- and not in the
    stx t_sh                    ; T block: screen_color scribbles X16_T0
                                ; composing its attribute nibble, which is
                                ; exactly where TPTR0 lives
    lda cxov_ink                ; the ink cx_ink set (white until it does)
    jsr t_ink
    ldx X16_P2                  ; row
    ldy X16_P0                  ; col
    jsr t_locate
    lda t_sl                    ; NOW the zp walker screen_puts used: only
    sta X16_TPTR0               ; screen_chrout runs from here on, and the
    lda t_sh                    ; KERNAL does not know the library's zp
    sta X16_TPTR0+1
    ldy #0
@ch
    lda (X16_TPTR0),y
    beq @done
    cmp #'_'                    ; ASCII underscore is PETSCII's left
    bne @nu                     ; arrow; the underline glyph is $A4
    lda #$A4
    bra @out
@nu
    cmp #'a'
    bcc @upper
    cmp #'z'+1
    bcs @out
    sec                         ; ASCII a-z -> PETSCII $41-$5A
    sbc #$20
    bra @out
@upper
    cmp #'A'
    bcc @out
    cmp #'Z'+1
    bcs @out
    ora #$80                    ; ASCII A-Z -> PETSCII $C1-$DA
@out
    phy
    jsr t_chrout
    ply
    iny
    bne @ch
@done
    tya                         ; the pen: col + characters printed
    clc                         ; (cols are 0-79, no high byte to carry)
    adc X16_P0
    sta X16_P0
    plp
    clc
    rts

; measure -- A/X = string -> P0/P1 = width in cells (its length)
ov3_measure
    sta X16_TPTR0
    stx X16_TPTR0+1
    ldy #0
@len
    lda (X16_TPTR0),y
    beq @done
    iny
    bne @len
@done
    sty X16_P0
    stz X16_P1
    clc
    rts

; ov3_rsave / ov3_rrest -- the toolkit's save-under, in text cells.
; The port contract: P0/P1 = first row, P2 = row count. A "row" is a
; full 80-cell text line = 160 bytes; the KERNAL's default screen (CINT,
; which ov3_init runs) puts the map at VRAM $1B000, 128-cell stride (256
; bytes a line). VERA port 1 does the streaming so port 0 -- the
; mouse's -- is undisturbed; interrupts are masked so nothing flips
; ADDRSEL mid-copy. The store is bank 14 (the dialog save-under bank);
; one bank holds 51 lines and a dropdown or panel is at most that, so no
; bank wrap. NOT bank 6: that is the CXF glyph cache, and although text
; mode never reads it, the mode-0 desktop returned to on exit does --
; stomping it there corrupted the desktop font after a TUI dialog.
T3_MAPM = $B0                   ; $1B000 middle byte; low = 0, high = $01
T3_SBANK = 14                   ; the save store (dialog save-under bank)
ov3_rsave
    ldx #0                      ; VRAM -> RAM
    bra ov3_sr
ov3_rrest
    ldx #1                      ; RAM -> VRAM
ov3_sr
    lda X16_P2
    bne @rows
    clc
    rts
@rows
    php
    sei
    stx t_dir
    lda RAM_BANK                ; the caller's bank comes back at the end --
    sta t_obank                 ; the menu code that called us runs banked
    lda #T3_SBANK
    sta RAM_BANK                ; the save store
    stz X16_T4                  ; the RAM walker = bank window $A000
    lda #$A0
    sta X16_T5
    lda #VERA_CTRL_ADDRSEL      ; steer ADDR writes at port 1
    tsb VERA_CTRL
    lda cx_minfo+24             ; the LIVE grid: cols x 2 bytes a row
    asl                         ; (<= 160; the map stride stays 256 in
    sta t_len                   ; every geometry, so only the byte count
                                ; per line follows the column width)
    lda X16_P0                  ; the running middle byte = $B0 + row
    clc
    adc #T3_MAPM
    sta t_vm
    ldx X16_P2                  ; row count
@row
    stz VERA_ADDR_L
    lda t_vm
    sta VERA_ADDR_M
    lda #($01 | (VERA_INC_1 << 4))
    sta VERA_ADDR_H
    ldy t_len
    lda t_dir
    bne @rest
@save
    lda VERA_DATA1
    sta (X16_T4)
    inc X16_T4
    bne @s2
    inc X16_T5
@s2
    dey
    bne @save
    bra @next
@rest
    lda (X16_T4)
    sta VERA_DATA1
    inc X16_T4
    bne @r2
    inc X16_T5
@r2
    dey
    bne @rest
@next
    inc t_vm                    ; the next line is 256 bytes on = M + 1
    dex
    bne @row
    lda #VERA_CTRL_ADDRSEL      ; ADDRSEL back to 0, the mouse IRQ's world
    trb VERA_CTRL
    lda t_obank                 ; the caller's bank back
    sta RAM_BANK
    plp
    clc
    rts

t_cnt .byte 0
t_chr .byte 0
t_h   .byte 0
t_row .byte 0
t_bg  .byte 0
t_sl  .byte 0
t_sh  .byte 0
t_dir   .byte 0
t_vm    .byte 0
t_obank .byte 0
t_len   .byte 0

t_reset
    vera_addrsel 0
    jmp CINT

t_smode
    pha                         ; vera_addrsel eats A (lda #1 / trb) --
    vera_addrsel 0              ; the mode code must survive it, and the
    pla                         ; caller's clc does (trb touches Z only)
    jmp SCREEN_MODE

t_cls
    vera_addrsel 0
    lda #PETSCII_CLS
    jmp CHROUT

t_chrout
    pha
    vera_addrsel 0
    pla
    jmp CHROUT

t_color
    and #$0F
    sta X16_T0
    txa
    and #$0F
    asl
    asl
    asl
    asl
    ora X16_T0
    sta KERNAL_COLOR
    rts

t_locate
    clc
    jmp PLOT

.segment "CODE"

.endif
