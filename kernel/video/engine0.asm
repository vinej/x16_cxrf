; ca65
; =====================================================================
; CXRF :: kernel/video/engine0.asm -- mode 0: 640x480 @ 2bpp (the GUI)
; =====================================================================
; The first engine image behind the graphics port (ovl.inc). The image
; is the fixed 13-entry vector, then x16lib's bitmap2h module, compiled
; to RUN at the overlay region but STORED in bank 3 (kernel.cfg's
; OV0CODE segment). cx_ov_boot copies it in at kernel init, before
; anything can draw; a later cx_gfx_mode(0) does the same copy.
;
; bitmap2h.asm is .included HERE, inside OV0CODE, so the X16_USE_BITMAP2H
; gate stays OFF in kernel.asm -- x16_code.asm must not also place the
; module in the resident image. Its helpers (vera_fill, fx_fill) stay
; resident via the X16_USE_VERA / X16_USE_VERAFX_FILL gates.
;
; Internal kernel callers (font, widgets, menus, dialogs) keep naming
; gfx2h_* directly: those labels ARE overlay run addresses now, correct
; whenever mode 0's image is resident -- and the toolkit is mode-0-only
; by contract. Only the ABI slots go through the vector, so an app
; always reaches the CURRENT engine.
; =====================================================================

CX_MODE_TEXT = 3                ; the 80x60 text personality -- named
                                ; here (not in the overlay block) because
                                ; cx_g_font_draw's dispatch needs it in
                                ; the flat runner build too

.ifndef CX_NO_OVERLAY

; --- the port manager (CODE, resident) --------------------------------
; cx_ov_load copies an engine image from its bank into the port region:
; interrupts masked (nothing must draw mid-copy), the caller's bank
; restored. Engine n lives in bank CX_OV0_BANK + n.
CX_NMODES   = 4                 ; screen MODES 0-3 (mode 0 = the 640x480 umbrella:
                                ; bpp 2 std-VERA desktop, 4/8 VERA_2)

.import __OV2CODE_LOAD__        ; modes 2 and 3 share a bank with the
.import __OV3CODE_LOAD__        ; shapes / text machinery; ld65 says where
.import __OV3TCODE_LOAD__       ; each image landed. OV4L / OV2L are the
.import __OV4LCODE_LOAD__       ; 320x240 4bpp / 2bpp images, stacked after
.import __OV2LCODE_LOAD__       ; OV0 in bank 3 (engine indices 5 and 6);
.import __OV4HCODE_LOAD__       ; OV4H / OV8H are the 640x480 VERA_2 images,
.import __OV8HCODE_LOAD__       ; stacked after OV1 in bank 4 (indices 7, 8)

cx_ov_boot                      ; boot: engine 0 in, mode noted
    stz cx_vmode
    stz cx_veng
    jsr cx_ov_bounds
    lda #0
    ; falls into cx_ov_load
cx_ov_load                      ; A = the ENGINE-IMAGE INDEX to pull in
    php
    sei
    sta cx_veng                 ; remember which image rides the port now
    stz VERA2_CTRL              ; leave any VERA_2 (mode 4) plane OFF; an
                                ; h-engine's init turns it back on, so every
                                ; non-mode-4 image restores the VERA display
    tay
    lda RAM_BANK
    pha
    lda cx_mbank,y
    sta RAM_BANK
    lda cx_msrc_lo,y            ; src walker in T0/T1, dst in T2/T3
    sta X16_T0
    lda cx_msrc_hi,y
    sta X16_T1
    lda #<CX_OVL
    sta X16_T2
    lda #>CX_OVL
    sta X16_T3
    ldx #>CX_OVL_SIZE           ; the whole pages first...
@page
    ldy #0
@byte
    lda (X16_T0),y
    sta (X16_T2),y
    iny
    bne @byte
    inc X16_T1
    inc X16_T3
    dex
    bne @page
.if <CX_OVL_SIZE <> 0
    ldy #0                      ; ...then the partial tail -- never a
@tail                           ; byte past OVL: $9F00 is I/O
    lda (X16_T0),y
    sta (X16_T2),y
    iny
    cpy #<CX_OVL_SIZE
    bne @tail
