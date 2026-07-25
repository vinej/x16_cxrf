; ca65
; =====================================================================
; CXRF :: test/geosmoke/geosmoke.asm -- headless text-geometry smoke
; =====================================================================
; Drives cx_gfx_mode(3, X) through the four toolkit geometries (80x60,
; 80x30, 64x50, 64x25), and at each size sets the menu bar + a widget
; panel and shows the mouse (so MOUSE_CONFIG runs against the live
; grid). After every switch it asserts cx_gfx_info reports the grid
; the geometry promised. Prints GEOSMOKE OK only if all four match;
; a mismatch prints GEO FAIL c=xx r=xx (hex) and stops.
;
; Run it as the boot AUTORUN.CXA and grep the -echo capture.
; =====================================================================

.include "x16.asm"
.include "asmsdk/ca65/cxrf.inc"

.segment "LOADADDR"
    .word $0801
.segment "CODE"
    basic_stub

GEO_N = 4

main
    cxm_ev_init

    ldy #0
@geo
    sty g_idx
    lda codes,y
    tax
    lda #CX_MODE_TEXT
    jsr cx_gfx_mode
    bcs @fail

    jsr paint                   ; menu + widgets + mouse on this grid

    jsr cx_gfx_info             ; P0/P1 = w, P2/P3 = h (cells)
    ldy g_idx
    lda X16_P0
    cmp wants_c,y
    bne @fail
    lda X16_P1
    bne @fail
    lda X16_P2
    cmp wants_r,y
    bne @fail
    lda X16_P3
    bne @fail

    iny
    cpy #GEO_N
    bne @geo

    ldx #0                      ; all four grids came up right
@ok
    lda s_ok,x
    beq @out
    jsr $FFD2
    inx
    bra @ok

@out
    cxm_gfx_mode CX_MODE_BMPHIGH, 2
    cxm_exit

@fail
    ldx #0
@fp
    lda s_fail,x
    beq @fc
    jsr $FFD2
    inx
    bra @fp
@fc
    lda X16_P0                  ; c=cols r=rows, hex
    jsr prhex
    lda #' '
    jsr $FFD2
    lda X16_P2
    jsr prhex
    lda #$0D
    jsr $FFD2
    bra @out

; paint: same shape as the TUIGEO demo, inside 64x25
paint
    cxm_gfx_clear 6
    cxm_say s_title, 2, 1
    cxm_menu_set bar
    cxm_wg_set widgets
    cxm_mouse_show 1
    rts

prhex
    pha
    lsr
    lsr
    lsr
    lsr
    jsr @dig
    pla
    and #$0F
@dig
    cmp #10
    bcc @num
    adc #6
@num
    adc #'0'
    jmp $FFD2

g_idx   .byte 0
codes   .byte $00, $01, $08, $09
wants_c .byte  80,  80,  64,  64
wants_r .byte  60,  30,  50,  25

bar
    cxm_menu_bar 1
    cxm_menu s_file, file_items
file_items
    cxm_items 1
    cxm_item s_quit
s_file .byte "File", 0
s_quit .byte "Quit", 0

widgets
    cxm_wcount widgets, widgets_end
    cxm_wg_button  2, 20, 12, 1, s_btn
    cxm_wg_check   2,  4, 24, 1, 1, s_chk
    cxm_wg_field   2, 11, 24, 1, 20, fieldbuf
    cxm_wg_list   40,  4, 20, 6, 4, listitems
widgets_end:

fieldbuf  .res 21, 0
listitems .addr s_l0, s_l1, s_l2, s_l3
s_btn   .byte "Button", 0
s_chk   .byte "a checkbox", 0
s_l0    .byte "one", 0
s_l1    .byte "two", 0
s_l2    .byte "three", 0
s_l3    .byte "four", 0

s_title .byte "geometry smoke", 0
s_ok    .byte $0D, "GEOSMOKE OK", $0D, 0
s_fail  .byte $0D, "GEO FAIL ", 0
