# M1 — Mechanical split of `cc.asm` into host core + `mod/*.inc`

Status: plan only. Target: introduce the `%include` seam with a **byte-identical**
`cc.com` (fallback: behaviourally identical, headless harness green).
Source analysed: `cc.asm`, 3722 lines, `nasm -f bin cc.asm -o cc.com` → 7,104 B.

This plan does **not** edit `cc.asm` or create any `mod/` files. It is the blueprint
for the first extraction. All line numbers below are current `cc.asm` lines.

---

## 0. Why byte-identical is achievable here

A flat `-f bin` `.COM` emits bytes in **pure source order**. There is no linker,
no section reordering for `section .text` (the implicit default section), and no
relocation. NASM's `%include` is a textual paste at the point of inclusion. So:

> If an `%include "mod/x.inc"` line sits at the *exact* line where the moved block
> used to start, and the file contains *exactly* the moved text, the assembled
> output is identical down to the byte.

The only things that can break this:

1. **`section` directives inside an include** that re-open `.bss` or `.data` and
   thereby move emitted bytes around. → Mitigation: **no `section` directive in
   any M1 module**; all moved blocks are plain code from the implicit text
   section. The single `section .bss` at line 3662 stays in `cc.asm`.
2. **`equ`/macro used before defined.** NASM resolves `equ` in multiple passes,
   so forward references to `equ` values are fine (proven already in this file:
   `MM_BROWSER` is *used* at line 189 but *defined* at line 1835). The risk is
   only if a module both *defines* an `equ` and that `equ` is needed by code
   that the assembler reaches *textually earlier* AND the value feeds a `times`
   / `resb` size or an `org`-relative constant. The viewer's `VIEW_MAX` /
   `MAX_VLINES` are exactly this case (see §3) and are handled by keeping their
   `equ`s in `cc.asm`.
3. **Label collisions** — local labels (`.loop`, `.ret`, `.up`, …) are scoped to
   the preceding non-local label, so they do **not** collide across modules as
   long as every module starts with a global (non-`.`) label. Every block we
   move does. No risk.

Conclusion: a conservative split that moves only **self-contained code blocks**,
leaves **all `equ` constants, all `db`/inline data, and the entire `.bss`** in
`cc.asm`, and places each `%include` at the block's current start line, will be
byte-identical.

---

## 1. File layout — what stays vs. what moves

### Stays in `cc.asm` (the host core — always present)