.endif
    pla
    sta RAM_BANK
    plp
    rts

; --- cx_gfx_init (slot 2) -- ALWAYS lands on the desktop (OV0) --------
; The shell (and the panic path, and every 0.x app) calls this to own
; the GUI screen. If another IMAGE rides the port, boot OV0 back first:
; whatever happens in a mode, cx_exit -> shell -> here restores the
; desktop. Test cx_veng, NOT cx_vmode -- the 640x480 umbrella's VERA_2
; depths (OV4H/OV8H) are cx_vmode 0 too, but their engine index is not 0;
; without booting OV0 back, cx_ov_load never turns VERA_2 off (black screen).
cx_do_gfx_init
    lda cx_veng
    beq @go
    jsr cx_ov_boot
@go
    jmp cxov_init

; --- cx_ink (slot 89) -- A = the text ink, into the CURRENT image -----
; The byte lives in the engine image (cxov_ink), so a mode switch copies
; the mode's default back in: an ink set here never leaks into a mode
; where the same number is a different colour space.
cx_do_ink
    sta cxov_ink                ; a void slot: no carry contract to set
    rts

; --- cx_gfx_mode (slot 76) -- A = mode, X = bpp; carry set if unknown -
; The bpp picks WHICH engine image serves a mode that has more than one
; depth: mode 1 (320x240) is 8/4/2 bpp. X = 0 (or any depth the mode does
; not offer) means the mode's native depth, so an old caller that sets
; only A still lands the same image it always did -- the slot is unchanged.
cx_do_gfx_mode
    pha                         ; the mode, for cx_vmode
    jsr cx_eng_index            ; A = mode, X = bpp -> A = engine index
    bcs @bad
    cmp #2                      ; mode 2 (tiles): the depth is per-layer, so
    bne @nt                     ; there is no single "mode bpp" -- instead X
    jsr cx_tbpp_set             ; sets the tile DEFAULT depth (cx_tbpp) that
@nt                             ; cx_tile_setup adopts when its own bpp is 0
    cmp cx_veng
    beq @same                   ; that image already rides the port
    jsr cx_ov_load              ; A = engine index (sets cx_veng)
    pla
    sta cx_vmode
    jsr cx_ov_bounds            ; canvas w/h from the engine's cx_minfo row
    jsr cxov_init               ; the fresh engine programs VERA
    clc
    rts
@same
    pla
    clc
    rts
@bad
    pla
    sec
    rts

; cx_eng_index -- A = mode, X = bpp -> A = engine-image index, carry set
; if the mode is unknown. Mode 0 (640x480) is an UMBRELLA: 2 bpp (or native)
; is OV0, the std-VERA desktop; 4 bpp is OV4H and 8 bpp is OV8H, both on the
; VERA_2 second plane. Mode 1 (320x240) has three (8 bpp = 1, 4 bpp = 5,
; 2 bpp = 6); modes 2/3 have one image each (index == mode).
cx_eng_index
    cmp #1
    beq @m1
    cmp #0
    beq @m0
    cmp #CX_NMODES
    bcs @bad
    clc
    rts                         ; modes 2/3: image index == mode
@m0                             ; mode 0: the 640x480 umbrella
    cpx #4
    beq @m0_4
    cpx #8
    beq @m0_8
    lda #0                      ; 2 bpp (default/native) -> OV0, std-VERA desktop
    clc
    rts
@m0_4
    lda #7                      ; 4 bpp -> OV4H (VERA_2)
    clc
    rts
@m0_8
    lda #8                      ; 8 bpp -> OV8H (VERA_2)
    clc
    rts
@m1
    cpx #4
    beq @m1_4
    cpx #2
    beq @m1_2
    lda #1                      ; 8 bpp (native), or any other X
    clc
    rts
@m1_4
    lda #5
    clc
    rts
@m1_2
    lda #6
    clc
    rts
@bad
    sec
    rts

