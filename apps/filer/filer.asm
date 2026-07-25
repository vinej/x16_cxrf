; ca65
; =====================================================================
; CXRF :: apps/filer/filer.asm -- the desktop (Phase 6)
; =====================================================================
; The file browser that IS the shell: boot lands here, and cx_exit
; comes back here. The directory arrives through cx_dir_*, lives in a
; list widget, and opening an entry is the whole desktop idea --
; a folder is entered (CD), an app is launched (cx_app_load), and
; anything else politely refuses. The File menu holds the four
; operations -- new folder, rename, copy, delete -- each built as a
; CMDR-DOS command for cx_dos_cmd, named through cx_dlg_prompt, with
; delete behind a confirm alert whose SAFE button is the default.
; The drive's own reply text is shown after every operation.
;
; Mouse or keyboard throughout: click selects, double-click opens;
; UP/DOWN + RETURN do the same; TAB raises the menu bar, ESC leaves.
; =====================================================================

.include "x16.asm"
.include "asmsdk/ca65/cxrf.inc"

WG_ICON   = 6                   ; emit_icon_rec writes this record type at runtime
WG_SELECTED = $40               ; WG_FLAGS bit: emit_icon_rec sets it on the icon
                                ; an app was launched from, and the kernel focuses
                                ; the flagged record when the list is installed

; the icon ids cx_icon draws (kernel/ui/icon.asm; order = tools/icongen.py)
ICON_UP        = 0
ICON_FOLDER    = 1
ICON_APP       = 2
ICON_FONT      = 3
ICON_ACCESSORY = 4
ICON_DATA      = 5
ICON_IMAGE     = 6
ICON_DISK      = 7
ICON_CALC      = 8              ; per-app icons for the shipped demos
ICON_PAINT     = 9
ICON_GAME      = 10
ICON_TEXT      = 11
ICON_SOUND     = 12
ICON_SPRITE    = 13
ICON_TILE      = 14
ICON_TERM      = 15
ICON_GEARS     = 16
ICON_GLOBE     = 17

