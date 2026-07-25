# The graphics port — pluggable video modes

The resident kernel contains **no graphics engine**. It contains a *port*:
a fixed region of resident RAM whose first bytes are an entry vector, and
a small manager that copies **engine images** into it. Which engine
answers the drawing ABI is a runtime choice — `cx_gfx_mode` — and adding
a new mode never moves a slot, changes a signature, or touches an app.

## The pieces

| piece | where | what |
|---|---|---|
| the region (`OVL`) | `$9600`–`$9EFF` resident RAM (`kernel.cfg`, `CX_OVL` in `kernel/video/ovl.inc`) | 2,304 bytes the current engine occupies |
| the entry vector | the region's first 42 bytes | 14 × `jmp`, one per gfx slot, in slot order: init, clear, pset, read, hline, vline, rect, frame, line, pattern set, pattern rect, blit, masked blit, **text**. The 14th (text) is `cx_say`: mode 0 points it at the CXF font, text mode at its cell writer, the rest refuse — so `cx_say` is mode-aware through the port, not a special case. One byte of ENGINE state follows at `CX_OVL+42`: `cxov_ink`, the text ink `cx_ink` sets — it rides the image, so every mode entry resets it to that mode's default and a value never leaks across a switch |
| an engine image | an ld65 overlay segment: `run = OVL`, `load =` a kernel bank | the vector + the engine + any argument adapters |
| the manager | `kernel/video/engine0.asm` (resident) | `cx_ov_load` copies image *n* from `cx_mbank[n]` / `cx_msrc[n]` (interrupts masked); `cx_gfx_mode` = copy + the new engine's init; `cx_gfx_init` **forces mode 0**, so `cx_exit` → shell always restores the desktop |
| the canvas facts | `cx_gfx_info` (slot 77), `cx_cur_w/h` | mode, width, height, bpp, stride — how client code adapts without naming engines |

The gfx ABI slots (2–14) target the vector's constants forever. Two gates
in `engine0.asm` guard the callers that assume a particular canvas. The
**CXF fonts and desk accessories** pass through `gui_gate`: in mode 0 the
call proceeds; in any other mode it **refuses with carry** rather than blit
a 2bpp glyph into another mode's picture. The **toolkit** (menus, widgets,
dialogs, `cx_panel`) draws through the port instead, so it passes through
`menu_gate` — which allows modes 0, 1 and 3, and mode 2 (tiles) while the
tile-text overlay (`cx_txtport`) owns the port, refusing plain tiles.
Internal kernel callers use the routines directly and pay nothing — there
is no dispatch tax on the hot path.

## The modes today

