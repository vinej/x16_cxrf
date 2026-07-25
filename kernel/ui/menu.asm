; ca65
; =====================================================================
; CXRF :: kernel/ui/menu.asm -- the menu engine
; =====================================================================
; Resident: four five-byte stubs. Everything else is B2CODE, runs in
; bank 2 through cxb_call, and costs the resident budget nothing
; (docs/ui.md). The menu tree lives in the APP's memory and is read in
; place -- $0801-$7FFF is always mapped. Format: docs/formats.md.
;
; The interaction model, deliberately minimal for 5a:
;
;   cx_menu_set   draws the bar, pushes the bar region. Once per app.
;   click in bar  opens that menu: full rows under the box are saved to
;                 the VRAM strip at $12C00 (full rows, because a linear
;                 fx_copy beats a rectangle walk and the strip can hold
;                 102 of them), the box is drawn, and a full-screen
;                 MODAL region is pushed -- menus own the machine while
;                 open, which is what makes closing them simple.
;   click again   on an item: restore, pop, post EV_MENU with the item
;                 in `detail` (P1) and the menu index in P2. Anywhere
;                 else: restore, pop, no event. Either way the machine
;                 is back the pixel it was.
;   cx_menu_off   removes the bar region. Only meaningful with no menu
;                 open; call it from handlers, not from inside a menu.
;
; Only an app that called cx_menu_set can ever receive EV_MENU, so apps
; built before the type existed cannot be handed one.
; =====================================================================

; b2_sig quotes the banked code's size as a change fingerprint
.import __B2CODE_SIZE__, __B5CODE_SIZE__

CX_MENU_H    = 12               ; the bar strip's height
CX_MENU_ROWH = 10               ; a drop-down row
CX_MENU_MAXI = 10               ; items per menu; 10 rows of save fit
CX_MENU_SAVE = $13100           ; the VRAM save-under strips. NOT $12C00:
                                ; the KERNAL mouse pointer image sits at
                                ; $13000, and a first draft that saved
                                ; from $12C00 would have written through
                                ; it with any box over six rows. The
                                ; ledger had it right all along.

; --- the resident stubs ------------------------------------------------
; The first two are what the ABI slots jump to; the second two are what
; the region stack calls. Five bytes each; the addresses are bank 2's
; local table, which ships in the same build as these stubs.

cx_do_menu_set
    jsr cxb_call
    .byte 2
    .addr $A000 + 0*3
cx_do_menu_off
    jsr cxb_call
    .byte 2
    .addr $A000 + 1*3
mn_bar_vec
    jsr cxb_call
    .byte 2
    .addr $A000 + 2*3
mn_drop_vec
    jsr cxb_call
    .byte 2
    .addr $A000 + 3*3
cx_do_menu_key
    jsr cxb_call
    .byte 2
    .addr $A000 + 11*3
cx_do_menu_active
    jsr cxb_call                ; -> A = mn_open (0 = no menu), Z from A
    .byte 2
    .addr $A000 + 5*3           ; repurposed filler slot 5 -> mn_active

; =====================================================================
; bank 2 from here on
; =====================================================================
.segment "B2CODE"