MAXFILES  = 96
NAMEMAX   = 36                  ; bytes reserved per name in the pool: up to 34
                                ; chars (cx_dir_next's cap) + a dir's '/' + NUL

; the icon-view grid (mode 0, 640x480). CONTENT_Y0 is the first row below
; the menu bar and title, cleared and redrawn on a view switch.
CONTENT_Y0 = 44
GX0    = 32
GY0    = 52
GCW    = 96                     ; cell width  (icon centred in it)
GCH    = 38                     ; cell height: icon (24) + one caption line,
                                ; hugged tight so the selection frame sits just
                                ; around it -- no empty band below the title
GCOLS  = 6
GROWS  = 6
PERPAGE = GCOLS * GROWS         ; 36 icons a page
MAXICON = PERPAGE

; The kernel's cx_hdr_shell header byte ($800A): resident, so unlike the
; desktop's own RAM it survives an app launch and the cx_exit back. The
; view mode lives here, so returning from a program lands in the same view
; it was launched from -- the directory still resets to root (above), but
; list-vs-icons is a preference and should stick.
CX_SHELL_STATE = $800A
; $800B: the file index the last app was launched from (into the root
; listing), restored as the desktop's selection on the cx_exit back. $FF =
; none -- a cold boot, or a launch from inside a folder, where the reset-to-
; root above makes the index meaningless.
CX_SHELL_SEL = $800B

; app zero page ($60-$7F is the app's)
poolp = $60                     ; the pool write head / a name walker
iwp   = $62                     ; the icon record write head, (zp),y
spoolp = $64                    ; the size-string pool write head, (zp),y

.segment "LOADADDR"
    .word $0801
.segment "CODE"
    basic_stub

main
    ldx #0
@mk
    lda s_marker,x
    beq @go
    jsr CHROUT
    inx
    bne @mk
@go
    cxm_gfx_init

    ; The disk work goes FIRST, before the screen is cleared. gfx2h_init
    ; leaves the framebuffer alone, so the outgoing app's picture stays up
    ; through the directory read; then the clear and the whole desktop are
    ; painted in one burst instead of a bare screen sitting through the I/O
    ; -- the jarring part when an app closes.
    cxm_dos_cmd s_home, s_home_len  ; home is the root: an app launched from a
                                ; folder leaves us there on reload, so the
                                ; desktop always resets. depth stays 0
    jsr seed_clock              ; start the RTC if at the emulator default
    jsr readdir                 ; fill the list from the directory

    cxm_gfx_clear 0                 ; now clear and paint the desktop at once
    cxm_say s_title, 20, 20

    cxm_ev_init
    cxm_menu_set bar

    ; --- restore the selection the last app was launched from ----------
    ; The list installs focused now (WG_SELECTED on its record), so UP/DOWN
    ; work at once without the old priming TAB; the icon grid flags the one
    ; restored file the same way, so both views land on the launched app.
    lda #WG_SELECTED
    sta wl_rec + 1
    lda CX_SHELL_SEL            ; the launched file's index; $FF or stale -> 0
    cmp fcount
    bcc @selok
    lda #0
@selok
    sta wl_rec + 9             ; list view: the selected row
    sta restore_sel            ; icon view: emit_icon_rec flags this file
    ldx #0                     ; iconpage = sel / PERPAGE (the page holding it)
@selpg
    cmp #PERPAGE
    bcc @selpgok
    sbc #PERPAGE
    inx
    bra @selpg
@selpgok
    stx iconpage

    lda CX_SHELL_STATE          ; the view the last desktop left; the cell
    and #1                      ; stores viewmode INVERTED, so the cold-boot
    eor #1                      ; zero lands on the DEFAULT view, icons. An
    sta viewmode                ; app launch does not clear it
    beq @vlist
    jsr build_icons             ; icons: lay the grid, then install it
    lda #<iwbuf
    ldx #>iwbuf
    bra @vset
@vlist
    lda #<widgets
    ldx #>widgets
@vset
    jsr cx_wg_set               ; A/X = the chosen list; wg_set focuses the
    lda #$FF                    ; WG_SELECTED record. Clear the one-shot so a
    sta restore_sel             ; later page turn does not re-force it
    cxm_mouse_show 1            ; the arrow

    cxm_ev_timer 60                ; a tick a second, for the clock
    jsr on_timer                ; and the clock NOW, not in a second

    cxm_ev_handlers handlers
    cxm_ev_mainloop

; ---------------------------------------------------------------------
say                             ; A/X = string, Y = row; column 20
    sty X16_P2
    stz X16_P3
    ldy #20
    sty X16_P0
    stz X16_P1
    jmp cx_font_draw

note                            ; A/X = string onto a cleared note row
    pha
    phx
    ldy #20                     ; the row back to paper first
    sty X16_P0
    stz X16_P1
    ldy #30
    sty X16_P2
    stz X16_P3
    lda #<600
    sta X16_P4
    lda #>600
    sta X16_P5
    lda #12
    sta X16_P6
    stz X16_P7
    lda #0
    jsr cx_gfx_rect
    plx
    pla
    ldy #30
    jmp say

; ---------------------------------------------------------------------
; readdir -- walk the directory into the pool. Inside a folder (depth >
; 0) row 0 is "../", the way up; at the root there is nowhere up, so no
; such row -- CD:.. above the root is a DOS "file not found", which is
; the loop the owner hit. The listing's own "." and ".." are skipped:
; the one go-back row is ours. Directories wear a trailing '/'.
; ---------------------------------------------------------------------
readdir
    stz fcount
    lda #<pool                  ; the pool grows from the start...
    sta poolp
    lda #>pool
    sta poolp+1
    lda #<spool                 ; ...and so does the size-string pool
    sta spoolp
    lda #>spool
    sta spoolp+1

    lda depth                   ; ...after a "../" go-back row, but only
    beq @open                   ; when we are down inside a folder
    lda #<pool
    sta fptrs
    lda #>pool
    sta fptrs+1
    lda #'.'
    sta pool
    sta pool+1
    lda #'/'
    sta pool+2
    stz pool+3
    lda #1
    sta fcount
    lda #ICON_UP                ; the go-back row wears the up arrow
    sta ficon
    stz fsptrs                  ; ...and shows no size
    stz fsptrs+1
    lda #<(pool+4)
    sta poolp
    lda #>(pool+4)
    sta poolp+1
@open
    cxm_dir_open pat, 1
    bcc @opened                 ; the loop body outgrew a short branch to @none
    jmp @none
@opened
    lda poolp                   ; discard the volume header
    sta X16_P0
    lda poolp+1
    sta X16_P1
    jsr cx_dir_next
@loop
    lda poolp                   ; next name at the free spot
    sta X16_P0
    lda poolp+1
    sta X16_P1
    jsr cx_dir_next
    bcs @done
    sta ftype                   ; 0 file / 1 dir
    lda X16_P2                  ; the entry's block count, before the name
    sta fblocks                 ; processing below can touch the P block
    lda X16_P3
    sta fblocks+1

    ldy #0                      ; skip the listing's own "." and ".." --
    lda (poolp),y               ; our "../" row is the only go-back
    cmp #'.'
    bne @keep
    iny
    lda (poolp),y
    beq @loop                   ; "." alone
    cmp #'.'
    bne @keep
    iny
    lda (poolp),y
    beq @loop                   ; ".."
@keep
    lda ftype                   ; folders always show; a system artifact
    bne @store                  ; (.X16 .BIN .PRG .CXF) is hidden, so the
    jsr hidden_ext              ; list is the programs and folders only
    bcs @loop
@store
    ldx fcount                  ; fptrs[count] = poolp
    txa
    asl
    tay
    lda poolp
    sta fptrs,y
    lda poolp+1
    sta fptrs+1,y

    jsr entry_icon              ; ficon[count] = its type icon
    ldx fcount
    sta ficon,x

    jsr store_size              ; fsptrs[count] = the block count (files) or
                                ; null (folders), for the list's size column

    ldy #0                      ; the name's end
@len
    lda (poolp),y
    beq @nul
    iny
    cpy #NAMEMAX-2
    bcc @len
@nul
    lda ftype                   ; a directory wears its slash
    beq @plain
    lda #'/'
    sta (poolp),y
    iny
    lda #0
    sta (poolp),y
@plain
    iny                         ; past the NUL
    tya
    clc
    adc poolp
    sta poolp
    bcc @nc
    inc poolp+1
@nc
    inc fcount
    lda fcount
    cmp #MAXFILES
    bcs @done                   ; the store_size body pushed @loop out of a
    jmp @loop                   ; short branch's reach: invert + jmp back
@done
    cxm_dir_close
@none
    lda fcount                  ; the record: count, selection 0, top 0
    sta wl_rec + 10
    stz wl_rec + 9
    stz wl_rec + 13
    rts

; ---------------------------------------------------------------------
; store_size -- fsptrs[fcount] for the row just stored. A folder shows no
; size (a null pointer); a file gets its block count formatted into spool
; and the pointer stored. Uses ftype, fblocks and spoolp; preserves poolp.
; ---------------------------------------------------------------------
store_size
    lda fcount                  ; Y = fcount * 2 (the pointer slot)
    asl
    tay
    lda ftype                   ; a directory: no size column
    beq @file
    lda #0
    sta fsptrs,y
    sta fsptrs+1,y
    rts
@file
    lda spoolp                  ; fsptrs[i] = spoolp, the string fmt_u16 writes
    sta fsptrs,y
    lda spoolp+1
    sta fsptrs+1,y
    ; fall through to fmt_u16: fblocks -> (spoolp), NUL-term, spoolp advanced

; fmt_u16 -- fblocks (0..65535) as decimal at (spoolp), NUL-terminated;
; spoolp is advanced past the NUL. Leading zeros suppressed; value 0 -> "0".
fmt_u16
    lda fblocks
    sta fm_val
    lda fblocks+1
    sta fm_val+1
    stz fm_wi                   ; write index into (spoolp)
    stz fm_lead                 ; 0 = still suppressing leading zeros
    ldx #0                      ; power index (0..4)
@digit
    stz fm_dig
@sub
    sec                         ; fm_val -= power[x] while it stays >= 0
    lda fm_val
    sbc fm_pw_lo,x
    tay
    lda fm_val+1
    sbc fm_pw_hi,x
    bcc @emit                   ; went negative: fm_val is the remainder
    sta fm_val+1
    sty fm_val
    inc fm_dig
    bra @sub
@emit
    cpx #4                      ; the ones place always prints (handles 0)
    beq @put
    lda fm_dig
    bne @lead                   ; a non-zero digit stops suppression
    lda fm_lead
    beq @skip                   ; still suppressing a leading zero: drop it
@lead
    lda #1
    sta fm_lead
@put
    ldy fm_wi
    lda fm_dig
    clc
    adc #'0'
    sta (spoolp),y
    inc fm_wi
@skip
    inx
    cpx #5
    bne @digit
    ldy fm_wi                   ; NUL-terminate
    lda #0
    sta (spoolp),y
    iny                         ; advance spoolp past the string and its NUL
    tya
    clc
    adc spoolp
    sta spoolp
    bcc @done
    inc spoolp+1
@done
    rts

fm_pw_lo .byte $10, $E8, $64, $0A, $01   ; 10000 1000 100 10 1, low bytes
fm_pw_hi .byte $27, $03, $00, $00, $00   ; ...and high bytes

refresh                         ; the directory again, repainted
    jsr readdir
    lda viewmode
    beq @list
    stz iconpage                ; a fresh listing lands on the first page
    jmp set_view                ; re-grid the icons and repaint
@list
    jmp cx_wg_draw

; ---------------------------------------------------------------------
; entry_icon -- A = the type icon for the entry at (poolp), given ftype
; (0 file / 1 dir). A folder gets the folder; a file is classed by its
; extension -- .CXA an app, .CXD a desk accessory, anything else data.
; The name is NUL-terminated here (the slash a directory wears is added
; after this runs), so the suffix test is on the bare name.
; ---------------------------------------------------------------------
entry_icon
    lda ftype
    beq @file
    lda #ICON_FOLDER
    rts
@file
    ldy #0                      ; Y = strlen
@sl
    lda (poolp),y
    beq @got
    iny
    cpy #NAMEMAX
    bcc @sl
@got
    cpy #4                      ; shorter than ".CX?": data
    bcc @data
    tya
    sec
    sbc #4
    tay                         ; Y -> the four-char suffix
    lda (poolp),y
    cmp #'.'
    bne @data
    iny
    lda (poolp),y
    cmp #'C'
    bne @data
    iny
    lda (poolp),y
    cmp #'X'
    bne @data
    iny
    lda (poolp),y
    cmp #'A'
    beq @app
    cmp #'D'
    beq @acc
@data
    lda #ICON_DATA
    rts
@app
    jmp app_icon                ; a known demo -> its own icon, else ICON_APP
@acc
    lda #ICON_ACCESSORY
    rts

; ---------------------------------------------------------------------
; app_icon -- A = the per-app icon for the .CXA at (poolp), matched by name
; against app_tab; the generic ICON_APP if the name is not one the desktop
; knows. app_tab is (NUL-terminated name, icon byte) pairs, ended by a lone
; 0 byte. The name is still bare here (entry_icon runs before the slash).
; ---------------------------------------------------------------------
app_icon
    lda #<app_tab
    sta iwp                     ; iwp is free until build_icons; reuse it as the
    lda #>app_tab               ; table walker so (iwp),y reaches each entry
    sta iwp+1
@ent
    ldy #0
    lda (iwp),y                 ; a lone 0 byte ends the table
    bne @cmp
    lda #ICON_APP
    rts
@cmp
    ldy #0                      ; compare the file name to this entry's name
@ch
    lda (iwp),y
    beq @eend                   ; entry name ended...
    cmp (poolp),y
    bne @adv                    ; a mismatch: on to the next entry
    iny
    bra @ch
@eend
    lda (poolp),y               ; ...the file name must end in the same spot
    bne @adv
    iny                         ; Y on the NUL -> the icon byte follows it
    lda (iwp),y
    rts
@adv                            ; iwp += strlen(entry) + 2 (its NUL and icon)
    ldy #0
@sk
    lda (iwp),y
    beq @skend
    iny
    bra @sk
@skend
    iny
    iny
    tya
    clc
    adc iwp
    sta iwp
    bcc @ent
    inc iwp+1
    bra @ent

; ---------------------------------------------------------------------
; the icon view: a page of the directory as a grid of icon widgets
; ---------------------------------------------------------------------
; set_view -- clear the content area and draw whichever view is current.
; The menu bar and title above CONTENT_Y0 stay standing; cx_wg_set is
; idempotent (it replaces its click region), so toggling never leaks the
; region stack.
set_view
    jsr clear_content
    lda viewmode
    beq @list
    jsr build_icons
    lda #<iwbuf
    ldx #>iwbuf
    jmp cx_wg_set
@list
    lda #<widgets
    ldx #>widgets
    jmp cx_wg_set

; clear_content -- the desktop below the bar back to paper (index 0).
clear_content
    stz X16_P0
    stz X16_P1
    lda #CONTENT_Y0
    sta X16_P2
    stz X16_P3
    lda #<640
    sta X16_P4
    lda #>640
    sta X16_P5
    lda #<(480 - CONTENT_Y0)
    sta X16_P6
    lda #>(480 - CONTENT_Y0)
    sta X16_P7
    lda #0
    jmp cx_gfx_rect

; build_icons -- lay this page's files into iwbuf as WG_ICON records.
; A page is PERPAGE cells on a GCOLS x GROWS grid; it stops early at the
; last file. pagebase = iconpage * PERPAGE is the first file shown.
build_icons
    lda #0                      ; pagebase = iconpage * PERPAGE
    sta pagebase
    ldx iconpage
    beq @pbok
@pbmul
    clc
    lda pagebase
    adc #PERPAGE
    sta pagebase
    dex
    bne @pbmul
@pbok
    lda restore_sel             ; the icon to install focused: the restored file,
    cmp #$FF                    ; or -- absent one (a page turn) -- the first icon
    bne @ffok                   ; on this page, so the frame always lands somewhere
    lda pagebase                ; and the arrow keys have a place to start
@ffok
    sta focus_fidx
    stz iw_n
    lda #<(iwbuf+1)
    sta iwp
    lda #>(iwbuf+1)
    sta iwp+1
    lda #GY0
    sta cy
    stz cy+1
    stz grow
@rows
    lda grow
    cmp #GROWS
    bcs @finish
    lda #GX0
    sta cxw
    stz cxw+1
    stz gcol
@cols
    lda gcol
    cmp #GCOLS
    bcs @nextrow
    lda pagebase                ; fidx = pagebase + iw_n, until fcount
    clc
    adc iw_n
    cmp fcount
    bcs @finish
    sta fidx
    jsr emit_icon_rec
    clc                         ; the record head forward one widget
    lda iwp
    adc #16
    sta iwp
    bcc @iwok
    inc iwp+1
@iwok
    inc iw_n
    clc                         ; the next column
    lda cxw
    adc #GCW
    sta cxw
    bcc @cxok
    inc cxw+1
@cxok
    inc gcol
    bra @cols
@nextrow
    clc                         ; the next row
    lda cy
    adc #GCH
    sta cy
    bcc @cyok
    inc cy+1
@cyok
    inc grow
    bra @rows
@finish
    lda iw_n
    sta iwbuf                   ; the count byte the toolkit reads
    rts

; emit_icon_rec -- one 16-byte WG_ICON record at (iwp) for file fidx at
; cell (cxw, cy). WG_VAL is its icon, WG_LBL its name pointer.
emit_icon_rec
    ldy #0                      ; WG_TYPE
    lda #WG_ICON
    sta (iwp),y
    ldy #1                      ; WG_FLAGS -- focus_fidx installs focused
    lda #0                      ; (WG_SELECTED): the restored file, or the first
    ldx fidx                    ; icon of the page after a turn
    cpx focus_fidx
    bne @flags
    lda #WG_SELECTED
@flags
    sta (iwp),y
    ldy #2                      ; WG_X
    lda cxw
    sta (iwp),y
    ldy #3
    lda cxw+1
    sta (iwp),y
    ldy #4                      ; WG_Y
    lda cy
    sta (iwp),y
    ldy #5
    lda cy+1
    sta (iwp),y
    ldy #6                      ; WG_W
    lda #GCW
    sta (iwp),y
    ldy #7
    lda #0
    sta (iwp),y
    ldy #8                      ; WG_H
    lda #GCH
    sta (iwp),y
    ldy #9                      ; WG_VAL = the icon id
    ldx fidx
    lda ficon,x
    sta (iwp),y
    ldy #10                     ; WG_GRP
    lda #0
    sta (iwp),y
    lda fidx                    ; WG_LBL = fptrs[fidx]
    asl
    tax
    ldy #11
    lda fptrs,x
    sta (iwp),y
    ldy #12
    lda fptrs+1,x
    sta (iwp),y
    ldy #13                     ; WG_TOP + the two pad bytes
    lda #0
    sta (iwp),y
    ldy #14
    sta (iwp),y
    ldy #15
    sta (iwp),y
    rts

; ---------------------------------------------------------------------
; hidden_ext -- carry set if the name at (poolp) ends in a system-file
; extension the desktop hides (.X16 .BIN .PRG .CXF), so the list reads
; as the programs available (.CXA apps, .CXD accessories) and folders,
; not the boot artifacts beside them.
; ---------------------------------------------------------------------
HIDDEN_N = 4
hidden_ext
    ldy #0                      ; Y = strlen(name)
@fn
    lda (poolp),y
    beq @got
    iny
    cpy #NAMEMAX
    bcc @fn
@got
    cpy #4                      ; shorter than a ".EXT": keep it
    bcc @no
    tya                         ; copy the last four bytes into ext4
    sec
    sbc #4
    tay
    ldx #0
@cp
    lda (poolp),y
    sta ext4,x
    iny
    inx
    cpx #4
    bne @cp
    stz he_i                    ; ext4 against each hidden suffix
@try
    lda he_i
    cmp #HIDDEN_N
    bcs @no
    asl                         ; entry base = he_i * 4
    asl
    tax
    ldy #0
@cmp
    lda hidden_tab,x
    cmp ext4,y
    bne @miss
    inx
    iny
    cpy #4
    bne @cmp
    sec                         ; all four matched: hide it
    rts
@miss
    inc he_i
    bra @try
@no
    clc
    rts

; ---------------------------------------------------------------------
; selname -- obuf = the selected entry's name with any trailing slash
; stripped; oblen = its length; A = 1 if it was a directory. The pool
; entry itself is left alone.
; ---------------------------------------------------------------------
selname
    lda wl_rec + 9              ; WG_VAL -> fptrs[2v]
    asl
    tay
    lda fptrs,y
    sta poolp
    lda fptrs+1,y
    sta poolp+1
    ldy #0
@cp
    lda (poolp),y
    sta obuf,y
    beq @end
    iny
    cpy #NAMEMAX
    bcc @cp
@end
    sty oblen
    ldy oblen                   ; strip the slash, remember it
    beq @plain
    dey
    lda obuf,y
    cmp #'/'
    bne @plain
    lda #0
    sta obuf,y
    sty oblen
    lda #1
    rts
@plain
    lda #0
    rts

; ---------------------------------------------------------------------
; dop -- send cbuf (Y = length) to the drive, show its reply, refresh.
; ---------------------------------------------------------------------
dop
    lda #<cbuf
    ldx #>cbuf
    jsr cx_dos_cmd
    lda #<mbuf                  ; the drive's words, whatever they were
    sta X16_P0
    lda #>mbuf
    sta X16_P1
    jsr cx_dos_msg
    lda #<mbuf
    ldx #>mbuf
    jsr note
    jmp refresh

; ---------------------------------------------------------------------
; the handlers
; ---------------------------------------------------------------------
on_widget                       ; an entry was activated: open it
    lda viewmode
    beq @open                   ; list view: wl_rec+9 is the selected row
    lda X16_P2                  ; icon view: only a double-click (value 1)
    bne @doopen                 ; opens; a single click (value 0) just selects
    rts
@doopen
    lda pagebase                ; the file = this page's base + the widget's
    clc                         ; index; put it where selname looks
    adc X16_P1
    sta wl_rec + 9
@open
    jsr selname
    bne @dir
    ldy oblen                   ; a ".CXD" opens OVER the desktop
    cpy #5
    bcc @app
    lda obuf-4,y
    cmp #'.'
    bne @app
    lda obuf-3,y
    cmp #'C'
    bne @app
    lda obuf-2,y
    cmp #'X'
    bne @app
    lda obuf-1,y
    cmp #'D'
    bne @app
    lda #<obuf                  ; a desk accessory: the desktop stays
    ldx #>obuf
    ldy oblen
    jsr cx_da_open
    bcc @ok
    lda #<s_noda
    ldx #>s_noda
    jmp note
@ok
    rts
@app
    lda oblen                   ; SHELL.CXA is this desktop itself --
    cmp #9                      ; launching it just reloads the same
    bne @load                   ; screen, so say what it is instead
    ldy #8
@shcmp
    lda obuf,y
    cmp s_shname,y
    bne @load
    dey
    bpl @shcmp
    lda #<s_isdesk
    ldx #>s_isdesk
    jmp note
@load
    lda depth                   ; remember which file we launched so the cx_exit
    bne @nosel                  ; back lands on it -- but only at the root, since
    lda wl_rec + 9              ; a launch from inside a folder is meaningless
    bra @savesel                ; once the desktop resets to root on reload
@nosel
    lda #$FF
@savesel
    sta CX_SHELL_SEL
    ; a file: only a CXAP comes back from this
    lda #<obuf
    ldx #>obuf
    ldy oblen
    jsr cx_app_load             ; returns only if it refused
    lda #<s_bad
    ldx #>s_bad
    jmp note
@dir                            ; a folder: go there and re-read
    lda #1                      ; the depth step: a name goes down, ".."
    sta ddelta                  ; comes back up
    lda oblen
    cmp #2
    bne @cd
    lda obuf
    cmp #'.'
    bne @cd
    lda obuf+1
    cmp #'.'
    bne @cd
    lda #$FF
    sta ddelta
@cd
    ldy #0                      ; "CD:" + name
@cdc
    lda s_cd,y
    beq @cdn
    sta cbuf,y
    iny
    bne @cdc
@cdn
    ldx #0
@cd2
    lda obuf,x
    sta cbuf,y
    beq @go
    iny
    inx
    bne @cd2
@go
    lda #<cbuf                  ; send it, and only on success does the
    ldx #>cbuf                  ; depth move -- a refused CD leaves us put
    jsr cx_dos_cmd
    php
    lda #<mbuf
    sta X16_P0
    lda #>mbuf
    sta X16_P1
    jsr cx_dos_msg
    lda #<mbuf
    ldx #>mbuf
    jsr note
    plp
    bcs @refresh
    lda depth
    clc
    adc ddelta
    sta depth
@refresh
    jmp refresh

on_menu
    lda X16_P2
    cmp #1
    beq @file
    cmp #2
    beq @theme
    cmp #3
    beq @view
    lda X16_P1                  ; menu 0: about / quit
    bne @quit
    cxm_dlg_alert dlg_about         ; a real box with an ok button, not a
    rts                         ; line that is easy to miss
@quit
    cxm_exit
@view
    lda X16_P1                  ; 0 = list, 1 = icons
    sta viewmode
    eor #1                      ; stored INVERTED (0 = the icons default),
    sta CX_SHELL_STATE          ; remembered across the next app launch
    stz iconpage                ; a view change starts at the first page
    jmp set_view
@theme
    lda X16_P1
    beq @day
    cxm_theme_set theme_night
    bra @repaint
@day
    cxm_theme_set theme_day
@repaint
    jmp cx_wg_draw
@file
    lda X16_P1                  ; the ops live pages away: jmp, not branch
    beq @fmk
    cmp #1
    beq @fnf
    cmp #2
    beq @frn
    cmp #3
    beq @fcp
    cmp #4
    beq @fdl
    rts
@fmk
    jmp do_mkdir
@fnf
    jmp do_newfile
@frn
    jmp do_rename
@fcp
    jmp do_copy
@fdl
    jmp do_delete

; ---- new folder ------------------------------------------------------
do_mkdir
    stz pbuf                    ; an empty seed
    lda #<s_mkq
    ldx #>s_mkq
    jsr ask
    bcs @out                    ; cancelled or empty
    ldy #0                      ; "MD:" + the name
@c
    lda s_md,y
    beq @n
    sta cbuf,y
    iny
    bne @c
@n
    ldx #0
@c2
    lda pbuf,x
    sta cbuf,y
    beq @send
    iny
    inx
    bne @c2
@send
    jmp dop
@out
    rts

; ---- new file --------------------------------------------------------
; An empty sequential file, created by opening "NAME,S,W" and closing
; it. Interrupts masked around the OPEN/CLOSE, the same reason the loader
; masks them -- the event IRQ must not re-enter the KERNAL mid-I/O. The
; drive's status is shown after, then the list re-reads.
do_newfile
    stz pbuf
    lda #<s_nfq
    ldx #>s_nfq
    jsr ask
    bcs @out
    ldx #0                      ; "NAME" into cbuf
@c
    lda pbuf,x
    beq @suf
    sta cbuf,x
    inx
    bne @c
@suf
    ldy #0                      ; ...then ",S,W"
@s
    lda s_sw,y
    sta cbuf,x
    beq @open
    inx
    iny
    bne @s
@open
    txa                         ; A = length (up to the NUL)
    ldx #<cbuf
    ldy #>cbuf
    jsr SETNAM
    lda #3
    ldx #8
    ldy #3                      ; secondary 3: a write channel
    jsr SETLFS
    sei                         ; do not let the IRQ re-enter the KERNAL
    jsr OPEN                    ; creates (and truncates) the file
    jsr CLRCHN
    lda #3
    jsr CLOSE
    cli
    lda #0                      ; the drive's verdict, then the list again
    tax
    tay
    jsr cx_dos_cmd
    lda #<mbuf
    sta X16_P0
    lda #>mbuf
    sta X16_P1
    jsr cx_dos_msg
    lda #<mbuf
    ldx #>mbuf
    jsr note
    jmp refresh
@out
    rts

; ---- rename ----------------------------------------------------------
do_rename
    jsr selname                 ; seed the prompt with the old name
    jsr no_dots
    bcs @out                    ; ".." is not a thing to rename
    ldy #0
@seed
    lda obuf,y
    sta pbuf,y
    beq @sn
    iny
    bne @seed
@sn
    lda #<s_rnq
    ldx #>s_rnq
    jsr ask
    bcs @out
    ldy #0                      ; "R:" + new + "=" + old
@c
    lda s_r,y
    beq @n
    sta cbuf,y
    iny
    bne @c
@n
    ldx #0
@c2
    lda pbuf,x
    beq @eq
    sta cbuf,y
    iny
    inx
    bne @c2
@eq
    lda #'='
    sta cbuf,y
    iny
    ldx #0
@c3
    lda obuf,x
    sta cbuf,y
    beq @send
    iny
    inx
    bne @c3
@send
    jmp dop
@out
    rts

; ---- copy ------------------------------------------------------------
; CMDR-DOS "C:new=old" is a syntax error on hostfs, so the copy is done
; by hand: open the source for read and the new name for write and
; stream the bytes across. Interrupts are masked around the transfer
; (the event IRQ must not re-enter the KERNAL mid-I/O, the loader
; lesson).
do_copy
    jsr selname
    jsr no_dots
    bcs @out
    ldy #0                      ; the source name is safe in obuf; ask
@save                           ; overwrites nothing of it, but keep a copy
    lda obuf,y                  ; in srcn so a later selname cannot disturb
    sta srcn,y
    beq @asked
    iny
    bne @save
@asked
    stz pbuf                    ; a fresh name for the copy
    lda #<s_cpq
    ldx #>s_cpq
    jsr ask
    bcs @out

    lda #<srcn                  ; open the source, ",S,R"
    ldx #>srcn
    jsr name_open_r
    bcs @noread

    lda #<pbuf                  ; open the destination, ",S,W"
    ldx #>pbuf
    jsr name_open_w
    bcs @nowrite

    sei                         ; stream source -> dest
@loop
    ldx #2
    jsr CHKIN
    jsr CHRIN
    sta ftype                   ; the byte (ftype is free here)
    jsr READST
    sta deldir                  ; the status
    ldx #3
    jsr CHKOUT
    lda ftype
    jsr CHROUT
    lda deldir
    and #$40                    ; EOF on the read?
    beq @loop
    jsr CLRCHN
    lda #2
    jsr CLOSE
    lda #3
    jsr CLOSE
    cli
    lda #<s_copied
    ldx #>s_copied
    jsr note
    jmp refresh
@nowrite
    lda #2                      ; the source is still open
    jsr CLOSE
@noread
    lda #<s_cpbad
    ldx #>s_cpbad
    jmp note
@out
    rts

; name_open_r -- A/X = a bare name; build "name,S,R" in cbuf and OPEN it
; as LFN 2. Carry set if OPEN refused.
name_open_r
    jsr build_name
    lda #<s_sr
    ldx #>s_sr
    jsr append_suffix           ; X = the full length
    txa
    ldx #<cbuf
    ldy #>cbuf
    jsr SETNAM
    lda #2
    ldx #8
    ldy #2
    jsr SETLFS
    jmp OPEN

; name_open_w -- A/X = a bare name; build "name,S,W" and OPEN it as LFN 3.
name_open_w
    jsr build_name
    lda #<s_sw
    ldx #>s_sw
    jsr append_suffix
    txa
    ldx #<cbuf
    ldy #>cbuf
    jsr SETNAM
    lda #3
    ldx #8
    ldy #3
    jsr SETLFS
    jmp OPEN

; build_name -- A/X = a NUL name; copy it into cbuf, cbuf_i = its length.
build_name
    sta poolp
    stx poolp+1
    ldy #0
@c
    lda (poolp),y
    beq @d
    sta cbuf,y
    iny
    bne @c
@d
    sty cbuf_i
    rts

; append_suffix -- A/X = a NUL suffix; append it (and its NUL) at cbuf_i.
; Returns X = the total length (the NUL's position).
append_suffix
    sta poolp
    stx poolp+1
    ldy #0
    ldx cbuf_i
@c
    lda (poolp),y
    sta cbuf,x
    beq @d
    inx
    iny
    bne @c
@d
    stx cbuf_i
    rts

; ---- delete ----------------------------------------------------------
; The alert's button 0 is what RETURN picks, so button 0 is "keep":
; destroying a file must be the deliberate answer, never the default.
do_delete
    jsr selname
    sta deldir                  ; 1 = a directory (RD:), 0 = a file (S:)
    jsr no_dots
    bcs @out
    ldy #0                      ; "delete " + name + "?"
@m
    lda s_delp,y
    beq @mn
    sta qbuf,y
    iny
    bne @m
@mn
    ldx #0
@m2
    lda obuf,x
    beq @mq
    sta qbuf,y
    iny
    inx
    bne @m2
@mq
    lda #'?'
    sta qbuf,y
    iny
    lda #0
    sta qbuf,y

    cxm_dlg_alert dlg_del
    cmp #1                      ; only the second button destroys
    bne @out
    ldy #0                      ; "S:" or "RD:" + name
    lda deldir
    beq @scr
    lda #'R'
    sta cbuf
    lda #'D'
    sta cbuf+1
    ldy #2
    bra @colon
@scr
    lda #'S'
    sta cbuf
    ldy #1
@colon
    lda #':'
    sta cbuf,y
    iny
    ldx #0
@c
    lda obuf,x
    sta cbuf,y
    beq @send
    iny
    inx
    bne @c
@send
    jmp dop
@out
    rts

; ask -- prompt with message A/X into pbuf; carry set if cancelled or
; left empty
ask
    pha
    lda #<pbuf
    sta X16_P0
    lda #>pbuf
    sta X16_P1
    lda #35                     ; a DOS name: up to 34 chars and the NUL
    sta X16_P2
    pla
    jsr cx_dlg_prompt
    bcs @no
    cmp #0
    beq @no
    clc
    rts
@no
    sec
    rts

; no_dots -- carry set if the selection is the "../" row (obuf = "..")
no_dots
    lda obuf
    cmp #'.'
    bne @ok
    lda obuf+1
    cmp #'.'
    bne @ok
    sec
    rts
@ok
    clc
    rts

; on_timer -- the live clock, top right of the menu bar. The KERNAL
; keeps the RTC; this draws HH:MM over a paper patch once a second.
; The bar's rule line (row 13) is left alone.
; on_timer -- "YYYY-MM-DD HH:MM" top right, once a second. The emulator
; RTC starts stopped at 2000-01-01 and only ticks once set, so the boot
; seeds it (see main); on real hardware it is already right and the seed
; is skipped.
on_timer
    jsr CLOCK_GET_DATE_TIME
    lda $02                     ; year: r0L is (year - 1900), so 100+ is
    cmp #100                    ; a 20xx date, below it a 19xx one
    bcc @c19
    sec
    sbc #100
    ldx #'2'
    ldy #'0'
    bra @yy
@c19
    ldx #'1'
    ldy #'9'
@yy
    stx tbuf
    sty tbuf+1
    jsr two_digits              ; the last two digits of the year
    stx tbuf+2
    sta tbuf+3
    lda #'-'
    sta tbuf+4
    lda $03                     ; month
    jsr two_digits
    stx tbuf+5
    sta tbuf+6
    lda #'-'
    sta tbuf+7
    lda $04                     ; day
    jsr two_digits
    stx tbuf+8
    sta tbuf+9
    lda #' '
    sta tbuf+10
    lda $05                     ; hours
    jsr two_digits
    stx tbuf+11
    sta tbuf+12
    lda #':'
    sta tbuf+13
    lda $06                     ; minutes
    jsr two_digits
    stx tbuf+14
    sta tbuf+15
    stz tbuf+16

    lda #<tbuf                  ; measure the date first, to right-align it
    ldx #>tbuf                  ; with an 8px margin (632 = 640-8), the same
    jsr cx_font_measure         ; margin the menu titles get on the left
    sec                         ; clkx = 632 - width
    lda #<632
    sbc X16_P0
    sta clkx
    lda #>632
    sbc X16_P1
    sta clkx+1

    lda #<470                   ; the patch, inside the bar. Height 10, not
    sta X16_P0                  ; 11: row 11 is the bar's rule line. Wide
    lda #>470                   ; enough to cover any right-aligned date
    sta X16_P1
    lda #1
    sta X16_P2
    stz X16_P3
    lda #<164
    sta X16_P4
    stz X16_P5
    lda #10
    sta X16_P6
    stz X16_P7
    lda #0
    jsr cx_gfx_rect

    lda clkx                    ; the date, right-aligned, row 2
    sta X16_P0
    lda clkx+1
    sta X16_P1
    lda #2
    sta X16_P2
    stz X16_P3
    lda #<tbuf
    ldx #>tbuf
    jmp cx_font_draw

two_digits                      ; A = 0-99 -> X = tens char, A = units
    ldx #'0'
@tens
    cmp #10
    bcc @units
    sbc #10
    inx
    bra @tens
@units
    adc #'0'
    rts

; seed_clock -- the emulator's RTC sits stopped at 2000-01-01 00:00:00
; until it is set, then it ticks. If it reads exactly that frozen state,
; start it at a sane date so the desktop clock moves; the control panel
; sets the real time. A hardware RTC holds a real date, fails this test,
; and is left alone.
seed_clock
    jsr CLOCK_GET_DATE_TIME
    lda $02                     ; year 2000?
    cmp #100
    bne @out
    lda $03                     ; month 1, day 1, 00:00:00?
    cmp #1
    bne @out
    lda $04
    cmp #1
    bne @out
    lda $05
    ora $06
    ora $07
    bne @out
    lda #126                    ; 2026-01-01 12:00:00 -- moving, not 00:00
    sta $02
    lda #1
    sta $03
    sta $04
    lda #12
    sta $05
    stz $06
    stz $07
    stz $08
    lda #4
    sta $09
    jmp CLOCK_SET_DATE_TIME
@out
    rts

on_key
    cxm_menu_active             ; a menu dropped -- by mouse OR keyboard?
    bne @menu                   ; yes: the cursor keys drive it, not the list
    lda X16_P1                  ; --- browsing (no menu open) ---
    cmp #$09                    ; TAB: raise the menu bar
    beq @open
    cmp #$1B                    ; ESC: leave the desktop
    beq @quit
    ldx viewmode
    beq @tolist                 ; list view: straight to the widget keys
    ; icon view: the arrows walk the grid focus (RETURN opens); only a LEFT
    ; or RIGHT that runs off the row edge falls through to turn the page.
    lda X16_P1                  ; keep the key -- the grid move clobbers X16_P*
    pha
    jsr cx_wg_key               ; carry set if it moved the focus (or opened)
    pla
    bcs @pgnone                 ; consumed by the grid
    cmp #$9D                    ; LEFT at the row edge
    beq @pgprev
    cmp #$1D                    ; RIGHT at the row edge
    beq @pgnext
    bra @pgnone
@tolist
    jsr cx_wg_key               ; UP/DOWN select, RETURN opens (list view)
    rts
@pgprev
    lda iconpage
    beq @pgnone                 ; already the first page
    dec iconpage
    jmp set_view
@pgnext
    clc                         ; a next page only if files remain past this one
    lda pagebase
    adc iw_n
    cmp fcount
    bcs @pgnone
    inc iconpage
    jmp set_view
@pgnone
    rts
@open
    cxm_menu_key CX_K_DOWN      ; feed DOWN to drop the first menu
    rts
@quit
    cxm_exit
@menu                           ; UP/DOWN move items, LEFT/RIGHT switch menus,
    lda X16_P1                  ; RETURN picks, ESC dismisses -- cx_menu_key
    cmp #$09                    ; owns the interaction while a menu is up. TAB
    bne @menukey                ; toggles back out: dismiss the menu and return
    lda #$1B                    ; to the list/icon, the same as ESC does here
@menukey
    jmp cx_menu_key

handlers                        ; NULL MOVE DOWN UP DBL KEY TIMER MENU WIDGET JOY
    .addr 0, 0, 0, 0, 0
    .addr on_key
    .addr on_timer
    .addr on_menu
    .addr on_widget
    .addr 0                     ; JOY: the table is EV_COUNT (10) vectors --
                                ; one short and a dispatched type reads a
                                ; garbage vector from whatever data follows

; ---------------------------------------------------------------------
; the menu tree and the widget list
; ---------------------------------------------------------------------
bar
    cxm_menu_bar 4
    cxm_menu s_m0, m0_items
    cxm_menu s_m1, m1_items
    cxm_menu s_m2, m2_items
    cxm_menu s_m3, m3_items
m0_items
    cxm_items 2
    cxm_item s_about_i
    cxm_item s_quit
m1_items
    cxm_items 5
    cxm_item s_newf
    cxm_item s_newfl
    cxm_item s_ren
    cxm_item s_cpy
    cxm_item s_del
m2_items
    cxm_items 2
    cxm_item s_day
    cxm_item s_night
m3_items
    cxm_items 2
    cxm_item s_list
    cxm_item s_icons

; the list-view widget. readdir patches wl_rec+10 (WG_GRP = the row count).
widgets
    cxm_wcount widgets, widgets_end
wl_rec
    cxm_wg_list2 20, 44, 400, 240, 0, fptrs, fsptrs   ; count 0 now; readdir sets it.
                                             ; fsptrs = the right-aligned size column
widgets_end:

dlg_del                         ; keep | delete -- keep is the default
    cxm_dialog 2, qbuf
    cxm_item s_keep
    cxm_item s_dodel

dlg_about                       ; one ok button
    cxm_dialog 1, s_about
    cxm_item s_ok

theme_day
    cxm_theme_rec $0FFF, $0AAA, $0555, $0000, 0, 1, 3
theme_night                     ; 0 near-black paper, 1 medium-blue
    cxm_theme_rec $0001, $0248, $0356, $0ABC, 0, 1, 3

s_marker  .byte "CXRF SHELL", $0D, 0
s_title   .byte "CXRF -- dbl-click opens (or UP/DOWN/LEFT/RIGHT+RETURN), TAB menu", 0
s_m0      .byte "CXRF", 0
s_m1      .byte "File", 0
s_m2      .byte "Themes", 0
s_m3      .byte "View", 0
s_list    .byte "list", 0
s_icons   .byte "icons", 0
s_about_i .byte "about", 0
s_quit    .byte "quit", 0
s_newf    .byte "new folder", 0
s_newfl   .byte "new file", 0
s_ren     .byte "rename", 0
s_cpy     .byte "copy", 0
s_del     .byte "delete", 0
s_day     .byte "daylight", 0
s_night   .byte "midnight", 0
s_about   .byte "CXRF -- a GEOS-inspired desktop for the X16.", 0
s_ok      .byte "ok", 0
s_bad     .byte "that is not a CXRF app.", 0
s_noda    .byte "that desk accessory would not open.", 0
s_shname  .byte "SHELL.CXA"
s_isdesk  .byte "this is the desktop -- you are already in it.", 0
s_mkq     .byte "name the new folder:", 0
s_nfq     .byte "name the new file:", 0
s_rnq     .byte "rename to:", 0
s_cpq     .byte "copy to:", 0
s_delp    .byte "delete "
          .byte 0
s_keep    .byte "keep", 0
s_dodel   .byte "delete", 0
s_cd      .byte "CD:", 0
s_home    .byte "CD://"
s_home_len = * - s_home
s_md      .byte "MD:", 0
s_r       .byte "R:", 0
s_sw      .byte ",S,W", 0
s_sr      .byte ",S,R", 0
s_copied  .byte "copied.                       ", 0
s_cpbad   .byte "copy failed.                  ", 0
pat       .byte "$"
hidden_tab .byte ".X16", ".BIN", ".PRG", ".CXF"
ext4       .res 4, 0
he_i       .byte 0

; app_icon's table: each shipped demo the desktop knows, mapped to its own
; icon. (name, NUL, icon id); a lone 0 ends it. Anything not here draws the
; generic ICON_APP, so a new app just works until it earns its own picture.
app_tab
    .byte "CALC.CXA", 0,    ICON_CALC
    .byte "CALC8.CXA", 0,   ICON_CALC
    .byte "PAINT.CXA", 0,   ICON_PAINT
    .byte "GAMELOOP.CXA", 0, ICON_GAME
    .byte "TEXT.CXA", 0,    ICON_TEXT
    .byte "BEEP.CXA", 0,    ICON_SOUND
    .byte "SPRITE.CXA", 0,  ICON_SPRITE
    .byte "TILES.CXA", 0,   ICON_TILE
    .byte "TILES8.CXA", 0,  ICON_TILE
    .byte "TILEDLG.CXA", 0, ICON_TILE
    .byte "TUI.CXA", 0,     ICON_TERM
    .byte "CPANEL.CXA", 0,  ICON_GEARS
    .byte "HELLO1.CXA", 0,  ICON_GLOBE
    .byte "HELLO2.CXA", 0,  ICON_GLOBE
    .byte "GFX8.CXA", 0,    ICON_IMAGE
    .byte 0

fcount    .byte 0
ftype     .byte 0
deldir    .byte 0
depth     .byte 0               ; folders deep from the root; 0 = home
ddelta    .byte 0               ; a pending CD's step: +1 down, -1 up
viewmode  .byte 0               ; 0 = list, 1 = icons
iconpage  .byte 0               ; the icon page on screen
restore_sel .byte $FF           ; the file index main restores focused across an
                                ; app launch; $FF = none (main clears it post-build)
focus_fidx  .byte 0             ; the file build_icons flags focused: restore_sel,
                                ; or the page's first icon when there is no restore
pagebase  .byte 0               ; the first file index of that page
iw_n      .byte 0               ; icons built on it
fidx      .byte 0               ; the file build_icons is placing
grow      .byte 0               ; the grid row/column being laid
gcol      .byte 0
cxw       .word 0               ; the running cell x / y
cy        .word 0
oblen     .byte 0
cbuf_i    .byte 0               ; build_name/append_suffix write index
tbuf      .res 17, 0            ; "YYYY-MM-DD HH:MM"
clkx      .word 0               ; the date's right-aligned x, recomputed each tick
srcn      .res NAMEMAX, 0       ; the copy's source name, kept across ask
obuf      .res NAMEMAX, 0       ; the selected name, slash stripped
pbuf      .res 36, 0            ; what the prompt collects (a 34-char name + NUL)
qbuf      .res 48, 0            ; the delete question ("delete " + 34 + "?")
cbuf      .res 80, 0            ; the DOS command ("R:new=old" = 2 names + 3)
mbuf      .res 64, 0            ; the drive's reply
fptrs     .res MAXFILES * 2, 0
ficon     .res MAXFILES, 0        ; the type icon for each listed entry
fsptrs    .res MAXFILES * 2, 0    ; the size-string pointer for each entry (the
                                  ; list's right-aligned second column; parallel
                                  ; to fptrs, null = no size shown)
iwbuf     .res 1 + MAXICON * 16, 0 ; the icon view's widget list (count + records)
pool      .res MAXFILES * NAMEMAX, 0
spool     .res MAXFILES * 6, 0    ; the size strings ("65535" + NUL, up to 6 bytes)

; --- size-column scratch (spoolp is in zero page, above) -------------
fblocks   .word 0                 ; the current entry's block count (from cx_dir_next)
fm_val    .word 0                 ; fmt_u16's working value
fm_dig    .byte 0                 ; ...the digit being emitted
fm_lead   .byte 0                 ; ...leading-zero suppression flag
fm_wi     .byte 0                 ; ...the write index into (spoolp)
