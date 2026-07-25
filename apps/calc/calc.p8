; Prog8
; =====================================================================
; CXRF :: apps/calc/calc.p8 -- CXRF Calc, the popup calculator
; =====================================================================
; A three-mode calculator that opens as a POPUP: it never clears the
; screen, it draws a framed window over whatever was there (the desktop
; stays visible around it) and hands the screen back on exit.
;
;   STD  four functions on the ROM float, percent, square root,
;        reciprocal, square, x^y and a memory (M+ MR MC MS)
;   SCI  sin cos tan, ln, log, 10^x, e^x, x^y, pi, e, DEG/RAD
;   PRG  32-bit integers in DEC / HEX / BIN with hex digit keys,
;        NOT AND OR XOR and shifts
;
; Every key is a button AND a keystroke; a click paints the button
; pressed (the toolkit's highlight fill) and releases it on mouse-up, so
; the keypad answers like the kernel's own widgets.
;
; The keypad is 7 columns x 5 rows: columns 0-2 are the digit pad,
; column 3 the arithmetic, and columns 4-6 change with the mode.
;
; This is also the "complete example" for the Prog8 SDK: the friendly
; p8sdk (`ui`, p8sdk/cxui.p8) paints buttons and pulls events; the
; generated binding (`cx`, sdk/include_prog8/cxrf.p8) is everything else.
;
;   prog8c -target cx16 -srcdirs sdk\include_prog8 -srcdirs p8sdk calc.p8
; =====================================================================

%import syslib
%import floats
%import cxrf
%import cxui
%zeropage basicsafe
%option no_sysinit      ; REQUIRED: a CXRF app is a guest -- the kernel owns
                        ; the machine (Prog8's init_system would tear out the
                        ; live kernel IRQ and video)
%zpreserved $02,$5f     ; REQUIRED: the kernel owns zp $02..$5F

main {
    ; --- the popup window -------------------------------------------
    const uword WX = 110
    const uword WY = 104
    const uword WW = 420
    const uword WH = 252

    const uword KX = WX + 14        ; the keypad origin
    const uword KY = WY + 78
    const uword KW = 50             ; a key
    const uword KH = 26
    const uword PX = 56             ; the cell pitch
    const uword PY = 32

    const uword DX = WX + 10        ; the display
    const uword DY = WY + 26
    const uword DW = WW - 20
    const uword DH = 24

    ; --- modes ------------------------------------------------------
    const ubyte M_STD = 0
    const ubyte M_SCI = 1
    const ubyte M_PRG = 2
    ubyte mode = 0

    ; --- key codes --------------------------------------------------
    ; digits and operators are their ASCII bytes (which are also the
    ; EV_KEY codes, so a keystroke and a click feed the same value);
    ; functions start at $80
    const ubyte F_SQRT = $80
    const ubyte F_RECIP= $81
    const ubyte F_SQR  = $82
    const ubyte F_POW  = $83
    const ubyte F_MPLUS= $84
    const ubyte F_MR   = $85
    const ubyte F_MC   = $86
    const ubyte F_MS   = $87
    const ubyte F_SIN  = $88
    const ubyte F_COS  = $89
    const ubyte F_TAN  = $8a
    const ubyte F_LN   = $8b
    const ubyte F_LOG  = $8c
    const ubyte F_P10  = $8d
    const ubyte F_EXP  = $8e
    const ubyte F_PI   = $8f
    const ubyte F_E    = $90
    const ubyte F_DEG  = $91
    const ubyte F_RAD  = $92
    const ubyte F_NOT  = $93
    const ubyte F_AND  = $94
    const ubyte F_OR   = $95
    const ubyte F_XOR  = $96
    const ubyte F_SHL  = $97
    const ubyte F_SHR  = $98
    const ubyte F_DEC  = $99
    const ubyte F_HEX  = $9a
    const ubyte F_BIN  = $9b
    const ubyte F_BACK = $9c        ; the <- key
    const ubyte F_NEG  = $9d        ; +/-

    ; columns 0-3, rows 0-4: the shared pad (row-major, 4 wide)
    ubyte[20] pad_key = [$43,  $9c,  $9d,  $2f,
                         $37,  $38,  $39,  $2a,
                         $34,  $35,  $36,  $2d,
                         $31,  $32,  $33,  $2b,
                         $30,  $2e,  $3d,  $25]
    uword[20] pad_lab = [0, 0, 0, 0,  0, 0, 0, 0,  0, 0, 0, 0,
                         0, 0, 0, 0,  0, 0, 0, 0]

    ; columns 4-6, rows 0-4: 15 slots that follow the mode
    ubyte[15] fn_std = [$80, $81, $82,
                        $84, $85, $86,
                        $87, $83, 0,
                        0,   0,   0,
                        0,   0,   0]
    ubyte[15] fn_sci = [$88, $89, $8a,
                        $8b, $8c, $8d,
                        $8e, $83, $80,
                        $8f, $90, $81,
                        $91, $92, $82]
    ubyte[15] fn_prg = [$93, $94, $95,
                        $96, $97, $98,
                        $99, $9a, $9b,
                        $41, $42, $43,
                        $44, $45, $46]
    uword[15] lb_std = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    uword[15] lb_sci = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    uword[15] lb_prg = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]

    ; --- float state (STD / SCI) ------------------------------------
    float acc
    float cur
    float frac
    float mem
    ubyte op
    ubyte typing
    ubyte err
    ubyte degmode = 1               ; 1 = degrees, 0 = radians

    ; --- integer state (PRG) ----------------------------------------
    long iacc
    long icur
    ubyte iop
    ubyte ityping
    ubyte base = 10

    uword note
    ubyte press = 255               ; the key drawn pressed, 255 = none

    ; --- labels ------------------------------------------------------
    str s_title = iso:"calc"
    str s_std = iso:"STD"
    str s_sci = iso:"SCI"
    str s_prg = iso:"PRG"
    str s_close = iso:"close"
    str s_c = iso:"C"
    str s_back = iso:"<-"
    str s_neg = iso:"+/-"
    str s_div = iso:"/"
    str s_mul = iso:"*"
    str s_sub = iso:"-"
    str s_add = iso:"+"
    str s_pct = iso:"%"
    str s_eq  = iso:"="
    str s_dot = iso:"."
    str s_0 = iso:"0"
    str s_1 = iso:"1"
    str s_2 = iso:"2"
    str s_3 = iso:"3"
    str s_4 = iso:"4"
    str s_5 = iso:"5"
    str s_6 = iso:"6"
    str s_7 = iso:"7"
    str s_8 = iso:"8"
    str s_9 = iso:"9"
    str s_sqrt = iso:"sqrt"
    str s_recip = iso:"1/x"
    str s_sqr = iso:"x2"
    str s_pow = iso:"x^y"
    str s_mplus = iso:"M+"
    str s_mr = iso:"MR"
    str s_mc = iso:"MC"
    str s_ms = iso:"MS"
    str s_sin = iso:"sin"
    str s_cos = iso:"cos"
    str s_tan = iso:"tan"
    str s_ln = iso:"ln"
    str s_log = iso:"log"
    str s_p10 = iso:"10^x"
    str s_exp = iso:"e^x"
    str s_pi = iso:"pi"
    str s_e = iso:"e"
    str s_deg = iso:"DEG"
    str s_rad = iso:"RAD"
    str s_not = iso:"NOT"
    str s_and = iso:"AND"
    str s_or = iso:"OR"
    str s_xor = iso:"XOR"
    str s_shl = iso:"<<"
    str s_shr = iso:">>"
    str s_dec = iso:"DEC"
    str s_hex = iso:"HEX"
    str s_bin = iso:"BIN"
    str s_ha = iso:"A"
    str s_hb = iso:"B"
    str s_hc = iso:"C"
    str s_hd = iso:"D"
    str s_he = iso:"E"
    str s_hf = iso:"F"
    str s_hint = iso:"TAB mode   ESC close"
    str s_dz = iso:"divide by zero -- C clears"
    str s_dom = iso:"out of range -- C clears"
    str s_mem = iso:"memory"

    ubyte[14] numbuf                ; hex / binary rendering
    ubyte[14] tmpbuf

    ; the label tables are filled at start: Prog8 array initialisers
    ; cannot hold string addresses, so they are assigned once here
    ; the label tables are filled here: a Prog8 array initialiser
    ; cannot hold string addresses, so they are assigned once at start
    sub labels_init() {
        pad_lab[0] = &s_c
        pad_lab[1] = &s_back
        pad_lab[2] = &s_neg
        pad_lab[3] = &s_div
        pad_lab[4] = &s_7
        pad_lab[5] = &s_8
        pad_lab[6] = &s_9
        pad_lab[7] = &s_mul
        pad_lab[8] = &s_4
        pad_lab[9] = &s_5
        pad_lab[10] = &s_6
        pad_lab[11] = &s_sub
        pad_lab[12] = &s_1
        pad_lab[13] = &s_2
        pad_lab[14] = &s_3
        pad_lab[15] = &s_add
        pad_lab[16] = &s_0
        pad_lab[17] = &s_dot
        pad_lab[18] = &s_eq
        pad_lab[19] = &s_pct
        lb_std[0] = &s_sqrt
        lb_std[1] = &s_recip
        lb_std[2] = &s_sqr
        lb_std[3] = &s_mplus
        lb_std[4] = &s_mr
        lb_std[5] = &s_mc
        lb_std[6] = &s_ms
        lb_std[7] = &s_pow
        lb_sci[0] = &s_sin
        lb_sci[1] = &s_cos
        lb_sci[2] = &s_tan
        lb_sci[3] = &s_ln
        lb_sci[4] = &s_log
        lb_sci[5] = &s_p10
        lb_sci[6] = &s_exp
        lb_sci[7] = &s_pow
        lb_sci[8] = &s_sqrt
        lb_sci[9] = &s_pi
        lb_sci[10] = &s_e
        lb_sci[11] = &s_recip
        lb_sci[12] = &s_deg
        lb_sci[13] = &s_rad
        lb_sci[14] = &s_sqr
        lb_prg[0] = &s_not
        lb_prg[1] = &s_and
        lb_prg[2] = &s_or
        lb_prg[3] = &s_xor
        lb_prg[4] = &s_shl
        lb_prg[5] = &s_shr
        lb_prg[6] = &s_dec
        lb_prg[7] = &s_hex
        lb_prg[8] = &s_bin
        lb_prg[9] = &s_ha
        lb_prg[10] = &s_hb
        lb_prg[11] = &s_hc
        lb_prg[12] = &s_hd
        lb_prg[13] = &s_he
        lb_prg[14] = &s_hf
    }

    sub start() {
        ; the markers go out in TEXT mode, BEFORE any drawing
        emit(&m_up)
        if selftest()
            emit(&m_ok)

        labels_init()

        ; NB: no gfx_clear anywhere -- this is a popup. gfx_init only
        ; programs the mode, so the desktop's pixels stay around the
        ; window and the shell repaints itself after cx.exit().
        cx.gfx_init()
        cx.ev_init()
        cx.mouse_show(1)
        draw_window()

        repeat {
            if ui.poll() {
                if ui.etype == cx.ET_KEY {
                    if ui.detail == cx.K_ESC
                        cx.exit()
                    if ui.detail == $09 {           ; TAB cycles the mode
                        mode++
                        if mode > 2
                            mode = 0
                        draw_window()
                    } else {
                        feed(ui.detail)
                    }
                } else if ui.etype == cx.ET_DOWN {
                    click(ui.mx, ui.my)
                } else if ui.etype == cx.ET_UP {
                    release()
                }
            }
        }
    }

    ; =================================================================
    ; drawing
    ; =================================================================
    sub draw_window() {
        cx.gfx_rect(WX, WY, WW, WH, cx.PAPER)
        cx.gfx_frame(WX, WY, WW, WH, cx.FRAME)
        cx.gfx_rect(WX + 1, WY + 1, WW - 2, 20, cx.HI)      ; the title bar
        void cx.say(&s_title, WX + 8, WY + 7)
        ui.button(WX + 60,  WY + 3, 44, 16, &s_std)
        ui.button(WX + 108, WY + 3, 44, 16, &s_sci)
        ui.button(WX + 156, WY + 3, 44, 16, &s_prg)
        ui.button(WX + WW - 74, WY + 3, 66, 16, &s_close)
        ; the active mode, underlined
        uword ux = WX + 60 + (mode as uword) * 48
        cx.gfx_rect(ux, WY + 21, 44, 2, cx.FRAME)
        cx.gfx_frame(DX, DY, DW, DH, cx.FRAME)
        void cx.say(&s_hint, WX + 10, WY + WH - 14)
        draw_keys()
        show()
    }

    sub draw_keys() {
        ubyte i
        for i in 0 to 34 {
            if key_at(i) != 0
                paint_key(i, 0)
        }
    }

    ; paint key i normal (pressed = 0) or pressed (1): the click feedback
    sub paint_key(ubyte i, ubyte pressed) {
        uword col = (i % 7) as uword
        uword row = (i / 7) as uword
        uword bx = KX + col * PX
        uword by = KY + row * PY
        uword lab = lab_at(i)
        if lab == 0
            return
        if pressed != 0 {
            cx.gfx_rect(bx, by, KW, KH, cx.HI)
            cx.gfx_frame(bx, by, KW, KH, cx.FRAME)
            uword tw = cx.font_measure(lab)
            void cx.say(lab, bx + (KW - tw) / 2, by + 9)
        } else {
            ui.button(bx, by, KW, KH, lab)
        }
    }

    sub key_at(ubyte i) -> ubyte {
        ubyte col = i % 7
        ubyte row = i / 7
        if col < 4
            return pad_key[row * 4 + col]
        ubyte fi = row * 3 + (col - 4)
        if mode == 0
            return fn_std[fi]
        if mode == 1
            return fn_sci[fi]
        return fn_prg[fi]
    }

    sub lab_at(ubyte i) -> uword {
        ubyte col = i % 7
        ubyte row = i / 7
        if col < 4
            return pad_lab[row * 4 + col]
        ubyte fi = row * 3 + (col - 4)
        if mode == 0
            return lb_std[fi]
        if mode == 1
            return lb_sci[fi]
        return lb_prg[fi]
    }

    ; the display line, plus the status line under it
    sub show() {
        cx.gfx_rect(DX + 2, DY + 2, DW - 4, DH - 4, cx.PAPER)
        if err == 0 {
            if mode == 2 {
                void cx.say(int_str(), DX + 8, DY + 8)
            } else {
                void cx.say(floats.tostr(display_value()), DX + 8, DY + 8)
            }
        }
        cx.gfx_rect(WX + 10, DY + DH + 4, WW - 20, 12, cx.PAPER)
        if note != 0 {
            void cx.say(note, WX + 10, DY + DH + 4)
        } else if mode == 1 {
            if degmode != 0
                void cx.say(&s_deg, WX + 10, DY + DH + 4)
            else
                void cx.say(&s_rad, WX + 10, DY + DH + 4)
        } else if mode == 2 {
            if base == 16
                void cx.say(&s_hex, WX + 10, DY + DH + 4)
            else if base == 2
                void cx.say(&s_bin, WX + 10, DY + DH + 4)
            else
                void cx.say(&s_dec, WX + 10, DY + DH + 4)
        }
        note = 0
    }

    sub display_value() -> float {
        if typing != 0
            return cur
        return acc
    }

    sub display_int() -> long {
        if ityping != 0
            return icur
        return iacc
    }

    ; the integer display, in the current base
    sub int_str() -> uword {
        long v = display_int()
        ubyte neg = 0
        if v < 0 {
            neg = 1
            v = -v
        }
        if base == 10 {
            ; a plain decimal through the float printer -- exact at these
            ; magnitudes, and the library has no long-to-string
            float f = v as float
            if neg != 0
                f = -f
            return floats.tostr(f)
        }
        ubyte bits = 4
        if base == 2
            bits = 1
        if v == 0 {
            numbuf[0] = $30
            numbuf[1] = 0
            return &numbuf
        }
        ubyte n = 0
        while v != 0 and n < 12 {
            ubyte d = lsb(v) & 15
            if bits == 1
                d = lsb(v) & 1
            if d < 10
                tmpbuf[n] = $30 + d
            else
                tmpbuf[n] = $37 + d         ; 'A'..'F'
            v >>= bits
            n++
        }
        ubyte j = 0
        if neg != 0 {
            numbuf[0] = $2d
            j = 1
        }
        while n != 0 {
            n--
            numbuf[j] = tmpbuf[n]
            j++
        }
        numbuf[j] = 0
        return &numbuf
    }

    ; =================================================================
    ; the float engine (STD / SCI)
    ; =================================================================
    sub apply() {
        when op {
            $2b -> acc += cur
            $2d -> acc -= cur
            $2a -> acc *= cur
            $2f -> {
                if cur == 0.0 {
                    err = 1
                    note = &s_dz
                    return
                }
                acc /= cur
            }
            $83 -> acc = floats.pow(acc, cur)
            else -> acc = cur
        }
        cur = 0.0
        frac = 0.0
        typing = 0
    }

    sub to_rad(float v) -> float {
        if degmode != 0
            return v * 0.017453293
        return v
    }

    ; a one-argument function on whatever is displayed
    sub unary(ubyte f) {
        float v = display_value()
        when f {
            $80 -> {                        ; sqrt
                if v < 0.0 {
                    err = 1
                    note = &s_dom
                    return
                }
                v = sqrt(v)
            }
            $81 -> {                        ; 1/x
                if v == 0.0 {
                    err = 1
                    note = &s_dz
                    return
                }
                v = 1.0 / v
            }
            $82 -> v = v * v                ; x2
            $9d -> v = -v                   ; +/-
            $88 -> v = floats.sin(to_rad(v))
            $89 -> v = floats.cos(to_rad(v))
            $8a -> v = floats.tan(to_rad(v))
            $8b -> {                        ; ln
                if v <= 0.0 {
                    err = 1
                    note = &s_dom
                    return
                }
                v = floats.ln(v)
            }
            $8c -> {                        ; log10
                if v <= 0.0 {
                    err = 1
                    note = &s_dom
                    return
                }
                v = floats.ln(v) / 2.302585093
            }
            $8e -> v = floats.pow(2.718281828, v)   ; e^x
            $8d -> v = floats.pow(10.0, v)          ; 10^x
            else -> return
        }
        acc = v
        cur = 0.0
        frac = 0.0
        typing = 0
    }

    sub feed_float(ubyte c) {
        if err != 0 and c != $43 and c != $63
            return
        if c >= $30 and c <= $39 {
            float digit = (c - $30) as float
            if frac == 0.0 {
                cur = cur * 10.0 + digit
            } else {
                cur += digit * frac
                frac *= 0.1
            }
            typing = 1
        } else if c == $2e {
            if frac == 0.0
                frac = 0.1
            typing = 1
        } else if c == $2b or c == $2d or c == $2a or c == $2f or c == $83 {
            if typing != 0
                apply()
            if err == 0
                op = c
        } else if c == $3d or c == $0d {
            if op != 0 or typing != 0
                apply()
            op = 0
        } else if c == $25 {                        ; percent
            acc = display_value() / 100.0
            cur = 0.0
            frac = 0.0
            typing = 0
        } else if c == $9c {                        ; backspace
            cur = floats.floor(cur / 10.0)
            frac = 0.0
            typing = 1
        } else if c == $43 or c == $63 {            ; clear
            acc = 0.0
            cur = 0.0
            frac = 0.0
            op = 0
            typing = 0
            err = 0
        } else if c == $8f {
            acc = 3.141592654
            typing = 0
        } else if c == $90 {
            acc = 2.718281828
            typing = 0
        } else if c == $91 {
            degmode = 1
        } else if c == $92 {
            degmode = 0
        } else if c == $84 {                        ; M+
            mem += display_value()
            note = &s_mem
        } else if c == $87 {                        ; MS
            mem = display_value()
            note = &s_mem
        } else if c == $85 {                        ; MR
            acc = mem
            cur = 0.0
            typing = 0
        } else if c == $86 {                        ; MC
            mem = 0.0
            note = &s_mem
        } else {
            unary(c)
        }
        show()
    }

    ; =================================================================
    ; the integer engine (PRG)
    ; =================================================================
    sub iapply() {
        when iop {
            $2b -> iacc += icur
            $2d -> iacc -= icur
            $2a -> iacc *= icur
            $2f -> {
                if icur == 0 {
                    err = 1
                    note = &s_dz
                    return
                }
                iacc /= icur
            }
            $94 -> iacc &= icur
            $95 -> iacc |= icur
            $96 -> iacc ^= icur
            $97 -> {
                ubyte sh = lsb(icur) & 31
                repeat sh
                    iacc <<= 1
            }
            $98 -> {
                ubyte sh2 = lsb(icur) & 31
                repeat sh2
                    iacc >>= 1
            }
            else -> iacc = icur
        }
        icur = 0
        ityping = 0
    }

    sub feed_int(ubyte c) {
        ubyte d = 255
        if c >= $30 and c <= $39
            d = c - $30
        else if c >= $61 and c <= $66
            d = c - $57                     ; a-f
        else if c >= $41 and c <= $46 and c != $43
            d = c - $37                     ; A,B,D,E,F ('C' is clear)

        if err != 0 and c != $43 and c != $63
            return

        if d != 255 {
            if d < base {
                icur = icur * (base as long) + (d as long)
                ityping = 1
            }
        } else if c == $2b or c == $2d or c == $2a or c == $2f or
                  c == $94 or c == $95 or c == $96 or c == $97 or c == $98 {
            if ityping != 0
                iapply()
            if err == 0
                iop = c
        } else if c == $3d or c == $0d {
            if iop != 0 or ityping != 0
                iapply()
            iop = 0
        } else if c == $93 {                        ; NOT
            iacc = display_int() ^ -1
            icur = 0
            ityping = 0
        } else if c == $9d {                        ; +/-
            iacc = -display_int()
            icur = 0
            ityping = 0
        } else if c == $9c {                        ; backspace
            icur /= (base as long)
            ityping = 1
        } else if c == $43 or c == $63 {            ; clear
            iacc = 0
            icur = 0
            iop = 0
            ityping = 0
            err = 0
        } else if c == $99 {
            base = 10
        } else if c == $9a {
            base = 16
        } else if c == $9b {
            base = 2
        }
        show()
    }

    sub feed(ubyte c) {
        if mode == 2
            feed_int(c)
        else
            feed_float(c)
    }

    ; =================================================================
    ; the mouse
    ; =================================================================
    sub click(uword ex, uword ey) {
        ; the title bar: the mode buttons and close
        if ey >= WY + 3 and ey < WY + 19 {
            if ex >= WX + WW - 74 and ex < WX + WW - 8
                cx.exit()
            if ex >= WX + 60 and ex < WX + 104 {
                mode = 0
                draw_window()
            } else if ex >= WX + 108 and ex < WX + 152 {
                mode = 1
                draw_window()
            } else if ex >= WX + 156 and ex < WX + 200 {
                mode = 2
                draw_window()
            }
            return
        }
        if ex < KX or ey < KY
            return
        uword dx = ex - KX
        uword dy = ey - KY
        ubyte col = (dx / PX) as ubyte
        ubyte row = (dy / PY) as ubyte
        if col > 6 or row > 4
            return
        if dx % PX >= KW or dy % PY >= KH
            return
        ubyte i = row * 7 + col
        ubyte code = key_at(i)
        if code == 0
            return
        press = i                       ; the click feedback: pressed now,
        paint_key(i, 1)                 ; released on the mouse-up
        feed(code)
    }

    sub release() {
        if press == 255
            return
        paint_key(press, 0)
        press = 255
    }

    ; =================================================================
    ; a headless proof the maths work, before any drawing
    ; =================================================================
    sub selftest() -> bool {
        bool ok = true
        acc = 2.0
        op = $2b
        cur = 3.0
        apply()
        if acc != 5.0
            ok = false
        iacc = 12
        iop = $94                       ; 12 AND 10 = 8
        icur = 10
        iapply()
        if iacc != 8
            ok = false
        acc = 0.0
        cur = 0.0
        frac = 0.0
        op = 0
        typing = 0
        err = 0
        iacc = 0
        icur = 0
        iop = 0
        ityping = 0
        return ok
    }

    ubyte[] m_up = [$43,$41,$4c,$43,$20,$50,$38,$20,$55,$50,$0d,0]
    ubyte[] m_ok = [$43,$41,$4c,$43,$20,$50,$38,$20,$4f,$4b,$0d,0]

    sub emit(uword ptr) {
        ubyte b = @(ptr)
        while b != 0 {
            cbm.CHROUT(b)
            ptr++
            b = @(ptr)
        }
    }
}