; The bank-2 jump table, at $A000. Bank-local, NOT the ABI: only the
; resident stubs name these slots ($A000 + n*3). SIXTEEN entries, with
; room to spare, so a new module fills a reserved slot without moving
; the state block behind it -- the table grew from 4 to 8 twice before,
; and each time the peekable state moved and a test's address went
; stale. Reserved slots land on mn_off, a safe near-no-op.
;
; SLOT MAP -- keep it in step with the stubs in each module's CODE half:
;   0 mn_set   1 mn_off   2 mn_bar   3 mn_drop     (menu.asm)
;   4 th_set                                        (theme.asm)
;   5 mn_active -- reads mn_open for cx_menu_active (was dg_alert filler)
;   6 -- was dg_hit; the dialog module moved to bank 5, so its resident
;         stub far-calls bank 5 directly and this slot is retired (kept
;         as filler to hold the state block at $A030)
;   7 -- was dos_cmd; the fs/dos code moved to bank 18, far-called by
;         label, so this slot is retired
;   8,9,10 -- were wg_set/wg_draw/wg_hit; the widget toolkit moved to
;         bank 16, so its resident stubs far-call bank 16 by label and
;         these slots are retired (still filler for the state block)
;   11 mn_key                                       (menu.asm, keyboard)
;   12 -- was wg_key; also bank 16 now (see 8,9,10)
;   13 -- was b2_dos_msg; also bank 18 now (see 7)
;   14,15 -- were dg_prompt/dg_panel; also bank 5 now (see 5,6)
;
; Only rows 0-4 and 11 are live now (menu + theme); the table stays 16
; entries so the peekable state block holds at $A030 (menutest reads
; mn_hot at $A03F). menu.asm and theme.asm are the last B2CODE tenants.
b2_table
    jmp mn_set                  ; 0
    jmp mn_off                  ; 1
    jmp mn_bar                  ; 2
    jmp mn_drop                 ; 3
    jmp th_set                  ; 4
    jmp mn_active               ; 5  reads mn_open for cx_menu_active
    jmp mn_off                  ; 6  retired -> dialog is bank 5 now
    jmp mn_off                  ; 7  retired -> fs/dos is bank 18 now
    jmp mn_off                  ; 8  retired -> widgets are bank 16 now
    jmp mn_off                  ; 9  retired -> widgets are bank 16 now
    jmp mn_off                  ; 10 retired -> widgets are bank 16 now
    jmp mn_key                  ; 11 kernel/ui/menu.asm (keyboard)
    jmp mn_off                  ; 12 retired -> widgets are bank 16 now
    jmp mn_off                  ; 13 retired -> fs/dos is bank 18 now
    jmp mn_off                  ; 14 retired -> dialog is bank 5 now
    jmp mn_off                  ; 15 retired -> dialog is bank 5 now

; The state block, at a FIXED spot behind the 48-byte table ($A030), so
; a test -- or a debugger, or a desperate evening -- can peek it from
; outside the bank without knowing where the code ends.
mn_bar_p .word 0                ; $A030  the app's bar; high 0 = none
mn_count .byte 0                ; $A032
mn_open  .byte 0                ; $A033
mn_cur   .byte 0                ; $A034  the open menu
mn_it_p  .word 0                ; $A035  ...its items
mn_n     .byte 0                ; $A037
mn_x0    .word 0                ; $A038  ...its box
mn_w     .word 0                ; $A03A
mn_h     .byte 0                ; $A03C
mn_pick  .byte 0                ; $A03D
mn_trace .byte 0                ; $A03E  breadcrumbs: mn_bar +1, open +$10
mn_hot   .byte 0                ; $A03F  the highlighted row; $FF = none

; CXBANKS.BIN's build signature, at the FIXED $A040 right behind the
; peekable state: "CXB", the bank, the build word, then the banked-code
; size as a change fingerprint. Stage-0 (kernel/boot/auto.asm) compares
; the first six bytes before believing this file matches CXKERNEL.PRG.
; (The state below is bank-internal; it moved down 8 bytes for this.)
b2_sig   .byte "CXB", 2
         .word CX_KBUILD
         .word __B2CODE_SIZE__ + __B5CODE_SIZE__

mn_i     .byte 0
mn_t     .byte 0, 0
mn_t2    .byte 0, 0
mn_band  .byte 0                ; the title band's colour, mid-paint
mn_mx0l  .res 8, 0              ; the bar spans, for the hit search
mn_mx0h  .res 8, 0
mn_mx1l  .res 8, 0
mn_mx1h  .res 8, 0