; cx_tbpp_set -- X = a tile depth (2/4/8) -> cx_tbpp; A preserved, any
; other X left alone (so cx_gfx_mode(2, 0) keeps the current default)
cx_tbpp_set
    cpx #2
    beq @s
    cpx #4
    beq @s
    cpx #8
    bne @done
@s
    stx cx_tbpp
@done
    rts

; The KERNAL's boot LOAD wraps exactly four banks (32KB) before it
; stops, so every engine image rides banks 2-5; modes 2 and 3 share
; bank 5 with the shapes/tile code (ld65 says where each landed).
; index 0-3 are the modes; index 4 (CX_OV_TILETEXT) is OV3T, the tile-
; text dialog port -- not a mode (cx_vmode stays 2), swapped into the port
; by cx_tile_text with cx_ov_load, never by cx_do_gfx_mode.
;               0     1     2                3                4                 5                 6                 7                 8
cx_mbank   .byte 3,    4,    5,               5,               5,                3,                3,                4,                4
cx_msrc_lo .byte <$A000, <$A000, <__OV2CODE_LOAD__, <__OV3CODE_LOAD__, <__OV3TCODE_LOAD__, <__OV4LCODE_LOAD__, <__OV2LCODE_LOAD__, <__OV4HCODE_LOAD__, <__OV8HCODE_LOAD__
cx_msrc_hi .byte >$A000, >$A000, >__OV2CODE_LOAD__, >__OV3CODE_LOAD__, >__OV3TCODE_LOAD__, >__OV4LCODE_LOAD__, >__OV2LCODE_LOAD__, >__OV4HCODE_LOAD__, >__OV8HCODE_LOAD__

; --- the engine image (OV0CODE: run = OVL, load = bank 3) ------------
.segment "OV0CODE"

