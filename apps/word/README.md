# CXRF Word

A text editor for the CXRF desktop — [X16 Edit](https://github.com/stefan-b-jakobsson/x16-edit)
by Stefan Jakobsson (BSD-2-Clause, see `LICENSE`), vendored verbatim and
hosted as a CXRF app. X16 Edit was practically designed for this: its
entry points take the RAM bank range in registers, its interrupt
handler chains to the host's and restores it at exit, and it snapshots
zero page + golden RAM around the whole session.

The entire port is [`word.asm`](word.asm), a ~40-line wrapper: enter
CXRF text mode (mode 3, the same KERNAL 80×60 screen the editor
expects), call `main_loadfile_entry` with **banks 20–63** (the CXRF app
banks — work area in 20, text buffer in 21–63, ~344 KB of document
room), and on exit restore the desktop mode and `cx_exit`. The CXRF
event system is never started, so the editor's own KERNAL keyboard and
mouse handling runs undisturbed.

## Using it

Launch `WORD.CXA` from the desktop. It's GNU-Nano-style — the shortcut
bar at the bottom shows the commands (`^` = Ctrl):

- **Ctrl+G** help (the full key list) · **Ctrl+X** exit → back to the desktop
- **Ctrl+O** write out (save) · **Ctrl+R** open a file
- **Ctrl+K** cut line · **Ctrl+U** uncut (paste) · **Ctrl+C** copy
- **Ctrl+W** where is (search) · **Ctrl+Y / Ctrl+V** page up / down

Mouse selection, word wrap, auto-indent and the rest are documented in
the in-editor help (Ctrl+G).

## Vendored-source deviations (each marked `CXRF:` in the source)

- `word.cfg` replaces upstream `conf/cx16-asm.cfg`: the zero page rides
  the CXRF app window (`$60–$7F`; the editor declares 24 bytes, upstream
  linked at `$22` which belongs to the kernel), and the code ceiling is
  `$8000` (CXRF app space) instead of `$9F00`.
- `common.inc`: the printer-driver ZP assert moves with the zero page
  (`$36` → `$74`) — external printer drivers built for stock X16 Edit
  ZP addresses are not supported under CXRF.
- `help.inc`: the lzsa-compressed help binaries (`help.bin`,
  `help_short.bin`) ship pre-compressed beside the sources, so building
  CXRF needs no lzsa tool. To regenerate after editing `help.txt`:
  `lzsa -r -f2 help.txt help.bin` (lzsa 1.4.1+).

Resyncing a new upstream X16 Edit: copy the sources over, re-apply the
three deviations above, rebuild — the wrapper and cfg carry everything
CXRF-specific.