; ---------------------------------------------------------------------
; mn_set -- A/X = the menu bar (docs/formats.md). Draws the bar, pushes
; the bar region. Carry set if the region stack is full.
; ---------------------------------------------------------------------
mn_set
    sta mn_bar_p
    stx mn_bar_p+1
    stz mn_open

    lda mn_bar_p                ; the count, BEFORE anything loops over
    sta CX_M_PTR                ; it -- mn_entry also parks it, but
    lda mn_bar_p+1              ; mn_entry only runs inside loops that
    sta CX_M_PTR+1              ; compare against it first
    ldy #0
    lda (CX_M_PTR),y
    sta mn_count

    jsr mn_draw_bar

    lda #<mn_bar_vec            ; a re-set REPLACES the bar region, it
    ldx #>mn_bar_vec            ; does not stack a second -- an app that
    jsr rg_remove               ; repaints per view switch leaked a slot

    stz X16_P0                  ; the bar region: 0,0 to w-1, barh-1
    stz X16_P1
    stz X16_P2
    stz X16_P3
    lda cx_cur_w                ; w - 1
    sec
    sbc #1
    sta X16_P4
    lda cx_cur_w+1
    sbc #0
    sta X16_P5
    lda cxov_m_barh             ; barh - 1
    sec
    sbc #1
    sta X16_P6
    stz X16_P7
    lda #<mn_bar_vec
    ldx #>mn_bar_vec
    jmp rg_push

; ---------------------------------------------------------------------
; mn_off -- forget the menu. Pops the bar region, which is only correct
; when it is on top: call this from an event handler, never mid-menu.
; ---------------------------------------------------------------------
mn_off
    stz mn_bar_p+1              ; a null bar pointer = no menu
    lda #<mn_bar_vec            ; remove OUR region wherever it sits --
    ldx #>mn_bar_vec            ; pop-the-top was only correct when the
    jmp rg_remove               ; bar happened to be on top

; ---------------------------------------------------------------------
; Geometry helpers -- the menu lays out in the current mode's units
; (pixels in mode 0, cells in mode 3). A row's pitch is the port's
; cxov_m_rowh, so i*rowh is a runtime multiply, not a baked *10.
; ---------------------------------------------------------------------
mn_mulrowh                      ; A = k -> A = k * rowh (product fits a byte)
    tay
    lda #0
@l
    cpy #0
    beq @d
    clc
    adc cxov_m_rowh
    dey
    bra @l
@d
    rts

mn_bandy                        ; A = row i -> A = the row's band y:
    jsr mn_mulrowh              ; barh (box top) + 1 (frame) + i*rowh
    clc
    adc cxov_m_barh
    clc
    adc #1
    rts

; mn_ink -- A = the paper a label is about to land on. Sets cxov_ink to
; the CONTRASTING theme role (reverse video): a label on the highlight
; draws in the paper colour, a label on the paper draws in the highlight
; colour. Mode 3's text writer honours cxov_ink, so this is what keeps
; the highlighted row legible there; mode 0's font ignores the byte and
; uses the theme, so this is a no-op on the desktop.
mn_ink
    cmp th_hi
    bne @onpaper
    lda th_paper                ; on the highlight: the dark paper colour
    sta cxov_ink
    rts
@onpaper
    lda th_hi                   ; on the paper: the light highlight colour
    sta cxov_ink
    rts

; ---------------------------------------------------------------------
; mn_draw_bar -- the strip and the titles, and the hit spans the bar
; click will search. Title m starts 8px in, then measured width plus
; 16px of air between neighbours.
; ---------------------------------------------------------------------
mn_draw_bar
    stz X16_P0                  ; the strip: paper 0, full canvas width,
    stz X16_P1                  ; bar-height tall
    stz X16_P2
    stz X16_P3
    lda cx_cur_w
    sta X16_P4
    lda cx_cur_w+1
    sta X16_P5
    lda cxov_m_barh
    sta X16_P6
    stz X16_P7
    lda th_paper
    jsr cxov_rect
    stz X16_P0                  ; ...ruled off along its bottom
    stz X16_P1
    lda cxov_m_barh             ; barh - 1
    sec
    sbc #1
    sta X16_P2
    stz X16_P3
    lda cx_cur_w
    sta X16_P4
    lda cx_cur_w+1
    sta X16_P5
    lda th_frame
    jsr cxov_hline

    lda cxov_m_barx             ; the pen: the bar's left inset
    sta mn_t
    stz mn_t+1

    stz mn_i
