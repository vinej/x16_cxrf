# CXRF Data

A flat-file record manager for the CXRF desktop — native, on the 640×480
GUI (mode 0) with the toolkit: a menu bar, modal dialogs, and a table
grid.

Editing walks the fields as labelled modal line editors (one per field,
pre-filled; Esc abandons the edit). That is deliberate: a modal box goes
through the mode's save-under, which in mode 0 spans banks 14–15 ≈ 102
pixel rows — a taller box runs into **bank 16, the widget engine's own
bank**, and the toolkit then executes the pixels that overwrote it. Every
modal here stays inside the dialog metric's 96 rows.

## The data model

**Fixed-length records**, so record *n* is a pure offset — that's what
keeps browsing and sorting cheap on a 6502. The v1 schema is an
address-book shape:

| field | type | shown |
|---|---|---|
| name | text | 18 chars |
| company | text | 16 |
| phone | text | 12 |
| amount | number | 9 |
| date | date (YYYYMMDD) | 8 |
| paid | flag | checkbox |

Records live in app banks 20 upward (96 bytes each, 85 per bank);
**1,200 records** max, and the table reports "full" rather than failing
oddly. A parallel *order* array holds record indices, so sorting and
filtering permute indices while the records themselves never move.

## Commands

**File** — new · open… · save · save as… · **export to sheet** · quit
**Record** — add · edit · duplicate · delete (confirm dialog)
**View** — sort by field… · find… · filter… · show all · totals

Keyboard in the table: ↑/↓ move the selection, Enter edits the current
record, Esc leaves. Mouse: click a row to select, **double-click to
edit**.

- **Sort** picks a field from a radio panel; text sorts case-insensitively,
  numbers sort numerically (right-aligned keys), dates sort correctly
  because YYYYMMDD is monotonic as text.
- **Filter** keeps only records containing the pattern in any field; the
  status line shows "filtered" until *show all*.
- **Find** jumps to the next matching record, wrapping.
- **Totals** reports count / sum / average of the numeric field over the
  current (possibly filtered) view.

## Files

`.CXR` — a 16-byte header (magic `CXDB`, version, field count, record
length, record count), the schema block, then the records verbatim, as a
CMDR-DOS SEQ file. The schema travels with the file, so a later version
with a schema editor can still read v1 tables.

**Export to Sheet** writes `<name>.SHT` in the keystroke-replay format
CXRF Sheet loads (see [apps/sheet/README.md](../sheet/README.md)): a
header row of field names, then one row per record, numbers as values
and everything else as labels. Open it in Sheet with `M` — the two apps
interchange without a CSV detour. (Sheet is 100 rows, so the export
stops at 99 records.)

## Not in v1

A schema editor (fields are fixed, but the file format already carries
the schema), computed fields with formulas (Sheet's shunting-yard parser
is the obvious future source), CSV import, labels/mail-merge, and undo
(delete confirms instead).