| Region | Lines | Why it stays |
|---|---|---|
| Header, `cpu 386 / bits 16 / org 100h` | 1–17 | Must be first; defines the binary. |
| **All `equ` constants** (video, geometry, attrs, box chars, panel/entry struct, DTA) | 19–83 | Centralized per ROADMAP §5.1 ("keep equ constants … centralized"). |
| `start` (arg parse, memory shrink, mouse init) | 86–204 | Host core. |
| `main_loop` | 205–233 | Host core. |
| `dispatch` + key handlers (`key_quit`…`set_active_cwd`) | 234–550 | Dispatch shell (M1 seam #2 replaces this later; stays in core now). |
| Render family (`render_all`…`draw_info`, `draw_cmdline`, `draw_fkeys`) | 551–929 | Host core render. |
| Directory model (`init_panel_cwd`, `read_dir`, `accept_dta`, `build_search`) | 930–1069 | Host core panel model. |
| Path helpers (`path_append`, `path_up`, `go_parent`) | 1070–1186 | Host core. |
| Sort (`sort_panel`, `order_cmp`, `rank_of`) | 1187–1305 | Host core. |
| Formatting + small utils (`format_entry`, `clear_rowbuf`, `u32toa`, `entry_ptr`, `cur_entry_ptr`, `strlen`, `strlen_di`, `strcmp_ci`, `rc_to_off`, `putbuf`, `hide_cursor`, `show_cursor`) | 1306–1543 | Shared leaf helpers used by everything; keep central. |
| `DLG_*` / `A_DLG*` / `BTN_*` / `MM_*` `equ`s + dialog primitives (`dlg_box`…`busy_name`, `dlg_input`, `dlg_field`, `dlg_confirm`, `dlg_draw_buttons`, `dlg_overwrite`, `ow_draw_buttons`, `ow_one_btn`) | 1808–2280 | Dialog primitives = host core per ROADMAP §5. (The `equ`s at 1811–1838 stay.) |
| Path-builder family (`build_entry_path`, `build_target_path`, `build_other_path`, `bp_copy_dir`, `bp_copy_name`, `other_panel_ptr`, `refresh_panels`) | 2281–2365 | Host core path family. |
| `get_tick`, `fbar_to_key` | 3037–3079 | Host core mouse/timer leaf. |
| `copy_file` | 3110–3182 | Shared by file ops; keep central in M1 (see note in §1.2). |
| `set_panel_drive` and drive keys | 3199–3238 | Host core. |
| **All initialized data** (`fk_tbl`…`dumph`, lines 3593–3656) | 3593–3656 | Centralized; strings move to MSG table in a *later* M1 step, not this one. |
| `KEYBUF_MAX` equ + **entire `section .bss`** | 3661–3722 | Centralized per ROADMAP §5.1. |

### Moves into `mod/*.inc` (self-contained code blocks)

| Module file | Routines | Lines (inclusive) | Notes |
|---|---|---|---|
| `mod/harness.inc` | `open_dump`, `close_dump`, `dump_screen`, `load_keys`, `get_key`, `selftest`, `dbg_panel_line`, **`snap_vram`** | 1544–1660 **and** 3509–3591 | Test/dump harness. Two physical ranges (see §1.1) — keep `snap_vram`+`selftest` together as the harness tail. |
| `mod/shell.inc` | `run_command`, `get_comspec`, `build_tail`, `fill_epb`, `run_exec` | 1661–1807 | EXEC shell-out (Layer-0 but cleanly self-contained; safe first extraction). |
| `mod/fileops.inc` | `key_mkdir`, `key_delete`, `delete_one`, `key_copy`, `copy_one`, `count_tagged`, `streqi` | 2366–2614 | File-op handlers. `copy_file` (3110) stays in core for M1 (it sits in a different physical range; moving it would need a 2nd seam). |
| `mod/recurse.inc` | `set_dta_cur`, `cur_dta_ptr`, `make_findpat`, `del_tree`, `copy_tree` | 2615–2793 | Recursive tree walkers. |
| `mod/mouse.inc` | `mouse_hide`, `mouse_show`, `mouse_poll`, `mouse_hit`, `mouse_left`, `mouse_right`, `mouse_confirm`, `mouse_overwrite` | 2794–3036 | INT 33h block. (`get_tick`/`fbar_to_key` at 3037 stay in core — they're called from `start`/dispatch too.) |
| `mod/rename.inc` *(optional, see §1.2)* | `key_rename` | 3080–3109 | Small; could fold into `mod/fileops.inc` later. For M1, **leave in core** to avoid a non-contiguous file-ops file. |
| `mod/viewer.inc` | `key_view`, `view_move`, `view_build_lines`, `render_view` | 3239–3508 | **Caveat:** the `VIEW_MAX`/`MAX_VLINES`/`VIEW_ROWS`/`A_V*` `equ`s at lines 3232–3237 must **stay in `cc.asm`** (see §3). The include starts at `key_view` (3239), not at the comment banner. |

### 1.1 Harness is split across two physical ranges

The test/dump helpers live at **1544–1660** (`open_dump`…`get_key`) and the
diagnostic tail (`snap_vram`, `selftest`, `dbg_panel_line`) lives at **3509–3591**.
Byte-identical order forbids merging them into one contiguous include unless we
move bytes. So for M1, **harness becomes TWO includes** at their two current
spots, or stays in core. Recommended for M1: extract only the **3509–3591 tail**
as `mod/harness.inc` (one contiguous block) and leave 1544–1660 in core. Revisit
unification after the dispatch/string seams land.

### 1.2 Routines deliberately NOT moved in M1

- `copy_file` (3110–3182) — logically file-ops, but physically separated from the
  fileops block (2366–2614) by the recurse block and mouse block. Moving it would
  fragment `mod/fileops.inc`. Keep in core for M1.
- `key_rename` (3080–3109) — same reasoning; small, isolated. Keep in core.
- All shared leaf helpers (`u32toa`, `strlen`, `entry_ptr`, …) — too widely
  referenced; central.

---

## 2. Exact `%include` placement

In `-f bin`, the include must sit **at the line where the moved block currently
begins**, so the pasted text lands at the same address. Procedure per module:
delete the block's lines from `cc.asm`, insert the single `%include` line in
their place.

| Module | Delete lines | Insert this line at the (now-vacated) position |
|---|---|---|
| `mod/shell.inc` | 1661–1807 | `%include "mod/shell.inc"` (where line 1661 was) |
| `mod/fileops.inc` | 2366–2614 | `%include "mod/fileops.inc"` (where 2366 was) |
| `mod/recurse.inc` | 2615–2793 | `%include "mod/recurse.inc"` (where 2615 was) |
| `mod/mouse.inc` | 2794–3036 | `%include "mod/mouse.inc"` (where 2794 was) |
| `mod/viewer.inc` | 3239–3508 | `%include "mod/viewer.inc"` (where 3239 was) — leave the `equ`s 3232–3237 in core, just above this line |
| `mod/harness.inc` | 3509–3591 | `%include "mod/harness.inc"` (where 3509 was) |

Resulting `cc.asm` skeleton (textual order preserved):

```
  org 100h
  ... equ constants (19-83) ...
  start ... render ... dirmodel ... paths ... sort ... utils (86-1660)
  %include "mod/shell.inc"        ; was 1661-1807
  ... DLG equs + dialogs + pathbuild (1808-2365) ...
  %include "mod/fileops.inc"      ; was 2366-2614
  %include "mod/recurse.inc"      ; was 2615-2793
  %include "mod/mouse.inc"        ; was 2794-3036
  ... get_tick, fbar_to_key, key_rename, copy_file, drive keys (3037-3238) ...
  VIEW_MAX/MAX_VLINES/VIEW_ROWS/A_V* equ (3232-3237 — STAY HERE)
  %include "mod/viewer.inc"       ; was 3239-3508
  %include "mod/harness.inc"      ; was 3509-3591
  ... initialized data (3593-3656) ...
  KEYBUF_MAX equ + section .bss (3661-3722)
```

Note ordering subtlety: lines 3232–3237 (the viewer `equ`s + comment banner at
3229–3231) stay in `cc.asm`; the `%include` replaces only 3239 onward. The banner
comment may stay in core or move into the .inc — comments emit no bytes, so
either is byte-safe; keep it with the code (move it) for readability.

---

## 3. Risk analysis (byte-identical-ness)

**R1 — `equ` used before definition across a file boundary: SAFE.**
NASM does multi-pass `equ` resolution. Already proven in-file: `MM_BROWSER`
(used L189, defined L1835), `VIEW_MAX` ideas, etc. A module calling a core label
defined *later* in `cc.asm`, or a core line referencing a label defined inside a
later-included module, both resolve. No byte change.

**R2 — viewer `equ`s feeding `.bss` sizes: HANDLED by keeping them in core.**
`VIEW_MAX` (L3232) and `MAX_VLINES` (L3233) size `viewbuf` (L3715) and `lineoff`
(L3716) in `section .bss`. If these `equ`s moved into `mod/viewer.inc`, they would
*still* resolve (multi-pass), but it is cleaner and removes all doubt to **keep
them in `cc.asm`** just above the `%include "mod/viewer.inc"` line. Decision: keep
all `equ`s in core (ROADMAP §5.1 already mandates this).

**R3 — `section` directive inside an include: FORBIDDEN in M1.**
No module re-opens `.bss`/`.data`/`.text`. The single `section .bss` stays at
L3662 in `cc.asm`. Each module is plain implicit-`.text` code. This is the most
likely byte-shifter, so it is simply disallowed for M1.

**R4 — local-label scope across files: SAFE.**
`.loop`/`.ret`/etc. rebind under each module's leading global label. Every moved
block begins with a global label (`run_command`, `key_mkdir`, `del_tree`,
`mouse_hide`, `key_view`, `snap_vram`). No collisions.

**R5 — forward/back label calls crossing file boundaries: SAFE, but enumerate.**
Cross-file calls that exist after the split (all resolve at assemble time):
- `mod/shell.inc` → core: `get_comspec`/`build_tail`/`fill_epb`/`run_exec` are
  internal; `run_command` is *called from* core (`on_enter`/dispatch) — back-ref
  into the include, fine.
- `mod/fileops.inc` → core: calls `copy_file` (stays in core, L3110),
  `build_target_path`, `dlg_confirm`, `refresh_panels`, `count_tagged` (in file),
  `copy_tree`/`del_tree` (in `mod/recurse.inc` — cross-module call, fine).
- `mod/recurse.inc` → core/fileops: calls `copy_one`/`delete_one` (in fileops),
  `make_findpat` (in file), dialog/busy helpers (core). Fine.
- `mod/mouse.inc` → core: `dispatch`, `fbar_to_key` (core L3049), render helpers.
  Fine.
- `mod/viewer.inc` → core: `build_entry_path`, `get_key`, `dump_screen`
  (`dump_screen` is in core range 1544–1660). Fine.
- `mod/harness.inc` → core: `u32toa`, `entry_ptr`, `dbg_panel_line` (in file).
  `dump_screen`/`load_keys`/`get_key` stay in core (1544–1660), called from core
  + viewer; harness tail only owns `snap_vram`/`selftest`/`dbg_panel_line`. Fine.

**R6 — macros: NONE in M1.** No `%macro` is introduced in this step (KEYBIND etc.
are later M1 sub-tasks). So no "macro used before definition" risk.

**Net risk: very low.** The only real hazard (R3) is eliminated by rule. Expect a
byte-identical `cc.com`.

---

## 4. Verification recipe

### 4.1 Primary: byte-compare the binary

```
:: capture the baseline BEFORE any edit
copy cc.com cc_base.com
:: (or: git stash the working tree, build, copy out, unstash)

:: after each module extraction, rebuild and compare
nasm -f bin cc.asm -o cc.com
fc /b cc_base.com cc.com
```

`fc /b` prints `FC: no differences encountered` on success. Equivalent hash check
(PowerShell):

```
(Get-FileHash cc_base.com -Algorithm SHA256).Hash -eq (Get-FileHash cc.com -Algorithm SHA256).Hash
```

Also assert size stays **7,104 bytes** (`(Get-Item cc.com).Length`).

### 4.2 Fallback: headless harness (if bytes differ but behaviour shouldn't)

Per README "Build & test" + ROADMAP §6, if NASM ever shifts bytes the acceptance
bar drops to *behaviourally identical*. Run each `keys_*.bin` and diff `CCDUMP.TXT`:

```
run_test.ps1 -ccArgs /T -keyfile keys_<name>.bin    ; prints CCDUMP.TXT
```

Capture `CCDUMP.TXT` from `cc_base.com` first (rename to `CCDUMP_base.txt`), then
after the split, and `fc CCDUMP_base.txt CCDUMP.TXT`. Also `cc.com /D` (single
frame) as the smoke baseline.

Which key files exercise which moved code (so a regression points at a module):

| Moved module | Key file(s) to run | What it proves |
|---|---|---|
| `mod/viewer.inc` | a keyfile that presses **F3** on a file then scrolls (↑↓/PgUp/PgDn/Home/End) and Esc | `key_view`/`view_move`/`view_build_lines`/`render_view` |
| `mod/fileops.inc` | keyfiles pressing **F5/F6/F7/F8** + **Insert** (tag) on files/dirs | mkdir/copy/delete/rename/tag/count_tagged |
| `mod/recurse.inc` | F5/F8 on a **directory** (tree copy/delete), incl. overwrite path | `copy_tree`/`del_tree`/`make_findpat` |
| `mod/mouse.inc` | any `/T` run renders mouse-init; a keyfile can't move the mouse, so rely on `/D` frame + the dialog focus paths exercised via keyboard | `mouse_*` compile + dispatch wiring (mouse poll is INT 33h, hard to script — byte-compare is the real gate here) |
| `mod/shell.inc` | **Enter** on a `.COM/.EXE/.BAT`, or a typed command + Enter | `run_command`/`run_exec`/`build_tail` |
| `mod/harness.inc` | `/D` and `/T` themselves use it; `/S` exercises `snap_vram` | dump/snap/selftest |

> Note: `mod/mouse.inc` and `mod/shell.inc` are the hardest to validate by harness
> (mouse needs INT 33h; shell-out spawns COMMAND.COM). For these two especially,
> **rely on the byte-identical compare**, not behaviour, as the gate.

---

## 5. Recommended extraction ORDER (one module per commit, rebuild+verify between)

Bisectable, lowest-risk first (smallest, most isolated, fewest cross-calls):

1. **`mod/harness.inc`** (3509–3591) — diagnostic tail, called only by `/S` and
   `selftest`; nothing in the hot path. Easiest to prove with `/D`.
2. **`mod/viewer.inc`** (3239–3508) — self-contained; the `equ` caveat (R2) is the
   one thing to get right, so do it early while attention is on it.
3. **`mod/shell.inc`** (1661–1807) — isolated EXEC block; back-ref `run_command`
   only.
4. **`mod/mouse.inc`** (2794–3036) — contiguous INT 33h block.
5. **`mod/recurse.inc`** (2615–2793) — depends on fileops + dialog helpers, but is
   itself contiguous.
6. **`mod/fileops.inc`** (2366–2614) — last, because it has the most cross-module
   calls (into recurse + core `copy_file`); doing it last means every callee it
   references is already in a known-good location.

After each step: `nasm -f bin cc.asm -o cc.com && fc /b cc_base.com cc.com`. The
hash must match at **every** step. If a step diverges, only that one module moved,
so the regression is immediately localized.

`key_rename` (3080–3109) and `copy_file` (3110–3182) stay in `cc.asm` for all of
M1; fold them into `mod/fileops.inc` only after the dispatch-table seam lets the
file-ops block become non-contiguous-safe (a later M1 sub-task, not this split).

---

## Appendix — label → line-range map (from `grep ^[a-z_]…:` + section scan)

```
start                86     dispatch     234    render_all   551    draw_frames  581
main_loop           205     key_*        290-407 read_dir    956    draw_panel   732
key_enter           428     is_exec      475    accept_dta   988    pick_attr    778
set_active_cwd      537     build_search 1042   path_append 1070    draw_info    805
draw_titles         659     one_title    673   path_up     1091    draw_cmdline 845
init_panel_cwd      930     go_parent   1123   sort_panel  1187    draw_fkeys   883
order_cmp          1255     rank_of     1306?  format_entry 1306   clear_rowbuf 1376
u32toa             1391     entry_ptr   1422   cur_entry_ptr 1435  strlen      1444
strlen_di          1458     strcmp_ci   1468   rc_to_off    1500   putbuf      1514
hide_cursor        1530     show_cursor 1535   open_dump    1544   close_dump  1556
dump_screen        1565     load_keys   1606   get_key      1626   run_command 1661
get_comspec        1691     build_tail  1746   fill_epb     1775   run_exec    1787
dlg_box            1841     dlg_cell    1867   putzstr      1904   busy_box    1927
busy_name          1941     dlg_input   1974   dlg_field    2023   dlg_confirm 2056
dlg_draw_buttons   2120     dlg_overwrite 2147 ow_draw_buttons 2243 ow_one_btn 2263
build_entry_path   2281     build_target_path 2295  build_other_path 2305
bp_copy_dir        2319     bp_copy_name 2334  other_panel_ptr 2345 refresh_panels 2358
key_mkdir          2366     key_delete  2381   delete_one   2432   key_copy    2457
copy_one           2508     count_tagged 2543  streqi       2572   set_dta_cur 2615
cur_dta_ptr        2630     make_findpat 2643  del_tree     2668   copy_tree   2720
mouse_hide         2800     mouse_show  2809   mouse_poll   2819   mouse_hit   2879
mouse_left         2918     mouse_right 2954   mouse_confirm 2973  mouse_overwrite 2998
get_tick           3037     fbar_to_key 3049   key_rename   3080   copy_file   3110
key_tag            3183     key_drive_l 3199   key_drive_r  3202   set_panel_drive 3205
key_view           3239     view_move   3278   view_build_lines 3362  render_view 3392
snap_vram          3512     selftest    3543   dbg_panel_line 3553

equ constants:     19-83 (geometry/attr/struct) ; 1811-1838 (DLG_*/MM_*) ;
                   3232-3237 (VIEW_*/A_V*) ; 3661 (KEYBUF_MAX)
initialized data:  3593-3656 (fk_tbl … dumph)
section .bss:      3662 (align 2 … stacktop/prog_end at 3721-3722)
```