@title
    lda mn_i
    cmp mn_count
    bcs @done
    jsr mn_entry                ; CX_M_PTR = entry mn_i

    ldy mn_i                    ; the span opens where the pen stands
    lda mn_t
    sta mn_mx0l,y
    lda mn_t+1
    sta mn_mx0h,y

    ldy #0                      ; the title, measured then drawn
    lda (CX_M_PTR),y
    sta mn_t2
    iny
    lda (CX_M_PTR),y
    sta mn_t2+1
    lda mn_t2
    ldx mn_t2+1
    jsr cxov_measure            ; P0/P1 = width
    clc                         ; span close = pen + width
    lda mn_t
    adc X16_P0
    ldy mn_i
    sta mn_mx1l,y
    lda mn_t+1
    adc X16_P1
    sta mn_mx1h,y

    lda mn_t                    ; draw at the pen, barty down
    sta X16_P0
    lda mn_t+1
    sta X16_P1
    lda cxov_m_barty
    sta X16_P2
    stz X16_P3
    lda th_paper                ; a bar title sits on the paper strip
    jsr mn_ink
    lda mn_t2
    ldx mn_t2+1
    jsr cxov_text               ; hands back the pen in P0/P1

    clc                         ; the air to the next title
    lda X16_P0
    adc cxov_m_airx
    sta mn_t
    lda X16_P1
    adc #0
    sta mn_t+1

    inc mn_i
    bra @title
@done
    rts

; ---------------------------------------------------------------------
; mn_title_band -- A = a colour index. Paints the OPEN menu's title
; span in the bar with it and redraws the title on top, so the bar
; itself says which menu is open: th_hi when a drop-down opens,
; th_paper when it closes. The band stops a pixel short of the bar's
; rule. The bar is not under any save-under strip, so the close path
; must paint it back by hand -- that is the th_paper call.
; ---------------------------------------------------------------------
mn_title_band
    sta mn_band
    ldy mn_cur                  ; x0 = span open - bandpad, w = span
    sec                         ; width + 2*bandpad (bandpad each side)
    lda mn_mx0l,y
    sbc cxov_m_bandpad
    sta X16_P0
    lda mn_mx0h,y
    sbc #0
    sta X16_P1
    sec
    lda mn_mx1l,y
    sbc mn_mx0l,y
    sta X16_P4
    lda mn_mx1h,y
    sbc mn_mx0h,y
    sta X16_P5
    ldx #2                      ; add bandpad twice
@wpad
    clc
    lda X16_P4
    adc cxov_m_bandpad
    sta X16_P4
    bcc @wnc
    inc X16_P5
@wnc
    dex
    bne @wpad
    stz X16_P2
    stz X16_P3
    lda cxov_m_barh             ; barh - 1
    sec
    sbc #1
    sta X16_P6
    stz X16_P7
    lda mn_band
    jsr cxov_rect

    lda mn_cur                  ; the title back on top, where the bar
    sta mn_i                    ; drew it: its span's start, barty down
    jsr mn_entry
    ldy mn_cur
    lda mn_mx0l,y
    sta X16_P0
    lda mn_mx0h,y
    sta X16_P1
    lda cxov_m_barty
    sta X16_P2
    stz X16_P3
    ldy #0
    lda (CX_M_PTR),y
    tax
    iny
    lda (CX_M_PTR),y
    stx CX_M_PTR
    sta CX_M_PTR+1
    lda mn_band                 ; the title's band: th_hi open, th_paper closed
    jsr mn_ink
    lda CX_M_PTR
    ldx CX_M_PTR+1
    jmp cxov_text

