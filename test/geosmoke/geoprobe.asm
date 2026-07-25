; ca65
; =====================================================================
; CXRF :: test/geosmoke/geoprobe.asm -- which screen_mode codes work?
; =====================================================================
; For each KERNAL code $00-$0B: cx_gfx_mode(3, code), then print
; "Pnn c=cc r=rr" (hex) -- carry-set prints "Pnn NO". Ends GEOPROBE OK.
; =====================================================================

.include "x16.asm"
.include "asmsdk/ca65/cxrf.inc"

.segment "LOADADDR"
    .word $0801
.segment "CODE"
    basic_stub

main
    cxm_ev_init
    ldy #0
@probe
    sty g_code
    lda #'P'
    jsr $FFD2
    lda g_code
    jsr prhex
    lda #' '
    jsr $FFD2
    ldx g_code
    lda #CX_MODE_TEXT
    jsr cx_gfx_mode
    bcs @no
    jsr cx_gfx_info
    lda X16_P0
    jsr prhex
    lda #' '
    jsr $FFD2
    lda X16_P2
    jsr prhex
    bra @next
@no
    lda #'N'
    jsr $FFD2
    lda #'O'
    jsr $FFD2
@next
    lda #$0D
    jsr $FFD2
    ldy g_code
    iny
    cpy #$0C
    bne @probe

    ldx #0
@ok
    lda s_ok,x
    beq @out
    jsr $FFD2
    inx
    bra @ok
@out
    cxm_gfx_mode CX_MODE_BMPHIGH, 2
    cxm_exit

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

g_code .byte 0
s_ok   .byte $0D, "GEOPROBE OK", $0D, 0