ov0_vector                      ; the port's entry vector, slot order
    jmp gfx2h_init
    jmp gfx2h_clear
    jmp gfx2h_pset
    jmp gfx2h_read
    jmp gfx2h_hline
    jmp gfx2h_vline
    jmp gfx2h_rect
    jmp gfx2h_frame
    jmp gfx2h_line
    jmp gfx2h_pattern_set
    jmp gfx2h_pattern_rect
    jmp gfx2h_blit
    jmp gfx2h_blitm
    jmp font_draw               ; text: the CXF proportional font
    jmp font_measure            ; measure: CXF pixel widths
    jmp ov0_rsave               ; rsave/rrest: full pixel rows <-> the
    jmp ov0_rrest               ; VRAM strip, the toolkit's mode-0 save-under
    .byte 1                     ; cxov_ink -- unused in mode 0 (the theme
                                ; owns the GUI's text ink), carried so the
                                ; port layout is the same in every image
    ; the UI metrics, in pixels (barh rowh barx airx barty bandpad
    ; boxwpad itemx itemdy) -- the toolkit's current mode-0 constants
    .byte 12, 10,  8, 16,  2,  4,  8,  4,  1
    ; dialog metrics: dgw(word) dgh dgbw dgbh dgbsp dgpad dgfldy
    .word 400
    .byte 96, 72, 16, 80, 12, 34

.assert ov0_vector = CX_OVL, error, "OV0CODE must start at CX_OVL -- kernel.cfg and ovl.inc disagree"

; --- the GUI save-under: full framebuffer rows <-> banked RAM --------
; P0/P1 = first row, P2 = row count -- the vrows contract. Banks 14-15,
; the same the dialogs use: a menu and a dialog are never both open
; (a pick closes the menu before the app can raise one), and desk
; accessories -- the other 14-15 tenant -- carry no menu bar, so nothing
; else is mid-save here. The mode's bank is fixed in the image, so the
; port entry needs no bank argument.
MN_SBANK = 14
ov0_rsave
    lda #MN_SBANK
    jmp vrows_save
ov0_rrest
    lda #MN_SBANK
    jmp vrows_restore

.include "gfx/bitmap2h.asm"

.segment "CODE"

.else
; the runner links flat: the engine is already in CODE via x16_code's
; X16_USE_BITMAP2H gate, the port names alias it (ovl.inc), there is
; nothing to copy, and mode 0 is the only mode.
cx_ov_boot
    rts
cx_do_gfx_init
    jmp gfx2h_init
cx_do_gfx_mode
    cmp #1
    bcs @bad
    clc
    rts
@bad
    sec
    rts
cxov_ink .byte 1                ; flat build: the ink byte is just a byte
cx_flatmet .byte 12, 10, 8, 16, 2, 4, 8, 4, 1   ; the mode-0 UI metrics
    .word 400                                    ; dgw
    .byte 96, 72, 16, 80, 12, 34                 ; dgh dgbw dgbh dgbsp dgpad dgfldy
cx_do_ink
    sta cxov_ink
    clc
    rts
.endif

; --- cx_gfx_info (slot 77) -- what canvas is this? --------------------
; A = the mode; P0/P1 = width, P2/P3 = height, P4 = bpp, P5/P6 = bytes
; per row. The one call that lets client code (cx_pic_*, a screenshot
; tool, a future mode) adapt to any engine without knowing its name.
cx_do_gfx_info
    lda cx_veng                 ; index by IMAGE, so the row carries the
    asl                         ; live bpp/stride (8-byte rows in the table)
    asl
    asl
    tax
    ldy #0
@copy
    lda cx_minfo,x
    sta X16_P0,y
    inx
    iny
    cpy #7
    bne @copy
    lda cx_vmode                ; but report the MODE the app selected
    rts

; cx_ov_bounds -- the current canvas w/h out of the image table, into
; the fixed words the shapes module (and anyone) reads
cx_ov_bounds
    lda cx_veng
    asl
    asl
    asl
    tax
    ldy #0
@cp
    lda cx_minfo,x
    sta cx_cur_w,y
    inx
    iny
    cpy #4
    bne @cp
    rts

; --- the GUI-only guard ----------------------------------------------
; The font engine and the toolkit assume the mode-0 framebuffer: they
; blit 2bpp glyphs and rows into $00000. Outside mode 0 that memory is
; another mode's picture (or, in tiles, not a framebuffer at all), so
; those calls must not run. gui_gate sits at the top of each of their
; ABI entries: in mode 0 it returns normally and the entry proceeds; in
; any other mode it discards the call and returns carry-set to the
; ORIGINAL caller -- the same polite refusal the drawing entries give,
; instead of a jump into whatever now occupies the port. Internal kernel
; callers use the routines directly and never pay this.
; menu_gate -- the guard for slots the toolkit lays out in any mode's
; units: the menu draws through the port, so it is allowed in mode 3
; (the text TUI) as well as mode 0. Mode 3 passes here; anything else
; falls into gui_gate, which passes mode 0 and refuses the rest. The
; bitmap modes still refuse -- a menu there wants an 8bpp save-under
; that is future work.
menu_gate
    pha                         ; the entry's A is an argument -- saved
    lda cx_vmode                ; across the check
    cmp #2                      ; tiles (mode 2) normally have no framebuffer
    bne @pass                   ; for the toolkit -- BUT cx_tile_text can put
    lda cx_txtport              ; the tile-text port (OV3T) up, and then the
    beq gg_refuse               ; menu, widgets and dialogs draw through it
@pass                           ; just like mode 3; 0, 1 and 3 always pass
    pla
    rts
gui_gate
    pha                         ; still mode-0-only: fonts, DAs
    lda cx_vmode
    bne gg_refuse
    pla
    rts
gg_refuse
    pla                         ; drop the saved A and the wrapper's
    pla                         ; return address, then land the rts on the
    pla                         ; app with carry set (X and Y untouched)
    sec
    rts

; the gated ABI entries -- one per GUI-only slot. impl.inc points the
; slots here; the plain routines behind the jmps are unchanged.
cx_g_font_set    jsr gui_gate
                 jmp font_set
cx_g_font_style  jsr gui_gate
                 jmp font_style

; cx_say (the font-draw slot) is NOT gated -- it routes through the
; port's 14th entry (cxov_text, in impl.inc), so each engine answers for
; itself: mode 0 the CXF proportional font, text mode the cell writer,
; the bitmap modes refuse. That is the whole "mode-aware text" story, in
; the same seam as the drawing calls.
cx_g_menu_set    jsr menu_gate
                 jmp cx_do_menu_set
cx_g_menu_off    jsr menu_gate
                 jmp cx_do_menu_off
cx_g_menu_key    jsr menu_gate
                 jmp cx_do_menu_key
cx_g_wg_set      jsr menu_gate      ; widgets render ASCII-classic in text
                 jmp cx_do_wg_set
cx_g_wg_draw     jsr menu_gate
                 jmp cx_do_wg_draw
cx_g_wg_key      jsr menu_gate
                 jmp cx_do_wg_key
cx_g_theme_set   jsr gui_gate
                 jmp cx_do_theme_set
cx_g_dlg_alert   jsr menu_gate      ; dialogs lay out through the port now
                 jmp cx_do_dlg_alert
cx_g_dlg_prompt  jsr menu_gate
                 jmp cx_do_dlg_prompt
cx_g_panel       jsr menu_gate      ; the modal form: box + widgets + buttons
                 jmp cx_do_panel
cx_g_da_open     jsr gui_gate
                 jmp cx_do_da_open
cx_g_da_close    jsr gui_gate
                 jmp cx_do_da_close

cx_vmode .byte 0                ; the screen MODE the app selected (0-4)
cx_veng  .byte 0                ; the engine-IMAGE index in the port (0-8);
                                ; == cx_vmode except the bpp variants
                                ; (mode 1: 5 = 4bpp, 6 = 2bpp) and OV3T (4)
cx_tbpp  .byte 4                ; the tile mode's default depth (2/4/8), set
                                ; by cx_gfx_mode(2, bpp); cx_tile_setup adopts
                                ; it when its own bpp arg is 0. 4 = the old
                                ; hardcoded default, so nothing changes unless
                                ; an app asks for another depth up front
cx_txtport .byte 0              ; 1 while cx_tile_text has OV3T (the tile-text
                                ; port) up over mode 2, so menu_gate lets the
                                ; toolkit draw; 0 = plain tiles, toolkit refused
cx_cshift .byte 0, 0, 0, 3, 0   ; mouse coord >> this per mode. Mode 1's
                                ; mouse is already its 320-wide field (see
                                ; cx_do_mouse_show), so only text (mode 3,
                                ; a 640 field of 8px cells) shifts, by 3;
                                ; mode 4 is a native 640 field, shift 0
cx_cur_w .word 640              ; the live canvas, kept current by
cx_cur_h .word 480              ; cx_ov_bounds (the flat runner keeps
                                ; the mode-0 defaults)
cx_minfo                        ; w.w, h.w, bpp, stride.w (+1 pad) per IMAGE
    .word 640, 480              ; 0 = mode 0: 640x480 2bpp GUI
    .byte 2
    .word 160
    .byte 0
    .word 320, 240              ; 1 = mode 1 native: 320x240 8bpp
    .byte 8
    .word 320
    .byte 0
    .word 320, 240              ; 2 = mode 2: tiles -- not a bitmap, so
    .byte 0                     ; bpp 0 and no stride; the maps are
    .word 0                     ; the picture (cx_tile_*)
    .byte 0
    .word 80, 60                ; 3 = mode 3: text -- an 80x60 CELL grid,
    .byte 0                     ; bpp 0; w/h are cells, not pixels
    .word 0
    .byte 0
    .word 320, 240              ; 4 = OV3T (tile-text): tiles-like bounds
    .byte 0
    .word 0
    .byte 0
    .word 320, 240              ; 5 = OV4L: mode 1 at 4bpp
    .byte 4
    .word 160
    .byte 0
    .word 320, 240              ; 6 = OV2L: mode 1 at 2bpp
    .byte 2
    .word 80
    .byte 0
    .word 640, 480              ; 7 = OV4H: mode 4 at 4bpp (VERA_2)
    .byte 4
    .word 320
    .byte 0
    .word 640, 480              ; 8 = OV8H: mode 4 at 8bpp (VERA_2)
    .byte 8
    .word 640
    .byte 0