; ---------------------------------------------------------------------
; mn_entry -- CX_M_PTR = bar entry mn_i (4 bytes each, after the count),
; and mn_count loaded while passing. Uses the app's tree in place.
; ---------------------------------------------------------------------
mn_entry
    lda mn_bar_p
    sta CX_M_PTR
    lda mn_bar_p+1
    sta CX_M_PTR+1
    ldy #0
    lda (CX_M_PTR),y
    sta mn_count
    lda mn_i                    ; 1 + i*4
    asl
    asl
    sec                         ; +1 via carry
    adc CX_M_PTR
    sta CX_M_PTR
    bcc @nc
    inc CX_M_PTR+1
@nc
    rts

; ---------------------------------------------------------------------
; mn_bar -- the bar region's handler: a mouse record in X16_P0..P7.
; Only a press does anything; finding which span the x falls in picks
; the menu to open.
; ---------------------------------------------------------------------
mn_bar
    inc mn_trace
    lda X16_P0
    cmp #EV_MOUSE_DOWN
    bne @out
    lda mn_bar_p+1
    beq @out                    ; no bar set: a stale region, ignore

    stz mn_i
@span
    lda mn_i
    cmp mn_count
    bcs @out                    ; the gap between titles: nothing
    ldy mn_i
    lda X16_P2                  ; x >= span open
    cmp mn_mx0l,y
    lda X16_P3
    sbc mn_mx0h,y
    bcc @next
    lda mn_mx1l,y               ; x <= span close
    cmp X16_P2
    lda mn_mx1h,y
    sbc X16_P3
    bcc @next
    lda mn_i
    jmp mn_drop_open
@next
    inc mn_i
    bra @span
@out
    rts

; ---------------------------------------------------------------------
; mn_drop_open -- A = the menu to open. Geometry, save-under, paint,
; and the modal region.
; ---------------------------------------------------------------------
mn_drop_open
    pha
    lda mn_trace
    clc
    adc #$10
    sta mn_trace
    pla
    sta mn_cur
    sta mn_i
    jsr mn_entry
    ldy #2                      ; the items list
    lda (CX_M_PTR),y
    sta mn_it_p
    iny
    lda (CX_M_PTR),y
    sta mn_it_p+1

    lda mn_it_p                 ; item count, capped to what the strip
    sta CX_M_PTR                ; can save under
    lda mn_it_p+1
    sta CX_M_PTR+1
    ldy #0
    lda (CX_M_PTR),y
    cmp #CX_MENU_MAXI+1
    bcc @nok
    lda #CX_MENU_MAXI
@nok
    sta mn_n

    ; the box: x0 = the title's span, w = widest item + 8, h = n rows +2
    ldy mn_cur
    lda mn_mx0l,y
    sta mn_x0
    lda mn_mx0h,y
    sta mn_x0+1

    stz mn_w
    stz mn_w+1
    stz mn_i
@wide
    lda mn_i
    cmp mn_n
    bcs @wdone
    jsr mn_item                 ; CX_M_PTR = label mn_i
    lda CX_M_PTR
    ldx CX_M_PTR+1
    jsr cxov_measure
    lda X16_P0                  ; keep the widest
    cmp mn_w
    lda X16_P1
    sbc mn_w+1
    bcc @thin
    lda X16_P0
    sta mn_w
    lda X16_P1
    sta mn_w+1
@thin
    inc mn_i
    bra @wide
@wdone
    clc
    lda mn_w
    adc cxov_m_boxwpad          ; the box's horizontal padding
    sta mn_w
    bcc @wnc
    inc mn_w+1
