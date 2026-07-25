# CXRF Paint

A native paint program for the CXRF desktop — 320×240 in 256 colours
(`CX_MODE_BMPLOW` at 8bpp), written from scratch against the CXRF ABI
and feature-matched to the community's cx16paint (whose feature list
served as the spec; no code was taken — it carries no license).

## Tools

The **left button paints** with colour 1, the **middle button erases**,
and the **right button opens the menu** — so `x` swaps the two paint
colours when you want colour 2. Every tool has a hotkey, live from the
canvas or inside the menu:

| key | tool |
|---|---|
| `w` | freehand draw (strokes joined with lines — no gaps on fast drags) |
| `l` | line (press, drag, release) |
| `r` | rectangle outline · `b` filled box |
| `c` | circle outline · `d` filled disc (press at the centre, drag the radius) |
| `e` | erase (9×9 stamp) |
| `f` | flood fill (the kernel's `cx_flood`) |
| `a` | **text**: click to place the pen, then type into the picture (Backspace corrects, Enter or Esc finishes; the whole run is one undo step) |

## Commands

| key | command |
|---|---|
| TAB / Esc | toggle the menu band (tools, commands, colour swatches) |
| `t` | the **palette picker**: a 16×16 grid of all 256 colours — left click sets colour 1, right click colour 2 |
| `u` | **undo** (one level — every stroke, shape, fill, clear and load is one step) |
| `n` | new (clear the canvas — undoable) |
| `s` / `o` | **save / open a BMX image** (v1, 8bpp — the community standard; type the filename, Enter; Esc cancels) |
| `q` | quit, back to the desktop |

The palette boots as: entries 0–15 the VERA defaults, 16–31 a gray
ramp, 32–255 an 8×7×4 RGB cube. A loaded BMX replaces the palette with
the file's own. Saves include the live palette, so files round-trip
exactly (a RAM shadow tracks every palette write — VERA palette RAM
does not read back reliably).

## Implementation notes

Immediate-mode: raw `cx_poll` events, own hit-testing, drawing through
the ABI. Bulk pixel work streams through VERA's data port with
interrupts masked: the undo snapshot rides app banks 20–29 (a full
76,800-byte frame), the menu/overlay save-under banks 30–33, and BMX
files stream row-by-row. The overlays (menu, palette, filename prompt)
are modal loops over a saved top band, so the canvas underneath is
never lost.

Works standalone on a cartridge too: `build.ps1 -Cart -App
build\PAINT.CXA` bakes it into ROM bank 37 (`paint.bat`).
