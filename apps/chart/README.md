# CXRF Chart

Charts a table from the rest of the suite — 320×240 in 256 colours
(`CX_MODE_BMPLOW` at 8bpp), native against the CXRF ABI.

## One importer, both sources

Chart reads the **Sheet file format** (`.SHT`), which means it plots

- a **CXRF Sheet** save directly, and
- a **CXRF Data** table through Data's *File > export to sheet*.

That format is a keystroke replay (see
[apps/sheet/README.md](../sheet/README.md)): `z` homes the cursor, `"`
starts a label and `=` a value (text, then a newline), `d`/`a` step right
and left, `s`/`w` down and up. The importer walks those commands with a
virtual cursor and fills a grid of up to 24 rows × 8 columns — no
spreadsheet engine needed.

## Charts

| key | type |
|---|---|
| `1` | **bars** — one coloured bar per row, auto-scaled axis with four gridlines and value labels |
| `2` | **line** — points joined, with markers |
| `3` | **pie** — `cx_pie` wedges proportional to each value, with a colour legend |

Menus: **File** (open sheet… · save picture · quit) · **Chart** (bars ·
line · pie) · **Data** (value column… · label column… · title… · header
row on/off). `o` opens a file, Esc quits.

By default column 1 supplies the labels, column 2 the values, and row 1
is treated as a header (its cell over the value column becomes the chart
title unless you set one).

**Save picture** writes a **BMX v1** image (8bpp) of the chart — the same
format CXRF Paint reads, so a chart can be touched up, and community
viewers can display it.

## Implementation notes

- Mode 1 was chosen over the 640×480 desktop because charts want colour
  more than pixels; the palette holds paper/ink/grid plus eight series
  hues, written with `cx_pal_set` and shadowed so a BMX save records the
  colours actually on screen.
- Prompts and messages are **drawn in-canvas** rather than through
  `cx_prompt`/`cx_alert`: those size their box from the *mode's* dialog
  metrics, which carry the 640×480 numbers, so a kernel dialog overflows
  a 320-pixel-wide screen. (Same approach as `apps/paint`.)
- `cx_clear` takes the menu bar's pixels with it, so every repaint
  re-sets the bar — safe because `cx_menu_set` replaces its own click
  region instead of stacking a second one.
- Values are whole units (digits before any decimal point), capped at
  65,000 — enough for a chart's resolution on a 240-pixel canvas.