@wnc

    lda mn_n                    ; h = n*rowh + 2 (top + bottom frame)
    jsr mn_mulrowh
    clc
    adc #2
    sta mn_h

    lda #1                      ; save the rows the box will cover
    jsr mn_strip

    lda mn_x0                   ; paper...
    sta X16_P0
    lda mn_x0+1
    sta X16_P1
    lda cxov_m_barh
    sta X16_P2
    stz X16_P3
    lda mn_w
    sta X16_P4
    lda mn_w+1
    sta X16_P5
    lda mn_h
    sta X16_P6
    stz X16_P7
    lda th_paper
    jsr cxov_rect
    lda mn_x0                   ; ...framed...
    sta X16_P0
    lda mn_x0+1
    sta X16_P1
    lda cxov_m_barh
    sta X16_P2
    stz X16_P3
    lda mn_w
    sta X16_P4
    lda mn_w+1
    sta X16_P5
    lda mn_h
    sta X16_P6
    stz X16_P7
    lda th_frame
    jsr cxov_frame

    stz mn_i                    ; ...and the items
@item
    lda mn_i
    cmp mn_n
    bcs @idone
    jsr mn_item
    clc                         ; x = x0 + itemx
    lda mn_x0
    adc cxov_m_itemx
    sta X16_P0
    lda mn_x0+1
    adc #0
    sta X16_P1
    lda mn_i                    ; y = bandy(i) + itemdy
    jsr mn_bandy
    clc
    adc cxov_m_itemdy
    sta X16_P2
    stz X16_P3
    lda th_paper                ; a fresh item sits on the box paper
    jsr mn_ink
    lda CX_M_PTR
    ldx CX_M_PTR+1
    jsr cxov_text
    inc mn_i
    bra @item
@idone

    stz X16_P0                  ; the modal region: menus own the
    stz X16_P1                  ; machine while open -- the whole canvas
    stz X16_P2
    stz X16_P3
    lda cx_cur_w                ; w - 1
    sec
    sbc #1
    sta X16_P4
    lda cx_cur_w+1
    sbc #0
    sta X16_P5
    lda cx_cur_h                ; h - 1
    sec
    sbc #1
    sta X16_P6
    lda cx_cur_h+1
    sbc #0
    sta X16_P7
    lda #<mn_drop_vec
    ldx #>mn_drop_vec
    jsr rg_push
    lda #$FF                    ; nothing highlighted until the pointer
    sta mn_hot                  ; says so
    lda #1
    sta mn_open
    lda th_hi                   ; the bar shows which menu is open
    jmp mn_title_band

; ---------------------------------------------------------------------
; mn_item -- CX_M_PTR = item label mn_i: the list is a count, then a
; word per item.
; ---------------------------------------------------------------------
mn_item
    lda mn_it_p
    sta CX_M_PTR
    lda mn_it_p+1
    sta CX_M_PTR+1
    lda mn_i                    ; 1 + i*2
    asl
    sec
    adc CX_M_PTR
    sta CX_M_PTR
    bcc @nc
    inc CX_M_PTR+1
@nc
    ldy #0                      ; resolve to the label itself
    lda (CX_M_PTR),y
    tax
    iny
    lda (CX_M_PTR),y
    sta CX_M_PTR+1
    stx CX_M_PTR
    rts

; ---------------------------------------------------------------------
; mn_drop -- the modal region's handler. A press picks or dismisses;
; either way the pixels come back and the modal region goes.
; ---------------------------------------------------------------------
mn_drop
    lda X16_P0
    cmp #EV_MOUSE_DOWN
    beq @press
    cmp #EV_MOUSE_MOVE
    beq @hover
    rts

@hover                          ; the row under the pointer follows it
    jsr mn_rowat
    cmp mn_hot
    beq @still                  ; the same row: nothing to repaint
    jmp mn_hotswap
@still
    rts

@press
    jsr mn_rowat                ; $FF misses double as "dismiss"
    ; falls into mn_finish

