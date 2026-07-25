# CXRF releases

CXRF (Commander X16 Runtime Framework) shipped as **CXGEOS** through v0.9.0 and
was renamed at v0.10.0. Git tags keep their `vX.Y.Z` names; dates are tag dates.
Newest release first.

## v0.13.0 — text geometries, list scrolling, leak-free re-set (2026-07-24)

- **`CX_MODE_TEXT` takes any KERNAL geometry.** `cx_gfx_mode(3, X)` with `X` =
  a `screen_mode` code (`$00`–`$0B`: 80×60 default, 80×30, 40×60, 40×30, 40×15,
  20×30, 20×15, 22×23, 64×50, 64×25, 32×50, 32×25). `X` = 0 keeps the old
  contract (code 0 *is* 80×60); an unknown code lands 80×60, the same "native"
  rule as the bitmap depths. `ov3_init` publishes the live grid in `cx_minfo`,
  so `cx_gfx_info`, the canvas bounds, the save-under row size and the mouse
  field all follow. Changing geometry while already in mode 3 reloads + reinits
  the image (bank-side `cx_veng` poison past the same-image short-circuit); the
  same geometry stays a no-op. The toolkit wants ≥ 64×25 — on narrower grids
  apps draw their own cell UI. Fixed along the way: the `t_smode` wrapper let
  `vera_addrsel` eat the mode code in `A`, so every geometry request became
  80×30. New demo `TUIGEO` (menu/widgets/dialog, View menu switches the grid
  live); new self-verifying boot smoke `GEOSMOKE` asserts all four toolkit
  grids headlessly.
- **Lists scroll with the mouse.** When a list's items overflow its box the
  widget draws a **scroll strip** on the right edge (separator + up/down
  arrows); a click in the strip's upper/lower half pages the selection a
  screenful. The desktop's file list (23 visible rows, 30+ files now) was the
  motivating case — the tail was keyboard-only before. Lists that fit draw
  unchanged; the size column shifts left of the strip.
- **Re-setting the menu/widgets no longer leaks regions.** New resident
  `rg_remove` (remove by handler, anywhere in the 8-deep stack, compacting);
  `cx_menu_set`, `cx_wg_set` and `cx_menu_off` use it, so an app repainting
  bar + widgets per view switch (TUIGEO) no longer fills the stack and goes
  unstable after a few switches. Repainting from an `EV_MENU` handler is a
  supported pattern.
- **The desktop defaults to icon view.** The resident view byte (`$800A`)
  stores the mode inverted, so the cold-boot zero lands on icons; a chosen
  view still sticks across app launches.
- **Resident ledger:** `cx_eng_index` (+ the tile-depth default) moved behind
  a `cxb_call` stub into bank 17; the v0.12.0 mode/bpp dispatch cost came back
  and paid for `rg_remove` and the mode-3 mouse field (152 B free). `CX_KBUILD`
  → `$0603`.
- **x16lib v0.12.1 vendored** (table-free fast `bitmap4h`/`8h` — the row tables
  outgrew the fixed 2304-byte overlay window, replaced upstream by an
  arithmetic `y*320`/`y*640`; largest engine image 2004/2304) and the library
  gained `screen_get_size` (the `SCREEN` cols/rows query, `EXTRA` section).

## v0.12.1 — fix a black screen on exit from a VERA_2 depth (2026-07-24)

- **`cx_gfx_init` now restores the desktop from a VERA_2 depth.** Leaving a
  `CX_MODE_BMPHIGH` bpp-4/8 app (`cx_exit` → shell → `cx_gfx_init`) left a black
  screen: `cx_do_gfx_init` decided "already on the desktop, skip the reload" by
  testing `cx_vmode == 0`, but with the 640×480 umbrella the VERA_2 depths run
  at `cx_vmode 0` too (only their engine index differs). So it never booted OV0
  back, `cx_ov_load` never ran its `stz VERA2_CTRL`, and VERA_2 stayed up over a
  dark VERA. Test `cx_veng` (the loaded image) instead — the desktop is engine 0.

## v0.12.0 — four new graphics depths, `cx_gfx_mode` gains a bpp (2026-07-24)