`cx_gfx_mode` takes **two** arguments: `A` = the mode, `X` = the bit depth
(`0`/`2`/`4`/`8`; `0` = the mode's native depth). A mode with more than one
depth is more than one engine image behind the same mode number — the depth
picks which image loads. An old caller that sets only `A` (`X` = 0 or left
alone) always lands the native image, so the slot is unchanged. The image
that actually rides the port is tracked separately from the mode
(`cx_veng` vs `cx_vmode`), and `cx_gfx_info` reports the live depth/stride.

| mode | canvas | engine | image (bank) | notes |
|---|---|---|---|---|
| 0 `CX_MODE_BMPHIGH` | 640×480: stride 160 (2bpp) / VERA_2 (4/8bpp) | x16lib `bitmap2h` (2bpp) · `bitmap4h`/`bitmap8h` (VERA_2) | 3 (2bpp) · 4 (4bpp, 8bpp) | the **640×480 umbrella**. `X`=2 (native) is the 4-colour desktop on standard VERA (`OV0`, `bitmap2h`; all entries native, text = the CXF font — this is the old `CX_MODE_GUI`). `X`=4 (16 colours) and `X`=8 (256) light up the **VERA_2** second plane (the MiSTer core's SDRAM bitmap layer, `$9F60`–`$9F6F`; the emulator wants `-bitmap2`, else it renders white). The VERA_2 depths keep their own framebuffer, registers and palette (`gfx*h_pal_*`, **not** `cx_pal_set`); `cx_ov_load` turns VERA_2 off on every swap, so switching back to `X`=2 restores the desktop. Direct JMP vector for the `gfx*h` modules (ABI-native); at 4/8bpp text and the save-under refuse |
| 1 `CX_MODE_BMPLOW` | 320×240, stride 320/160/80 | x16lib `bitmap8l` / `bitmap4l` / `bitmap2l` | 4 (8bpp) · 3 (4bpp, 2bpp) | **three depths** shown fullscreen (2:1): `X`=8 (256 colours, native), `X`=4 (16), `X`=2 (4). 8bpp has thin adapters (colour A→P3, line operands), pattern bg/fg as full bytes in P4/P5, blit widths in pixels, and **text works** (8×8 charset glyphs from VRAM `$1F000` in the `cx_ink` colour). The 4bpp/2bpp images carry the 13 drawing entries and refuse text and the save-under (colours come from the default VERA palette) |
| 2 `CX_MODE_TILE` | 320×240, two 64×32 tile maps | refusal vector + real init | 5 (shared, via `__OV2CODE_LOAD__`) | bitmap entries refuse (a map is not a bitmap); the API is `cx_tile_*` (slots 81–84 and 101–104, plus `cx_vram_stream`/`cx_tile_load`); tiles at VRAM `$00000`, maps `$10000`/`$11000`. `X` here is the **default tile depth** `cx_tile_setup(layer, 0)` adopts (`cx_mode(CX_MODE_TILE, 8)` then a `0`-bpp setup = an 8bpp layer) |
| 3 `CX_MODE_TEXT` | text cells, 16 colours — **any KERNAL geometry**: `X` = a `screen_mode` code (`$00`–`$0B`: 80×60 default, 80×30, 40×60, 40×30, 40×15, 20×30, 20×15, 22×23, 64×50, 64×25, 32×50, 32×25; an unknown code lands 80×60). `ov3_init` publishes the live grid in `cx_minfo`, so `cx_gfx_info`, the canvas bounds and the mouse field all follow; the toolkit (menus, dialogs, panels) wants ≥ 64 cols × 25 rows — on narrower grids apps draw their own cell UI. Changing geometry while already in mode 3 reloads + reinits the image (same geometry stays a no-op) | KERNAL console (`screen.asm`), **all in the overlay** | 5 (shared, via `__OV3CODE_LOAD__`) | a CELL grid, not pixels: clear/rect fill cells with a colour (and set the "paper" later drawing sits on); **frame is a real box in the PETSCII frame glyphs** (┌ ┐ └ ┘ ─ │: codes `$B0 $AE $AD $BD $C0 $DD`); hline/vline are ruled lines; **line works for horizontal/vertical runs** and refuses diagonals; `cx_say` prints ASCII at (col,row), letters mapped to the PETSCII upper/lower charset so the case on screen is the case in the string. pset/read/pattern/blit refuse. Runs in the overlay (low RAM), not a bank, because the KERNAL screen routines do not preserve `RAM_BANK` and would corrupt banked code. Init is `CINT` (a full reset — `screen_set_mode` alone left the text layer dark) then the `CHR$(14)` switch out of ISO (the X16 default, whose charset has no box glyphs) |

**Mode-agnostic by construction:** events, audio, sprites, PCM, files,
clipboard, joysticks — and the *shapes* (slots 78–80, ellipses 85–86):
circle, disc, ellipse, filled ellipse and flood are one copy of code in
bank 5 drawing **through the vector itself**, with bounds from
`cx_cur_w/h`, so they are correct in every bitmap mode automatically.

**The toolkit through the port:** the menu, widgets and dialogs draw
through the port vector (not the mode-0 engine's labels), measure text
through a 15th `measure` entry, and save what a transient element covers
through `rsave`/`rrest` entries — so the same toolkit code lays out in
any mode's units. The per-mode geometry (bar height, row height, the
insets, the title air) rides each engine image as nine metric bytes
after the ink; the frame thicknesses are "one unit" in every mode and
stay literal.

The **menu, dialogs and widgets** all cross: `menu_gate` admits their
slots to every mode that has a framebuffer — mode 0 (the desktop), mode
1 (the 320×240 8bpp bitmap) and mode 3 (the text TUI); only tiles
(mode 2) refuse. None of them carries a mode-branch in its logic — only
the drawing goes through the port.

- **Menu** — the bar, drop-downs as framed PETSCII boxes, items in
  cells, reverse-video highlights. Laid out from the port metrics
  (`cxov_m_*`): the pixel row pitch becomes a cell pitch, the screen
  bounds become `cx_cur_w/h`.
- **Dialogs** (alert + prompt) — a centred box, so the origin derives
  from `cx_cur_w/h` and a per-mode size; message, framed buttons, and
  the prompt's field editor in cells. mode-0 metrics reproduce the old
  fixed 120,192,400,96 exactly, so the desktop dialog is unchanged.
- **Widgets** — ASCII-classic in text mode (`[X]`/`[ ]`, `(*)`/`( )`,
  `[button]`, `[field]`, list rows), since a pixel marker has no cell
  equivalent; the graphical painters still serve mode 0. The text
  painter rides bank 5 (bank 2, the toolkit's bank, was full) and
  `wg_paint` far-calls it.

Highlights stay legible because the toolkit sets `cxov_ink` to the
contrasting theme role before each label — the bitmap engines' fonts and
mode 3's text writer honour it, and mode 0's proportional font inks from
the theme instead, so the desktop is unchanged. Save-unders go through
the port too: mode 0 to banks 14–15 (pixel rows), mode 1 to a VRAM strip
(fx_copy), mode 3 to a bank of text cells. The pointer is always in
640×480 space, so `ev_do_mouse` shifts it down to each mode's units
(mode 1 `>>1`, mode 3 `>>3`), and clicks land on the same box the widgets
were pushed with — keyboard and mouse both drive every mode.

**Still mode-0-only:** fonts (`cx_font_set`/`style`) and desk
accessories. Tiles (mode 2) refuse the whole toolkit — a map is not a
framebuffer. A mistaken call there refuses with carry, a clean no-op,
not a crash. Text in tile mode is font *tiles* (`cx_tile_cell` with a
glyph's tile index), the classic approach.

## How to add mode N

1. **Write the engine image**: a new `OVnCODE` overlay segment (`run =`
   a new `OVLn` area, `load =` a bank with room). First bytes: the
   17-entry vector (13 drawing + text + measure + rsave/rrest),
   `.assert`ed at `CX_OVL`, then the `cxov_ink` byte and the UI metrics.
   Entries the engine can't honour refuse (`sec`+`rts`, e.g. `ovlo_refuse`)
   or no-op (`clc`+`rts`). Include real code + adapters after it. Keep the
   image ≤ `CX_OVL_SIZE`.
2. **Register it**: an entry each in `cx_mbank`, `cx_msrc_lo/hi`, and the
   `cx_minfo` table (w, h, bpp, stride), indexed by **engine image**, in
   `engine0.asm`. If the mode has more than one depth, map (mode, bpp) →
   image index in `cx_eng_index`; a mode with one image keeps index ==
   mode. `cx_vmode` is the mode the app asked for; `cx_veng` is the image
   in the port (they differ for the bpp variants and OV3T).
3. **Mode-specific calls**, if any: append-only ABI slots far-called into
   bank code, guarded on `cx_vmode` (the tile slots are the template).
4. **csdk**: a `CX_MODE_x` constant; wrappers for any new slots.
5. **Docs**: a row in the table above; guide sections.

Nothing else changes: not the jump table, not the slots' numbers, not the
toolkit, not one existing app. That property was proven repeatedly — modes
1, 2, and 4, plus the mode-1 4/2bpp and mode-4 4/8bpp depths, were all
added after mode 0 shipped, and the frozen canary binary still draws.

## Budget notes

Resident cost of the whole port: the manager (~260 bytes) — the region
itself replaced the engine that used to live in resident RAM. Engine
images ride banks 3–5: bank 3 = mode 0 **plus the mode-1 4bpp/2bpp images**
(OV4L/OV2L), bank 4 = mode 1 8bpp **plus the mode-4 VERA_2 images**
(OV4H/OV8H), bank 5 = the mode-2 and mode-3 images beside the dialog code.
The mode-agnostic shapes and the tile *machinery* live in bank 17 since the
restructure, but the tile *image* (OV2) stays in bank 5 storage —
`cx_ov_load` reads it from the linker's `__OV2CODE_LOAD__`.

**The per-file four-bank ceiling.** The boot's KERNAL LOAD of a banked
file wraps exactly **four banks (32 KB)** and then stops — a fifth gets
nothing. `CXBANKS.BIN` fills banks 2–5 that way; `CXBANKS2.BIN` a second
LOAD fills 16–19 (kernel/boot/auto.asm). Mode 3 was first parked in bank
6 and crashed to the monitor for exactly this reason (`$9601`, blown
stack: the copy pulled `$FF` from an unloaded bank). A new engine image
shares an existing storage bank (3/4/5 stack several images each); the
tighter limit is the OVL window it *runs* in — 2,304 B, and the mode-0
image (the largest) is already ~2,004. The new bitmap images fit under it
(OV4L 1,705 · OV2L 1,997 · OV4H 1,744 · OV8H 1,539). See
[banks.md](banks.md) for the bank ledger.