; ---------------------------------------------------------------------
; mn_finish -- A = the chosen item, or $FF to dismiss. Restores the
; pixels, pops the modal region, and -- unless dismissed -- posts
; EV_MENU. Shared by the click, the keyboard, and menu switching.
; ---------------------------------------------------------------------
mn_finish
    sta mn_pick
    lda th_paper                ; the open title's band off the bar (the
    jsr mn_title_band           ; bar is above the save-under strip)
    lda #0                      ; the pixels back, the region gone
    jsr mn_strip
    jsr rg_pop
    stz mn_open

    lda mn_pick
    bmi @out                    ; dismissed: no one hears anything
    sta X16_P1                  ; EV_MENU: detail = item, P2 = menu
    lda #EV_MENU
    sta X16_P0
    lda mn_cur
    sta X16_P2
    stz X16_P3
    stz X16_P4
    stz X16_P5
    stz X16_P6
    stz X16_P7
    jmp ev_post
@out
    rts

; ---------------------------------------------------------------------
; mn_key -- A = a key. Drives the menus from the keyboard: DOWN opens
; the bar; once open, UP/DOWN move the highlight, LEFT/RIGHT switch
; menus, RETURN picks, ESC dismisses. Carry set if the key was a menu
; key (the app should not also act on it), clear to pass it through.
;
; The same open/highlight/finish routines the mouse uses, so a menu
; driven blind by the keyboard behaves exactly like a clicked one --
; including the EV_MENU it posts.
; ---------------------------------------------------------------------
KEY_DOWN  = $11
KEY_UP    = $91
KEY_RIGHT = $1D
KEY_LEFT  = $9D
KEY_ENTER = $0D
KEY_ESC   = $1B

mn_key
    ldx mn_bar_p+1
    beq @no                     ; no bar set: not ours
    ldx mn_open
    bne @open

    cmp #KEY_DOWN               ; closed: DOWN drops the first menu
    bne @no
    lda #0
    jsr mn_kopen
    bra @yes

@open
    cmp #KEY_ESC
    beq @dismiss
    cmp #KEY_ENTER
    beq @pick
    cmp #KEY_DOWN
    beq @down
    cmp #KEY_UP
    beq @up
    cmp #KEY_RIGHT
    beq @right
    cmp #KEY_LEFT
    beq @left
    bra @no                     ; a typing key: the app's, not ours

@dismiss
    lda #$FF
    jsr mn_finish
    bra @yes
@pick
    lda mn_hot
    jsr mn_finish
    bra @yes
@down
    ldx mn_hot
    inx                         ; $FF (none) wraps to 0 too
    cpx mn_n
    bcc @seth
    ldx #0
@seth
    txa
    jsr mn_hotswap
    bra @yes
@up
    ldx mn_hot
    bmi @last                   ; none highlighted: wrap to the last
    dex
    bpl @seth2
@last
    ldx mn_n
    dex
@seth2
    txa
    jsr mn_hotswap
    bra @yes
@right
    ldx mn_cur
    inx
    cpx mn_count
    bcc @switch
    ldx #0
@switch
    txa
    jsr mn_switch
    bra @yes
@left
    ldx mn_cur
    bne @decm
    ldx mn_count
@decm
    dex
    txa
    jsr mn_switch
@yes
    sec
    rts
@no
    clc
    rts

; mn_active -- cx_menu_active: A = mn_open (0 = no menu dropped), Z set from
; it. Both the mouse and keyboard open paths set mn_open, so an app can tell
; a menu is up however it opened and route the keyboard to it.
mn_active
    lda mn_open
    rts

; mn_kopen -- A = menu: open its drop-down and highlight item 0.
mn_kopen
    jsr mn_drop_open
    lda #0
    jmp mn_hotswap

; mn_switch -- A = menu: close the open drop-down (no pick) and open
; the given one. LEFT/RIGHT walk the bar this way.
mn_switch
    pha
    lda #$FF
    jsr mn_finish
    pla
    jmp mn_kopen

