; ca65
; =====================================================================
; CXRF :: kernel/ui/region.asm -- the region stack
; =====================================================================
; A region is a rectangle with a handler: "while I am on top, mouse
; events inside me are mine." Strict LIFO, CX_RG_MAX deep -- a menu
; bar, an open drop-down, a dialog, a desk accessory, and room to
; spare (docs/ui.md).
;
; This is resident because routing is: every mouse event walks the
; stack, and a bank cross per pointer move would be absurd. The
; HANDLERS are not resident -- a region's vector may point at an app,
; or at a five-byte stub that far-calls a kernel bank.
;
; The stack is event-owned state, not app state: ev_init resets it, so
; an app that inherits the machine inherits no stale rectangles.
; =====================================================================

CX_RG_MAX  = 8
CX_RG_SIZE = 10                 ; x0.w y0.w x1.w y1.w handler.w

; ---------------------------------------------------------------------
; rg_reset -- an empty stack.
; ---------------------------------------------------------------------
rg_reset
    stz rg_n
    rts

; ---------------------------------------------------------------------
; rg_push -- X16_P0..P7 = x0, y0, x1, y1 (inclusive edges); A/X = the
; handler. Carry set if the stack is full.
; ---------------------------------------------------------------------
rg_push
    ldy rg_n
    cpy #CX_RG_MAX
    bcs @full                   ; carry is already the answer
    sta rg_t                    ; the vector, while A works
    stx rg_t+1

    lda rg_n                    ; the record's slot: n * 10
    asl
    asl
    adc rg_n                    ; n*4 + n = n*5 (carry clear: n <= 7)
    asl
    tay

    ldx #0
@copy
    lda X16_P0,x
    sta rg_tab,y
    iny
    inx
    cpx #8
    bne @copy
    lda rg_t
    sta rg_tab,y
    lda rg_t+1
    sta rg_tab+1,y

    inc rg_n
    clc
@full
    rts

; ---------------------------------------------------------------------
; rg_pop -- discard the top region. Popping an empty stack is a no-op,
; so paired push/pop code cannot underflow its neighbour's region.
; ---------------------------------------------------------------------
rg_pop
    lda rg_n
    beq @done
    dec rg_n
@done
    rts

; ---------------------------------------------------------------------
; rg_remove -- A/X = a handler: remove EVERY region wearing it, wherever
; it sits in the stack, closing the gap. Pop-only-if-top is not enough
; for re-setting: an app that repaints its bar + widgets on every view
; switch interleaves the two regions, so each re-set leaked a slot and
; the 8-deep stack filled after a few switches. menu_set and wg_set
; remove their own region through here before pushing the fresh one.
; ---------------------------------------------------------------------
rg_remove
    sta rg_t                    ; the handler to hunt
    stx rg_t+1
    ldx #0                      ; the slot under inspection
@scan
    cpx rg_n
    bcs @done
    txa                         ; slot X: offset X * 10
    asl
    asl
    sta rg_t2
    txa
    clc
    adc rg_t2
    asl
    tay
    lda rg_tab+8,y
    cmp rg_t
    bne @next
    lda rg_tab+9,y
    cmp rg_t+1
    bne @next
    lda rg_n                    ; a match: slide the slots above it down
    dec a                       ; one place. end offset = (n-1)*10
    sta rg_t2
    asl
    asl
    clc
    adc rg_t2
    asl
    sta rg_t2
@slide
    cpy rg_t2
    bcs @slid
    lda rg_tab+10,y
    sta rg_tab,y
    iny
    bra @slide
@slid
    dec rg_n
    bra @scan                   ; slot X now holds the NEXT region: recheck
@next
    inx
    bra @scan
@done
    rts

; ---------------------------------------------------------------------
; rg_route -- an event record sits in X16_P0..P7 (type, detail, x.w,
; y.w). Walk the stack top-down; the first region containing the point
; wins: its handler comes back in rg_vec with carry clear. Carry set =
; nobody claims it, use the app's handler table.
;
; Top-down is the entire window model: the drop-down pushed over the
; menu bar hears the click, not the bar under it.
; ---------------------------------------------------------------------
rg_route
    ldx rg_n
@next
    dex
    bmi @miss

    txa                         ; slot X: offset X * 10 = (X*4 + X) * 2
    asl
    asl
    sta rg_t
    txa
    clc
    adc rg_t
    asl
    tay

    ; x >= x0
    lda X16_P2
    cmp rg_tab+0,y
    lda X16_P3
    sbc rg_tab+1,y
    bcc @next
    ; y >= y0
    lda X16_P4
    cmp rg_tab+2,y
    lda X16_P5
    sbc rg_tab+3,y
    bcc @next
    ; x <= x1  (x1 - x, borrow = outside)
    lda rg_tab+4,y
    cmp X16_P2
    lda rg_tab+5,y
    sbc X16_P3
    bcc @next
    ; y <= y1
    lda rg_tab+6,y
    cmp X16_P4
    lda rg_tab+7,y
    sbc X16_P5
    bcc @next

    lda rg_tab+8,y              ; claimed: the handler
    sta rg_vec
    lda rg_tab+9,y
    sta rg_vec+1
    clc
    rts
@miss
    sec
    rts

rg_n       .byte 0
rg_t       .byte 0, 0
rg_t2      .byte 0
rg_vec     .word 0
rg_tab     .res CX_RG_MAX * CX_RG_SIZE, 0