- **`cx_gfx_mode` now takes a bit-depth.** `A` = the mode, **`X` = bpp**
  (`0`/`2`/`4`/`8`; `0` = the mode's native depth). A mode with more than one
  depth is more than one engine image behind the same mode number — the depth
  picks which loads. The slot number and semantics are backward-compatible: an
  old caller that sets only `A` still lands the native image. C is
  `cx_mode(mode, bpp)`; the asmsdk macro is `cxm_gfx_mode m, bpp`; Prog8 is
  `gfx_mode(m, bpp)`.
- **Mode 1 (320×240) is now three depths.** `X`=8 (256 colours, the existing
  `OV1`/`bitmap8l`), `X`=4 (16 colours, new `OV4L`/`bitmap4l`), `X`=2 (4 colours,
  new `OV2L`/`bitmap2l`), all shown fullscreen (2:1). The 4/2bpp images carry
  the 13 drawing entries and refuse text and the save-under (future work); their
  colours come from the default VERA palette.
- **`CX_MODE_BMPHIGH` is the 640×480 umbrella; `CX_MODE_GUI` is gone.** One mode
  number (0) now spans the whole 640×480 family by depth: **bpp 2** is the
  4-colour desktop on standard VERA (`OV0` — this is the old `CX_MODE_GUI`,
  folded in and removed as a separate constant, so `cx_mode(CX_MODE_BMPHIGH, 2)`
  is the desktop); **bpp 4** (`OV4H`) and **bpp 8** (`OV8H`) light up the VERA_2
  second plane (the MiSTer core's SDRAM bitmap layer, `$9F60`–`$9F6F`). The
  VERA_2 depths keep their own framebuffer, registers and palette (`gfx*h_pal_*`,
  not `cx_pal_set`); the loader turns VERA_2 **off on every image swap**, so
  switching back to bpp 2 restores the desktop, and each VERA_2 init turns it on.
  The emulator needs **`-bitmap2`** to show VERA_2 — without it a mode-4/8 app
  renders fully white; it is now on every `build.ps1` path AND the `run-cart.bat`
  / `paint.bat` / `launch.bat` launchers (this was the "white page from the
  desktop" bug — the interactive boot alone had been missing the flag).
- **Loader restructure.** The engine *image* in the port (`cx_veng`, 0–8) is now
  decoupled from the *mode* the app selected (`cx_vmode`, 0–3); `cx_eng_index`
  maps (mode, bpp) → image — mode 0 alone spans three images (bpp 2 = `OV0`,
  4 = `OV4H`, 8 = `OV8H`). `cx_gfx_info` reports the live depth/stride from the
  image row, and `cx_mbank`/`cx_msrc`/`cx_minfo` are indexed by image. Runtime-
  verified: `M1BPP4=4 M1BPP2=2 M4H4=Y M4H8=Y`. Resident free is ~183 B (from
  327), OVL window unchanged (largest image 2,004 of 2,304); bank 3 stacks
  `OV0`+`OV4L`+`OV2L` (5,706 B), bank 4 stacks `OV1`+`OV4H`+`OV8H` (4,831 B).
- **Tiles kept consistent.** `cx_gfx_mode(CX_MODE_TILE, bpp)` records the tile
  mode's **default depth** — `cx_tile_setup(layer, 0)` adopts it, so
  `cx_mode(CX_MODE_TILE, 8)` then a `0`-bpp setup is an 8bpp layer. Default stays
  4bpp, and every existing caller passes an explicit depth, so nothing changes
  for them. Verified `TILE8=Y TILE4=Y`.
- **A demo for every new depth** (C, self-verifying, all in the boot smoke under
  `-bitmap2`): `apps/gfx8hi` (640×480 8bpp), `apps/gfx4hi` (640×480 4bpp),
  `apps/gfx4` (320×240 4bpp), `apps/gfx2` (320×240 2bpp). Each draws a colour
  spectrum full width with the port's rect/frame/line/shape calls, then reads a
  pixel back to prove the depth took the ink (`GFX.. OK`/`FAIL`). The mode-4
  demos load VERA_2's own palette through `$9F66`–`$9F68` (VERA_2 keeps a
  separate palette that `cx_pal_set` does not reach); the mode-1 demos use the
  ordinary VERA palette at `$1FA00`.
- **Fixed a mode-1 2bpp port bug (CXRF).** `gfx2l` is ABI-native (colour in `A`,
  16-bit y in P2/P3), but its port vector had the same `sta P3` adapters as
  `gfx4l` (colour in P3, byte y) — for 2bpp that `sta P3` clobbered y's high
  byte, so every pixel drew off-screen and read back 0. The ov2l vector is now
  direct JMPs.
- **Vendored x16lib re-synced to a clean v0.11.9 snapshot.** Building and
  visually testing the demos drove out a run of upstream fixes, all **upstreamed
  into `x16_library`** (in `src_acme`, regenerated to all six variants,
  ACME/ca65 suites green), so `x16lib/` stays a plain snapshot: the `acme2ca65`
  lone-label regen bug and the `_MIN`/`_NO_INIT` gates (**v0.11.2**); a
  `bitmap8h` `hline`/`rect` fill that wrote 64 KB for any span under 256 px wide
  — correct but thousands of times too slow (**v0.11.3**); `gfx4l_rect` drawing
  a diagonal staircase because `gfx4l_hline` advances x and the rect never reset
  it (**v0.11.4**); `gfx4l_setptr` computing the wrong VRAM row address on odd
  rows — the `y*128` step shifted the accumulator instead of `X16_T0`, so 4bpp
  low-res rendered as a comb of stripes (**v0.11.7**); `gfx4l_line` reading its
  8-bit `y` as 16-bit and pulling adjacent variables in as garbage `dy`, so
  vertical/diagonal `cx_line` and the circle/ellipse outlines drew garbage, and
  a `gfx4l_text` cheap-local scope break in the converter-generated ports
  (**v0.11.9**).

## v0.11.0 — x16lib v0.11.1 vendored, tile/text UI polish (2026-07-23)

- **Vendored x16lib re-synced to v0.11.1.** The whole `x16lib/` tree is a clean
  snapshot of the upstream `src_ca65` at v0.11.1: the bitmap modules were renamed
  and split (`bitmap.asm` → `bitmap8l.asm`, `bitmap2.asm` → `bitmap2h.asm`, with
  `gfx_*` → `gfx8l_*` and `gfx2_*` → `gfx2h_*`), `X16_USE_ALL` is gone in favour
  of per-module gates, and many new modules ride along gated-out. Two gates CXRF
  needs for its split-bank, bare-VERA kernel were **upstreamed into x16_library
  v0.11.1 first** — `X16_SKIP_BASE` (source `shapes.asm` twice, base + extras in
  separate banks) and `X16_BITMAP8L_NO_INIT` (omit `gfx8l_init`'s
  `screen_set_mode`) — so the vendored copy stays a plain snapshot with nothing
  hand-patched.
- **~130 B of resident reclaimed — free rose from ~194 B to 327 B.** Dropping the
  KERNAL console/input shims (SCREEN, INPUT) for inline KERNAL calls, plus finer
  opt-in x16lib gates — `X16_USE_VERA` split into `_ADDR`/`_FILL`/`_FXPROBE` and
  `irq_remove` behind `X16_USE_IRQ_REMOVE`, both also upstreamed — let the kernel
  carry `vera_fill` alone and drop the address setters, FX probe and `irq_remove`
  it never calls.
- **Fixed a boot crash into the machine monitor.** `font_set`'s inline far call
  (`jsr cxb_call` + inline bank/addr) is a *tail* call — `cxb_call` consumes the
  stub's frame to read its data and returns to the ORIGINAL caller — so the
  refactored rollback code after it was dead, and its pushed bytes were popped as
  a return address, BRK-ing to the monitor at boot. Now behind its own 5-byte
  stub. The flat test runner links `fs_parse` directly and never saw it; only the
  boot smoke caught it.
- **Tile/text dialogs: upper-case text no longer renders as graphics.** The
  mode-2 glyph charset was staged with `CINT` + `CHR$(14)`, but on the X16 the
  case toggle only sets the editor's mode FLAG — it does not re-upload the VRAM
  charset — so `$1F000` kept the upper/GRAPHICS set and every `A-Z` in a tile
  dialog drew as a graphic tile. `ov2_init` now uploads explicitly with
  `SCREEN_SET_CHARSET(3)`. TILETEXT's self-test gained a charset-glyph assertion
  so it cannot regress silently.
- **Cell-mode widget polish** (mode-2 tiles + mode-3 TUI, one shared path): text
  fields grew a **block caret** (there was none); the focus outline no longer
  boxes a field (the caret is the cue); the slider's fill is a **solid rectangle**
  drawn as a colour fill instead of `#` (a glyph rendered differently by the tile
  and KERNAL ports); and every widget now shares the **dialog's background**
  instead of a stale or black one — with no stray cyan.
- **`fontconv.py` gains a `--x16-charset` path** — raw 8x8/1bpp X16 tile fonts to
  CXF, remapping screen-code order into CXRF's codepoints; a set of `.cxf` fonts
  is staged for future use.
- **ABI unchanged (v4, 105 slots).** The freeze canary still passes. Green:
  62/62 tests, the asmsdk byte-identical fidelity gate, and every headless boot
  (SD, cartridge, FAT32, standalone cart).

## v0.10.1 — desktop file sizes, longer filenames (2026-07-22)

- **File sizes in the desktop list** — the list view now shows each entry's
  size (its CMDR-DOS block count) as a right-aligned second column beside the
  name. `cx_dir_next` surfaces the block count it used to discard, in P2/P3; a
  new `cxm_wg_list2` builder gives the list widget an optional parallel
  size-string array, drawn right-aligned. Folders and the "../" row show no
  size. It costs nothing extra — the count was already in the DOS listing.
- **Longer filenames** — the desktop's name limit rose from **16 to 34
  characters**. `cx_dir_next`'s name cap is now 34 (its buffer contract grows
  to >=35 bytes), and the file browser's name pool and its prompt / DOS-command
  buffers grew to match. Both browsing/launching and create/rename/copy handle
  34-char names in list view. (The X16 itself allows up to 255; 34 is the
  desktop's practical cap — icon-view captions can overflow their cell for the
  longest names, list view is unaffected.)
- **`docs/exit-to-basic.md`** — records a known instability found while
  prototyping "launch a standard X16 program": handing the machine from CXRF to
  BASIC resets the board ~1 s later, and CXRF's own `cx_exit -> BASIC` fallback
  does the same. It is NOT the SMC watchdog (there is none). The note keeps the
  evidence, the dead ends (no KERNAL soft re-init fixes it), and the
  hardware-reset / boot-chain path that would, so a future fix starts informed.
- **ABI unchanged (v4, 105 slots).** The `cx_dir_next` change is behaviour-only,
  so the freeze canary still passes. Green: 59/59 tests, the asmsdk fidelity
  gate, and every headless boot (SD, cartridge, FAT32, standalone cart).

## v0.10.0 — CXRF: the rename, and a standalone cartridge (2026-07-21)

- **Renamed CXGEOS → CXRF** (Commander X16 Runtime Framework) across the whole
  repo: identifiers, comments, docs, build outputs (`cxrf_cart.bin`) and the
  generated bindings, plus the source files themselves (`abi/cxrf.abi`,
  `sdk/include_*/cxrf.{inc,h,p8}`, `asmsdk/*/cxrf.inc`). All 13 toolchains and
  the ABI generators regenerate consistently; the `cx_*` ABI names are
  unchanged, so existing apps rebuild untouched.
- **Standalone cartridge** — `build.ps1 -Cart -App <CXA>` bakes an app into a
  sixth ROM bank (37); the boot stub copies it to `$0801` and runs it, so the
  cartridge boots straight into the program with **no SD card at all** — a
  single-item deliverable. `paint.bat` is the worked example (PAINT in ROM).
- **Clean exit to BASIC** — with no `SHELL.CXA` to load (a standalone cart, or
  a card without one), `cx_exit` now rebuilds the stock text screen (`CINT`:
  charset, layers, palette the 2bpp desktop clobbered) and hands the machine to
  the **X16 BASIC prompt**. It uses `ENTER_BASIC`, not a reset, so the
  cartridge's `"CX16"` auto-boot does not re-fire. The old "NO SHELL.CXA" halt
  is gone.
- Green: 59/59 tests, the ABI-freeze canary, the asmsdk byte-identical fidelity
  gate, and every headless boot (SD, cartridge, FAT32, standalone cart).

## v0.9.0 — desktop matures, 8bpp tiles (2026-07-21)

The icon view becomes a real file browser: an **18-icon** sheet with a per-app
picture mapped by filename, tighter single-line cells, single-click select /
double-click open, keyboard grid navigation, and a selection that **survives an
app launch** (the launched file's index rides resident byte `$800B`, and a new
`WG_SELECTED` flag installs a list focused, so `cx_exit` lands the frame back on
the app you ran). Radio buttons draw **round**, the prompt field centres its
text, and **TAB toggles** the menu bar. Fixed a latent `cx_do_icon` blit-op bug
that vanished any icon whose sheet address had `(high & 3) == 2`. Tile mode
gained an **8bpp path** — a 64 KB set streamed to VRAM (`cx_vram_stream`,
`cx_tile_load`) with maps relocated to `$10000` — plus **double-buffering**
(`cx_tile_dbuf`/`cx_tile_flip`) and a mode-2 **dialog overlay** (`cx_tile_text`).
ABI **v4, 105 slots**; vendored x16lib bumped to **0.9.1** with an
`X16_SKIP_SHAPES`/`X16_SKIP_MATH` include opt-out. 59/59 tests green.

## v0.8.0 — Prog8 support, and more shapes (2026-07-20)

**Prog8** (Irmen de Jong's structured 6502 language) joins as a 13th toolchain:
`abi/prog8.py` generates the `cx.*` binding to every slot, and `p8sdk/` is the
Prog8 parallel of the C csdk. `apps/calc/calc.p8` is the worked example. x16lib
0.8.0's extra shapes — polygon, fpolygon, arc, pie — arrive through a single
dispatched slot, `cx_gfx_shape` (X selects the shape; a `jmp(tbl,X)` routes it),
for 6 resident bytes. Bank 19 was cleared for them (audio + sprites → bank 18).
ABI bumped to **v2** (slot 100, append-only), with friendly layers across all
toolchains. 56/56 on-target tests, byte-identical asmsdk fidelity, zero
regression.

## v0.7.1 — a friendly assembly macro SDK, and desktop fixes (2026-07-20)

`asmsdk/ca65`: named `cxm_*` macros + descriptor builders over the jump table,
the assembly parallel of the C csdk, expanding byte-identical to hand code; all
ten in-tree asm apps use it. `cx_menu_active` (slot 99) reports whether a menu
is open (mouse or keyboard) so the desktop routes cursor keys to a click-opened
menu. Two exit-path fixes stop a mode-switching app from returning to the
desktop on the wrong file. New `docs/asmsdkguide.md`.

## v0.7.0 — invisible hit regions, palette API, persistent desktop view (2026-07-19)

`WG_HIT`: a hotspot the app draws itself while the toolkit only routes the mouse
— rect/circle/ellipse, click/release/hover — for 0 resident bytes.
`cx_pal_set`/`cx_pal_load` (slots 97–98) program VERA's palette directly. The
desktop remembers its list-vs-icons view across app launches. x16lib v0.7.0 gfx
re-vendored (~600 B saved); the C SDK now wraps all 99 slots.

## v0.6.1 — icon widget + dual-view desktop (2026-07-19)

A graphical icon widget and an icon-view desktop, plus sprite-collision capture.
One 24×24 2bpp icon sheet serves both bitmap modes; the filer's View menu
toggles a file-type icon grid against the classic list.

## v0.6.0 — memory architecture restructured for growth (2026-07-19)

The per-bank memory architecture: banks re-themed, the font split, the jump
table grown (110 → 135 slots), resident free 20 → 130 B, bank 2 shrunk 7 KB →
1.8 KB. RAM banks 16–19 now belong to the kernel; the first app bank (and
`cx_bload` floor) moved from 16 to **20**. See `docs/banks.md`.

## v0.5.1 — cartridge boot, a game's own IRQ (2026-07-19)

Boot the whole framework from a **cartridge** (`build.ps1 -Cart`, ROM banks
32–36, the KERNAL's `"CX16"` auto-boot) — no ROM patch. `cx_ev_raster` /
`cx_ev_stop` (slots 93–94) let a game own a raster line and borrow the kernel's
events for a dialog.

## v0.5.0 — the toolkit in every mode (2026-07-19)

The widget toolkit, menus, and modal dialogs draw in every video mode, not just
the desktop — the menu gate and text-port work that lets a tile or bitmap app
raise the whole UI.

## v0.4.0 — pluggable fonts & charsets, cx_file_load, cx_ink, mode-1 text (2026-07-18)

Pluggable fonts and charsets, the `cx_file_load` asset loader, `cx_ink` for
mode-1 text colour, and an event **source mask** so an app subscribes only to
the event kinds it wants.

## v0.3.1 — ellipses in the ABI (2026-07-18)

Ellipse primitives added at slots 85–86.

## v0.3.0 — the graphics port: four video modes (2026-07-18)

Four video modes behind a pluggable graphics port (`cx_mode`) — the same drawing
calls reinterpreted per canvas (GUI, 8bpp bitmap, tiles, text) — plus
joysticks, the mode-agnostic shapes, and text boxes.

## v0.2.0 — audio, sprites and PCM (2026-07-17)

x16lib's multimedia through the ABI (now 74 slots, still v1): the VERA PSG (16
voices), the YM2151 FM chip, and streamed PCM (`cx_psg_*`, `cx_ym_*`,
`cx_pcm_*`); hardware sprites 1–127 (`cx_sprite_*`, sprite 0 is the mouse) with
`cx_vram_write`. New examples `apps/beep` and `apps/sprite`.

## v0.1.0 — first tagged release (2026-07-17)

A from-scratch, GEOS-inspired desktop for the Commander X16 (640×480 @ 2bpp,
stock R49+ ROM) with a documented SDK. Kernel ABI **v1, 55 slots** (graphics,
text, events, menus, widgets, themes, dialogs, directory, DOS, clipboard, desk
accessories). Header-only C wrapper (`csdk/`). Apps: the desktop/file manager,
widget gallery, control panel, notes desk accessory, and C examples hello_c,
calc, cdemo, paint. 40/40 tests, six boot chains green.