; ---------------------------------------------------------------------
; mn_rowat -- the record's point (X16_P2..P5) against the open box:
; A = the item row it lands on, or $FF -- outside, on the frame, or
; past the last item. The press and the hover share this verdict.
; ---------------------------------------------------------------------
mn_rowat
    lda X16_P2                  ; x >= x0
    cmp mn_x0
    lda X16_P3
    sbc mn_x0+1
    bcc @no
    clc                         ; x < x0 + w
    lda mn_x0
    adc mn_w
    sta mn_t
    lda mn_x0+1
    adc mn_w+1
    sta mn_t+1
    lda X16_P2
    cmp mn_t
    lda X16_P3
    sbc mn_t+1
    bcs @no
    lda X16_P5                  ; rows start at barh+1, rowh each
    bne @no
    lda X16_P4
    sec
    sbc cxov_m_barh             ; y - barh
    bcc @no
    sec
    sbc #1                      ; - 1 (the frame)
    bcc @no
    ldx #0
@row
    cmp cxov_m_rowh
    bcc @got
    sbc cxov_m_rowh             ; carry known set from cmp
    inx
    bra @row
@got
    cpx mn_n
    bcs @no
    txa
    rts
@no
    lda #$FF
    rts

; ---------------------------------------------------------------------
; mn_hotswap -- A = the row the highlight moves to ($FF = none). The
; old row is repainted plain, the new one on paper 1; the label rides
; on top both times, because the masked blit keeps whatever paper it
; lands on.
; ---------------------------------------------------------------------
mn_hotswap
    pha
    lda mn_hot
    bmi @nold
    ldy th_paper
    jsr mn_row_paint
@nold
    pla
    sta mn_hot
    bmi @done
    ldy th_hi
    jsr mn_row_paint
@done
    rts

; ---------------------------------------------------------------------
; mn_row_paint -- A = row, Y = its paper. The band inside the frame,
; then the label again.
; ---------------------------------------------------------------------
mn_row_paint
    sta mn_i
    sty mn_t2
    clc                         ; the band: x0+1, w-2 -- off the frame
    lda mn_x0
    adc #1
    sta X16_P0
    lda mn_x0+1
    adc #0
    sta X16_P1
    lda mn_i                    ; y = bandy(row)
    jsr mn_bandy
    sta X16_P2
    stz X16_P3
    sec                         ; w - 2 (off both frames)
    lda mn_w
    sbc #2
    sta X16_P4
    lda mn_w+1
    sbc #0
    sta X16_P5
    lda cxov_m_rowh
    sta X16_P6
    stz X16_P7
    lda mn_t2
    jsr cxov_rect

    jsr mn_item                 ; the label, back on top
    clc
    lda mn_x0
    adc cxov_m_itemx
    sta X16_P0
    lda mn_x0+1
    adc #0
    sta X16_P1
    lda mn_i                    ; y = bandy(row) + itemdy
    jsr mn_bandy
    clc
    adc cxov_m_itemdy
    sta X16_P2
    stz X16_P3
    lda mn_t2                   ; the row's band: th_hi hot, th_paper not
    jsr mn_ink
    lda CX_M_PTR
    ldx CX_M_PTR+1
    jmp cxov_text

; ---------------------------------------------------------------------
; mn_strip -- A = 1 saves, 0 restores the rows the open box covers.
; Through the port: the box sits at row barh (the bar's foot) and is
; mn_h rows tall, and each engine preserves its own canvas -- mode 0 to
; a VRAM strip, mode 3 to a bank of text cells. So the menu never knows
; how the pixels (or cells) are stashed.
; ---------------------------------------------------------------------
mn_strip
    tax                         ; the direction, for later
    lda cxov_m_barh             ; the box top row
    sta X16_P0
    stz X16_P1
    lda mn_h                    ; the row count
    sta X16_P2
    cpx #0
    beq @restore
    jmp cxov_rsave
@restore
    jmp cxov_rrest

.segment "CODE"
