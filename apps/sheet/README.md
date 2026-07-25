# CXRF Sheet

A spreadsheet for the CXRF desktop — an adaptation of
[X16Cell](https://github.com/TediusTimmy/X16Cell) by Thomas DiModica
(BSD-3-Clause, see `LICENSE`). The engine — 8-digit decimal (BCD)
floating point, the shunting-yard formula parser, the banked cell
store — is X16Cell's, verbatim. The platform layer (`machina_cxrf.c`)
speaks CXRF: text mode 3 painted by direct VERA writes, `EV_KEY` input,
the cell store in app banks 20–61, files over CMDR-DOS SEQ channels.

**100 rows** (`0`–`99`) × **26 columns** (`A`–`Z`), up to 120
characters per cell. Launch `SHEET.CXA` from the desktop; `Q` `y`
returns to it.

## The screen

```
A0  VALUE 3.00                                       LT   <- status: cell, type, value, recalc order
1+2                                                       <- edit line (the cell's source)
     A        B        C        D        ...              <- column headers
 0   3.00
 1
```

The gray band marks the current row, column and cell. A label longer
than its column spills across the empty cells to its right (CXRF
addition); a number too wide for its column shows `#` — widen with `]`.

## Moving around

| key | action |
|---|---|
| arrows or `W` `A` `S` `D` | move the cell cursor (the view follows) |
| `Z` or Home | back to `A0`, view reset |

## Entering data

| key | action |
|---|---|
| `=` or `+` | start a **number / formula**, finish with Enter |
| `"` or `'` | start a **text label**, finish with Enter |
| `E` | edit the current cell's existing contents |
| **ESC** | abandon the edit — the cell comes back as it was (CXRF addition) |
| `X` `X` | clear the cell (`X` `R` clears the whole ROW, `X` `C` the whole COLUMN) |

While editing: type mixed case; cursor left/right move the insertion
point (shown as a reverse-video block on the edit line), Home jumps to
the start, Insert to the end, Backspace deletes left, Shift+Delete
deletes right.

## Formulas

Infix expressions over 8-significant-digit decimals:

- operators: `+` `-` `*` `/`, parentheses, unary `-`
- cell references: `A0` … `Z99` (case doesn't matter)
- ranges `A0:A9` inside functions
- functions: `SUM( )` `AVERAGE( )` `COUNT( )` `MIN( )` `MAX( )`
  `ROUND( )` `TRUNC( )` `ABS( )`

Examples: `=1+2*3`, `=A0*B0`, `=sum(a0:a9)`, `=round(C5/7)`.

| key | action |
|---|---|
| `!` | recalculate now |
| `J` | toggle recalculation major order (row-major / column-major — the two letters top-right) |
| `K` | toggle top-down / bottom-up (`T` / `B`) |
| `L` | toggle left-to-right / right-to-left (`L` / `R`) |
| `,` | show decimals with a comma instead of a point |

Recalculation order matters when formulas refer to each other — set it
to match the direction your data flows.

## Layout

| key | action |
|---|---|
| `]` | widen the current column (up to 26 cells) |
| `[` | narrow it (down to 3) |

## Rows, columns and cells

Two-key commands: the first key picks *insert before* (`I`) / *open
after* (`O`) / *remove* (`U`), the second what moves:

| keys | action |
|---|---|
| `I` `R` / `O` `R` | insert a row above / below (rows shift down) |
| `I` `C` / `O` `C` | insert a column left / right (columns shift right) |
| `U` `R` | delete the row (rows below shift up) |
| `U` `C` | delete the column (columns shift left) |
| `I` `I` / `U` `U` | insert / remove just this CELL, shifting the rest of the row |
| `I` `O` / `O` `O` / `U` `O` | insert / open / remove this cell, shifting the rest of the column |

## Files

The filename comes from a **cell**: type it as a label (e.g.
`"budget`), leave the cursor on it, then

| key | action |
|---|---|
| `N` | save the sheet to that file (SEQ, CMDR-DOS) |
| `M` | load that file into the sheet (merges over what's there) |

CMDR-DOS refuses to overwrite: to re-save over the same name, use the
DOS prefix in the label — `"@:budget`. A DOS error replaces the cell's
text with a message. Names are folded to PETSCII upper case for DOS,
so case never matters. The save format replays the keystrokes that
rebuild the sheet, so a saved file loads on upstream X16Cell too.

## Quitting

`Q`, then `y` to confirm — back to the CXRF desktop.

## Adaptation notes (what differs from upstream X16Cell)

- Full **80×60** screen (upstream used 80×30 under cc65 conio).
- Painting is **direct VERA text-map writes** — full-screen repaints
  and scrolling are instant; VERA port 1 is used and interrupts are
  masked around each burst, per CXRF IRQ rules.
- **Mixed-case** typing and display (PETSCII↔ASCII translated at the
  edges), **ESC cancels** an edit, labels **spill** over empty cells,
  Backspace is the X16 DEL key.
- Files go through a small CBM-channel `fopen`/`fgetc` shim
  (`machina_cxrf_files.h`) instead of llvm-mos stdio (which didn't fit
  the app ceiling); the channel stays redirected for the file's life,
  so saves are fast on real hardware.
- The cell store rides CXRF app banks: the cell table in bank 20, cell
  text in banks 21–61.
