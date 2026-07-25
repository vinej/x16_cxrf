; ca65
; =====================================================================
; CXRF :: apps/tuigeo/tuigeo.asm -- the toolkit across text geometries
; =====================================================================
; The mode-3 TUI demo for cx_gfx_mode(3, X): the View menu re-enters
; text mode at another KERNAL screen geometry LIVE -- 80x60 (the
; default), 80x30, 64x50 and 64x25 -- and repaints the same menu bar,
; widget panel and modal dialog on the new grid. Those four are the
; geometries the toolkit supports (menus/dialogs need >= 64 columns
; and >= 25 rows); the narrower ones (40x30, 20x15...) are for apps
; that draw their own cell UI. Everything here is laid out inside
; 64x25, the smallest grid, so one layout fits all four.
;
; What it exercises: the geometry re-init path (switching sizes while
; mode 3 already rides the port), the live cx_minfo bounds, and the
; mouse field following the grid -- click anything at every size.
; ESC, the Exit button or File > Quit returns to the desktop.
; =====================================================================

.include "x16.asm"
.include "asmsdk/ca65/cxrf.inc"

.segment "LOADADDR"
    .word $0801
.segment "CODE"
    basic_stub

main
    cxm_ev_init
    cxm_gfx_mode CX_MODE_TEXT, 0    ; the 80x60 default first
    jsr paint

    cxm_ev_handlers handlers
    cxm_ev_mainloop

; paint the whole screen on the CURRENT grid: paper, heading, menu
; bar, widgets -- and the mouse again, so its field matches the grid
paint
    cxm_gfx_clear 6
    cxm_say title, 2, 1
    cxm_menu_set bar
    cxm_wg_set widgets
    cxm_mouse_show 1
    rts

; --- handlers ---------------------------------------------------------
on_key
    lda X16_P1
    cmp #CX_K_ESC
    beq do_exit
    lda X16_P1
    jsr cx_menu_key
    bcs @done
    lda X16_P1
    jsr cx_wg_key
@done
    rts

on_menu                         ; P2 = the menu, P1 = the item
    lda X16_P2
    beq @file                   ; File (0): 0 = Dialog, 1 = Quit
    cmp #1
    beq @view                   ; View (1): a geometry pick
    rts
@file
    lda X16_P1
    beq show_dialog
    cmp #1
    beq do_exit
    rts
@view
    ldx X16_P1                  ; item 0-3 -> the screen_mode code
    lda geocodes,x
    tax
    lda #CX_MODE_TEXT           ; re-enter mode 3 on the new grid; the
    jsr cx_gfx_mode             ; kernel reloads + reinits the engine
    jmp paint                   ; same layout, new cell count

on_widget                       ; 0 = Dialog, 1 = Exit
    lda X16_P1
    beq show_dialog
    cmp #1
    beq do_exit
    rts

show_dialog
    cxm_dlg_alert alert
    rts
do_exit
    cxm_gfx_mode CX_MODE_BMPHIGH, 2    ; the desktop's mode BEFORE leaving, so
    cxm_exit                    ; the reload never crosses a mode change

handlers                        ; NULL MOVE DOWN UP DBL KEY TIMER MENU WIDGET JOY
    .addr 0, 0, 0, 0, 0
    .addr on_key
    .addr 0
    .addr on_menu
    .addr on_widget
    .addr 0

; the View items, in menu order -> KERNAL screen_mode codes
geocodes .byte $00, $01, $08, $09

; --- the menu bar -----------------------------------------------------
bar
    cxm_menu_bar 2
    cxm_menu s_file, file_items
    cxm_menu s_view, view_items
file_items
    cxm_items 2
    cxm_item s_dlg
    cxm_item s_quit
view_items
    cxm_items 4
    cxm_item s_g8060
    cxm_item s_g8030
    cxm_item s_g6450
    cxm_item s_g6425
s_file  .byte "File", 0
s_view  .byte "View", 0
s_dlg   .byte "Dialog...", 0
s_quit  .byte "Quit", 0
s_g8060 .byte "80 x 60", 0
s_g8030 .byte "80 x 30", 0
s_g6450 .byte "64 x 50", 0
s_g6425 .byte "64 x 25", 0

; --- the widgets: everything inside 64x25, the smallest grid ---------
widgets
    cxm_wcount widgets, widgets_end
    cxm_wg_button  2, 20, 12, 1, s_bdlg         ; 0: Dialog
    cxm_wg_button 17, 20,  8, 1, s_bexit        ; 1: Exit
    cxm_wg_check   2,  4, 24, 1, 1, s_wrap      ; 2: checkbox, on
    cxm_wg_radio   2,  6, 16, 1, 1, 1, s_left   ; 3: radio (group 1), on
    cxm_wg_radio   2,  7, 16, 1, 0, 1, s_right  ; 4: radio (group 1)
    cxm_wg_scroll  2,  9, 22, 1, 3, 9           ; 5: slider 0..9, at 3
    cxm_wg_field   2, 11, 24, 1, 20, fieldbuf   ; 6: edit field, capacity 20
    cxm_wg_list   40,  4, 20, 6, 4, listitems   ; 7: list, ends at column 60
widgets_end:

fieldbuf  .res 21, 0
listitems .addr s_li0, s_li1, s_li2, s_li3

s_bdlg  .byte "Dialog", 0
s_bexit .byte "Exit", 0
s_wrap  .byte "wrap long lines", 0
s_left  .byte "align left", 0
s_right .byte "align right", 0
s_li0   .byte "Northwind", 0
s_li1   .byte "Contoso", 0
s_li2   .byte "Fabrikam", 0
s_li3   .byte "Adventure Works", 0

; --- the dialog -------------------------------------------------------
alert
    cxm_dialog 2, s_msg
    cxm_item s_no
    cxm_item s_yes
s_msg .byte "Keep this screen size?", 0
s_no  .byte "no", 0
s_yes .byte "yes", 0

title .byte "CXRF toolkit -- View picks the text size", 0
