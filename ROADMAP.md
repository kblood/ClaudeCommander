# Claude Commander — modularity & feature roadmap

Status: **M2–M5 largely delivered.** Last updated 2026-09-23. See §0.

This document plans turning `cc` from a monolithic 7 KB `.COM` (as it was in
June 2026) into a **modular**
file manager without breaking the size story. It records the chosen
architecture, a full feature catalogue (what becomes a module and *how*), the
memory budget that constrains everything, and a milestone sequence.

Decisions locked with the user (2026-06-22):

- **Modularity model = Hybrid.** Compile-time feature modules (`%include` +
  `%ifdef`) for resident features; **external programs** (via the existing
  EXEC shell-out) for heavy tools; **runtime data files** (`cc.ini`, `*.lng`,
  menus, help, themes) for everything configurable. No runtime-overlay plugin
  system yet — it's documented as a future escape hatch only.
- **First milestone = Foundations refactor.** No new user-facing features in
  M1; instead, build the seams (data-driven dispatch, string table, config
  loader, build profiles) that every later feature plugs into.

---

## 0. Delivered (2026-06-23, rows updated 2026-09-23)

Every feature the user originally asked for is shipped, plus several roadmap
extras. The default `cc.com` (FEAT_STD) build is code 18,949 B, resident
50,448 B vs the 64,512 B budget → **~14 KB free** since the far data segment
(`xseg`, `plan/memory_map.md`) moved ~13 KB of buffers out of the program
segment (`build.ps1` gates it). The opt-in `FEAT_LFN_FULL` build
(`cc-lfn.com`) is at 19,711 / 51,267 B; `CCPOP.COM` (no menu bar)
16,562 / 48,020 B; `ccmin.com` 8,757 / 39,142 B. Heavy features still ship
as external Layer-3 helpers (invoked by typing the name at cc's prompt —
`on_enter` already shells out via `run_command`). `configure.ps1` can also
trade features against each other for custom builds.

**Resident modules (Layer 1, `mod/*.inc`, gated by `%ifdef`):**

| Feature | Key | Module | Commit |
|---|---|---|---|
| Clock (HH:MM:SS; cmdrow/topright/off via cc.ini) | — | clock.inc | c007c84 / b5aa3cb |
| Panel views: full → brief 3-column → LFN (cycle) | Ctrl-F10 / Alt-F3 | views.inc | 8892902 / b5aa3cb |
| Pull-down menu bar + mouse open/select (STD) | F9 / click | menubar.inc | d581d5a / b1bb15b / b5aa3cb |
| Sort: name/ext/size/date | Ctrl-F1..F4 | sort.inc | 70c044d |
| Columns: size/date/time/attrs | Ctrl-F5 | cols.inc | 3e299b0 / 1ff023b |
| File-count + free-space + tagged footer | — | free.inc | f4dffce |
| Incremental quick-search | Ctrl-F6 | search.inc | b0fa646 |
| F9 pop-up command menu (**CCPOP.COM only**; STD has the pull-down bar) | F9 | menu.inc | d096a4a |
| Tag/untag by `*.mask` | Ctrl-F7/F8 | mask.inc | 8552881 |
| Edit file (launches CCEDIT) | F4 | edit.inc | b5aa5a4 |
| Find files (launches CCFIND) | Alt-F7 | find.inc | 0a33090 |
| List archive (launches CCZIP) | Ctrl-F9 | zip.inc | 2714b8b |
| `cc.ini` options loader (sort+columns) | — | ini.inc | a635151 |
| F1 help screen (pages `cc.hlp`) | F1 | help.inc | 7e796ea |
| Language: translate F-key bar via `cc.lng` | — | lang.inc | 20e8692 |
| LFN: cursor file's long name on command row | — | lfn.inc | c3a93ad |
| Grep contents (launches CCGREP) | Alt-F8 | grep.inc | 0ddd13c |
| Find/grep matches → browsable results panel | Alt-F7/F8 + Enter | results.inc | v1.0.6 |
| Drives view (all drives as an openable list) | Alt-F1/F2 | results.inc | ce493f9 |
| Attribute editor (R/H/S/A) | Ctrl-A | attr.inc | 671ba32 |
| Modal directory-tree browser | Alt-F10 | tree.inc | 07f0928 |
| Tools pull-down (runs the bundled helpers) | Tools menu | tools.inc | 0573128 |
| User `[tools]` menu rows (a-la-carte flag) | — | toolsini.inc | (TOOLS_INI) |
| Live helper discovery (gates helper keys) | — | discover.inc | 0a97583 |
| Human-readable size column (K/M/G) | — | cc.asm `fmt_size` | 3bf9d42 |
| LFN panel view mode (on-demand long names) | view mode | lfnview.inc | 71a8a67 |
| Archive-as-folder browse / extract / pack (`[open]` map) | Enter / F5 / Alt-F9 / Alt-F5 | vfs.inc | 9594ef8 (+ GOALS G1/G2, db1a9de) |
| F6 move (editable dest) / Shift-F6 rename in place | F6 / Shift-F6 | fileops.inc / cc.asm | 6510e14 |

**External helpers (Layer 3, separate `.COM`, zero resident cost):**

| Tool | Purpose | Commit |
|---|---|---|
| CCEDIT.COM | full-screen text editor | b5aa5a4 |
| CCFIND.COM | recursive find-by-name | 0a33090 |
| CCZIP.COM | list ZIP central directory | 2714b8b |
| CCGREP.COM | recursive content search (path:line) | 0ddd13c |
| CCHEX.COM | hex + ASCII dump (binary viewer) | 4f4a6ce |
| CCSUM.COM | CRC-32 + byte size | 01bda41 |
| CCTOUCH.COM | set file date/time (now or explicit) | 8c004dc |
| CCHEXED.COM | overwrite-only hex editor | bc3274f |
| CCD64.COM | browse + extract C64 1541 `.d64` | 45b60fd |
| CCT64.COM | browse + extract C64 `.t64` | 837766a |
| CCARJ.COM | browse + extract ARJ (STORED) | 1c6d2e7 |
| CCRAR.COM | browse + extract RAR 4.x (STORED) | 46d20f7 |
| CCIMG.COM | image viewer (BMP/PCX/GIF, mode 13h) | 3de016d |
| CCWAV.COM | WAV player (PCM, Sound Blaster) | c1627f3 |
| CCDIFF.COM · CCSPLIT/CCJOIN.COM · CCREN.COM | compare / split-join / multi-rename | 3a72ca6 |
| CCPAK.COM | browse Quake `.pak` | e989435 |
| CCMDL.COM | Quake `.mdl` 3D model viewer (experimental) | e989435 |

**Runtime data files (Layer 2):** `cc.ini` (sort/columns, clock, editor, the
`[open]`/`[view]` association maps, opt-in `[tools]`), `cc.lng` (F-key bar
translation; `da.lng` shipped as a Danish sample), `cc.hlp` (F1 help text).

**Safety & robustness (2026-09):**

| Area | What landed |
|---|---|
| F6 / copy | Move never deletes the source after a failed or partial copy (`cp_fail`); refuses dir-into-own-subdir; copy-onto-self detected via `TRUENAME` |
| Panel guards | F8 / F6 / Shift-F6 / Ctrl-A / F4 / hex edit refuse on archive, results and drives panels |
| Host core | Typed commands & Tools run in the active panel's folder; `INT 24h` critical-error handler; bounded cmdline / F-key labels / command tail / `P_PATH`; `.bss` zeroed at startup |
| Extractors | ZIP/PAK/RAR/ARJ/D64/T64 extraction can't escape the dest dir; extract-all never overwrites |
| Parsers | Malformed-input hangs/overruns fixed in INFLATE, GIF, BMP, PCX, WAV, RAR, D64 |
| Editors / tools | CCEDIT safe save (`.$$$` temp + rename) and >48 KB refusal; save-on-quit prompts in CCEDIT/CCHEXED; CCSPLIT/CCJOIN refuse to clobber their inputs; CCREN honours the source dir; CCTOUCH validates dates |
| Exit codes | CCDIFF 0/1/2; CCGREP 0 = match / 1 = none; extractors 1 on failure |
| wincc | Move/delete data-loss fixes (dir-into-self, junctions never followed); viewer heap overflow; UTF-8 cd-on-exit |
| Build / dist | `build_dist.ps1` always rebuilds; failed builds never overwrite binaries; `INSTALL.BAT` DOS-compatible via the `ccpop.asm` wrapper |
| Tests | `run_all.ps1` gate + `run_safety` / `run_czip_safety` / `run_fileops_safety` / `run_parsers_safety` |

Notes on the two hard ones:
- **LFN** uses the memory-safe strategy from §3 option (a): panels keep 8.3
  names; only the cursor entry's long name is resolved on demand (INT 21h
  714Eh) and shown on the command row. Falls back to 8.3 cleanly when no LFN
  provider is present (bare DOS / DOSBox-staging). The fallback is verified;
  live long-name rendering needs an LFN provider (Win9x DOS / DOSLFN).
  Since then `lfnview.inc` added an on-demand long-name panel view (third
  step of the Ctrl-F10 cycle), and the opt-in `FEAT_LFN_FULL` build adds LFN
  file ops + 714Eh/714Fh enumeration with FILETIME→DOS dates (39ccfe0).
- **Language** currently translates the F-key bar (the most visible UI text)
  via `cc.lng`. A full `MSG(id)` string-table i18n (M1 seam #4) is not done;
  the F-key bar override is the pragmatic subset that fit the resident wall.

**Still open** (would need resident reclaim or stay external): full `MSG` string
table, F2 user menu (`cc.mnu`), remappable keys, command-line history,
bookmarks, colour themes, and copy/move progress %.
(Shipped as helpers/config instead: touch = CCTOUCH.COM (8c004dc); file
compare = CCDIFF; split/combine = CCSPLIT/CCJOIN; multi-rename = CCREN;
file associations via the `cc.ini` `[open]`/`[view]`/`[tools]` maps; the
brief 3-column view (views.inc) and the tree browser (tree.inc) are in.)

---

## 1. The hard constraint: the 64 KB segment

A flat `.COM` is **one 64 KB segment** shared by code + data + `.bss` + stack.
Current default build (FEAT_STD, 2026-09-23, measured by `build.ps1`):

| Consumer | Size |
|---|---|
| Code + initialized data (the emitted `cc.com`) | 18,949 B |
| `.bss` — `panelL`+`panelR` (2 × `PANELSIZE` = 2 × (156 + 512 entries × 24 B)) | 24,888 B |
| `.bss` — everything else (1 KB stack, DTA stack, ini maps, scratch) | ~6.3 KB |
| **Resident image total** (`0x100` PSP + code + all `.bss`) | **50,448 B** |
| **Budget** (`build.ps1` std: resident < 63 KB = 64,512 B) | **~14 KB headroom** |
| *Outside the segment* — far block `xseg`: `viewbuf` 8 KB, `lineoff` 2 KB, `res_heap` 3 KB | ~13 KB |

Other profiles (resident): `FEAT_LFN_FULL` (`cc-lfn.com`) 51,267 B (~13 KB
headroom); `CCPOP.COM` 48,020 B; `FEAT_MIN` 39,142 B.

Until 2026-09-23 the three `xseg` buffers were in the `.bss` and the STD
image was 63,637 B (875 B headroom, 56 B for LFN). Moving them out is step 1
of `plan/memory_map.md`; step 2 (panel entry arrays → far segment, lifting
the 512-files cap) and step 3 (code overlays) are designed there.

> The measured resident figure is authoritative — it equals the
> `mov ax, prog_end` immediate the assembler bakes into `start`. *Historical:*
> at the M1 refactor (June 2026) the image was 7,104 B code / 60,714 B
> resident with a 16 KB `viewbuf` and ~4.7 KB headroom; `VIEW_MAX` has since
> been halved to 8 KB and `snapbuf` gated behind `FEAT_SNAP` to make room.

**Everything new and resident must fit in that ~14 KB** (~13 KB for the LFN
build). This is *the* number to respect. The realistic levers are (a) push
heavy features external/overlay, (b) move more data to far blocks (the panel
arrays, `MAX_FILES` 512, ~24.3 KB, are next), and (c) under `FEAT_*` flags
reclaim buffers. `build.ps1`
enforces the budget so this can't be violated silently.
Consequences, baked into the plan below:

- Cheap resident features (sort, clock, columns, quick-search, menu bar,
  config loader, string table) each cost hundreds of bytes to ~2 KB — so each
  new one must be **counted against the remaining headroom**. Build profiles,
  not "add everything," are how the
  default stays buildable.
- RAM-hungry features (LFN names, archive directory parsing, a built-in
  editor) either (a) ship as **external** programs, (b) **trade** against
  existing buffers (e.g. shrink `viewbuf` or `MAX_FILES` under a build flag),
  or (c) wait for a future **overlay** loader. Each such feature notes its
  strategy.
- Build profiles let the **default `cc.com` stay small** while a `FEAT_FULL`
  build uses more of the headroom. The build script enforces a size budget.

---

## 2. The hybrid architecture (four layers)

```
  Layer 3  External helpers   CCEDIT.COM  CCZIP.COM  CCFIND.COM  ...
           (separate binaries, invoked via EXEC; reuse run_command path)
  ----------------------------------------------------------------------
  Layer 2  Runtime data       cc.ini   en.lng/da.lng   cc.mnu   help.txt
           (no rebuild needed; read by a generic ini/string loader)
  ----------------------------------------------------------------------
  Layer 1  Resident modules   mod/sort.inc  mod/clock.inc  mod/cols.inc ...
           (%include, gated by %ifdef FEAT_x; selected by build profile)
  ----------------------------------------------------------------------
  Layer 0  Host core          video  dispatch  panel model  read_dir
           (always present)    render  dialogs  EXEC  mouse  ini loader
```

### Decision rule — where does a feature live?

1. **Small, tightly coupled to the panel/render loop?** → Layer 1 resident
   module behind `%ifdef`. (sort, columns, clock, quick-search, menu bar,
   attribute editor, bookmarks.)
2. **Pure configuration / text / translatable?** → Layer 2 data file read at
   startup. (themes, key remaps, language strings, user menu, help, file
   associations.)
3. **Big code or big RAM, runs to completion then returns?** → Layer 3
   external `.COM`, launched through EXEC with the selection passed in.
   (editor, archive pack/unpack, find-in-files, file compare, checksums.)
4. **Big *and* needs deep host integration (live panel callbacks)?** → defer
   to a future Layer-4 overlay. Only if a real case demands it.

### The three foundation seams (built in M1)

These are what make Layer 1 "modular" instead of "edit one giant chain":

- **Data-driven key dispatch.** Replace the flat `cmp ah,XX / je handler`
  chain (`cc.asm:234`) with a table of `{ascii, scan, handler_ptr}` rows. A
  `KEYBIND` macro lets each `mod/*.inc` append its own rows. Adding a feature
  = include its file; no surgery on a central routine.
- **Data-driven menu + F-key bar.** A menu/label tree built from table entries
  that modules contribute to, so the F9 menu and the bottom bar assemble
  themselves from whatever features are compiled in.
- **UI string table + `MSG(id)`.** Every user-visible `db "..."` string moves
  into an indexed table; code references `MSG(id)`. The compiled-in table is
  English; a `.lng` file can override entries at load. This single change
  unlocks i18n *and* makes themes/menus translatable.

### Module file convention (Layer 1)

```
  mod/<name>.inc
    ; %ifdef FEAT_<NAME>
    ; - KEYBIND rows for any keys it owns
    ; - MENUITEM rows for any menu entries
    ; - its handlers (self-contained)
    ; - its own .bss block (so RAM cost is visible per module)
    ; %endif
```

*As built:* modules own their handlers, menu rows and `.bss`, but every
`KEYBIND_*` row lives in the single `keytab` in `cc.asm` (each wrapped in its
feature's `%ifdef`); only `FEAT_TOOLS_INI` adds keys at runtime (`ukeytab`).

### External helper convention (Layer 3)

Host writes the selection (cursor entry or tagged set) to a temp list file,
then EXECs the helper with the list path on its command tail; helper does its
job and returns; host refreshes both panels. Reuses `run_command` /
`run_exec` / DTA save-restore that already exist.

---

## 3. Feature catalogue

Legend: **[R]** resident module (Layer 1) · **[D]** runtime data (Layer 2) ·
**[X]** external helper (Layer 3) · **[O]** future overlay (Layer 4).
"Cost" is rough resident bytes; **0** for [D]/[X] (lives outside the image).

### Display & browsing

| Feature | Where | Cost | Notes |
|---|---|---|---|
| Sort menu — name / ext / size / date / unsorted | [R] | ~0.6 KB | `sort_panel`/`order_cmp` already exist; add a sort-key setting + a small dropdown. Persist to `cc.ini`. |
| Display columns — size / modified date+time / attrs | [R] | ~0.8 KB | Panel is 38/39 cols wide; needs a brief/full layout switch (see below). |
| View modes — brief (names only) / full (name+size+date) / info (single-column + details pane) | [R] | ~1 KB | Toggle per panel; remembered in `cc.ini`. |
| Quick-search / incremental filter (type letters → jump/filter) | [R] | ~0.7 KB | Norton-style; Esc cancels. |
| File-mask filter (`+`/`-` to gray or select by `*.EXT`) | [R] | ~0.6 KB | Uses existing tag machinery. |
| Clock (top-right `HH:MM:SS`) | [R] | ~0.3 KB | INT 1Ah / INT 21h 2Ch; redraw on the main loop tick. |
| Free-space + file count footer | [R] | ~0.4 KB | INT 21h 36h for free space. |
| Colour themes | [D] | 0 | Theme = the `A_*` attribute set; load from `cc.ini [theme]`. |
| Directory size (compute tree bytes for cursor dir) | [R] | ~0.5 KB | Reuses the recursive walker. |
| Bookmarks / directory hotlist | [R]+[D] | ~0.5 KB | List stored in `cc.ini`. |

### Long file names (LFN)

| Feature | Where | Cost | Notes |
|---|---|---|---|
| VFAT LFN read (INT 21h 71h: FindFirst/Next 4E/4F variants) | [R] | see notes | **RAM problem:** 255-byte names × 512 entries = 128 KB, impossible in one segment. Strategy options, decided in M4: (a) store a **truncated** long name per entry (e.g. 20 B) + fetch full name on demand for the cursor only; (b) reduce `MAX_FILES` and store medium names; (c) a separate long-name heap carved from a smaller `viewbuf` under `FEAT_LFN`. Accessors added in M1 so the storage choice is swappable. |

### Menus, config, language

| Feature | Where | Cost | Notes |
|---|---|---|---|
| Dropdown menu bar (F9, Norton/VC pull-downs) | [R] | ~1.5 KB | Built from the data-driven menu tree (M1 seam). Mouse-clickable like existing dialogs. |
| F2 user menu (commands defined in `cc.mnu`) | [R]+[D] | ~0.5 KB | Reads a simple menu text file. |
| F1 help screen | [R]+[D] | ~0.4 KB | Pages `help.txt` through the existing viewer. |
| Config file `cc.ini` (persist all settings) | [R]+[D] | ~1 KB | Generic `[section] key=value` reader in the host core; the backbone of Layer 2. |
| Remappable keys (`keys.cfg`) | [D] | 0 | Overrides the dispatch table's `{ascii,scan}` at load. |
| Language files (`*.lng`, ship `en` + `da`) | [D] | 0 | Override the `MSG` string table. Danish first (user is Danish). |
| Command-line history (↑/↓ recall) | [R] | ~0.5 KB | Small ring buffer. |
| File associations (open by extension) | [R]+[D] | ~0.4 KB | `[assoc] txt=CCEDIT.COM` etc. drives Enter / F-key. |

### Heavy tools (external first)

| Feature | Where | Cost | Notes |
|---|---|---|---|
| Text editor (F4) | [X] then maybe [O] | 0 | Start as external `CCEDIT.COM` (or shell to `EDIT.COM`). A built-in editor is a strong overlay candidate later. |
| Archive-as-folder — browse/extract `.zip` (later `.arj`,`.lzh`,`.rar`) | [X]+[R] | ~1 KB browse / 0 pack | Browsing needs to read the zip central directory (moderate parse) — do it in an external `CCZIP.COM` that emits a listing the panel shows as a virtual dir (`zip:\FOO.ZIP\...`); pack/unpack are external. Pure VFS-in-host is an overlay candidate. |
| Find files (name across a tree) | [R] or [X] | ~0.8 KB | Name-only search can be resident (reuses the walker); content grep should be external. |
| Grep-in-files (content search) | [X] | 0 | External `CCGREP.COM`. |
| Hex view mode in the viewer | [R] | ~0.6 KB | Extend `key_view`/`render_view` with a hex toggle. |
| File compare / diff | [X] | 0 | External `CCDIFF.COM` on two selected files. |
| Checksum / CRC32 / MD-style | [X] | 0 | External; results to a dialog. |
| Split / combine large files | [X] | 0 | External. |
| Multi-rename tool (batch pattern rename) | [R] or [X] | ~0.7 KB | Tagged set + a pattern dialog. |

### File-operation extras

| Feature | Where | Cost | Notes |
|---|---|---|---|
| Attribute editor (toggle R/H/S/A) | [R] | ~0.5 KB | INT 21h 43h. |
| Touch (set date/time) | DONE | 0 KB | Shipped as CCTOUCH.COM (8c004dc), INT 21h 5701h. |
| cd-on-exit (leave shell in active panel's dir) | DONE | ~0 KB | INT 21h 0Eh+3Bh at terminate; DOS keeps CWD as global state. Norton/Volkov style. |
| Copy/Move byte-progress % | [R] | ~0.4 KB | Extend the existing busy box. |
| Preserve timestamps/attributes on copy | [R] | ~0.3 KB | Read+reapply during `copy_file`. |
| Verify-after-copy | [R] | ~0.5 KB | Optional re-read+compare. |

### Nice-to-have / later

Print file (LPT); screen blanker / idle screensaver; configurable panel split
ratio (not just 38/39); two-line status with the full long path; "swap panels"
and "panels = same dir" quick keys; tree-view panel mode; FTP/network panel
(far future, external only).

---

## 4. Build profiles & size budget

`build.ps1` produces named profiles by passing `-d<flag>` to NASM, and **fails
the build if the image exceeds budget**:

| Profile | Flags | Intended set | Budget (enforced) | Current (2026-09-23) |
|---|---|---|---|---|
| `ccmin.com` | `FEAT_MIN` | nav + view + basic file ops only | code ≤ 9 KB | 8,757 B code / 39,142 B res. |
| `cc.com` (default) | `FEAT_STD` | min + every shipped resident module (§0) | code ≤ 19 KB; resident < 63 KB | 18,949 / 50,448 B |
| `ccfull.com` | `FEAT_FULL` | currently == STD | resident < 63.5 KB | (as STD) |
| `cc-lfn.com` | `FEAT_STD` + `FEAT_LFN_FULL` | std + LFN file ops/enumeration | resident < 63 KB | 19,711 / 51,267 B |

(`CCPOP.COM` is built by `package.ps1`, not `build.ps1`: STD without
`FEAT_MENUBAR`, 16,562 / 48,020 B.)

Budget guardrail: the script recovers the resident size from the NASM listing
(same math as the `prog_end` paragraph count in `start`) and refuses anything
over budget; a failed build never overwrites an existing binary. *Historical
targets from the June 2026 plan were ≤ 5 KB (min), ≤ 13 KB code / < 60 KB
resident (std) and < 64 KB (full).*

---

## 5. Milestone sequence

### M1 — Foundations (no new user features) ← START HERE

Goal: introduce the seams with **zero behaviour change**. Acceptance = the
`FEAT_STD` build is behaviourally identical to today and the headless harness
(`/D`, `/T` keyfiles) stays green.

1. ✅ **DONE.** Split `cc.asm`: host core stays in `cc.asm`; carved 6 feature
   areas into `mod/*.inc` (`shell`, `fileops`, `recurse`, `mouse`, `viewer`,
   `harness`) included at the current spots. Each extraction verified
   **byte-identical** (`cc.com` SHA-256 unchanged at every step; 7,104 B).
   `cc.asm` 3722 → 2557 lines; 1,189 lines moved out.
2. ✅ **DONE.** Data-driven key dispatch: `KEYBIND_EXT/ASC/END` macros + a
   `keytab` walked by `dispatch:`, replacing the `cmp ah,XX/je` chain. Modules
   can now register keys by emitting rows before `KEYBIND_END`. Not
   byte-identical (intended), so verified **behaviourally identical** — old vs
   new binary run back-to-back in a frozen dir across the dispatch/nav/view
   `/T` keyfiles showed 0 real diffs (only the CC.COM/CC.ASM size columns moved).
   Binary shrank 7104 → 7100 B.
3. **Data-driven menu + F-key bar** registration; reproduce today's bar.
4. **UI string table** + `MSG(id)`; move all current strings into it.
5. **`cc.ini` loader** (generic section/key reader) + a settings struct;
   nothing reads settings yet beyond a smoke key.
6. **Build profiles** (`build.ps1`, FEAT_MIN/STD/FULL) + size-budget check.
7. **LFN groundwork:** wrap entry-name access in accessors so M4 can swap the
   storage model without touching call sites.

### M2 — Core in-panel UX (resident, cheap)
Sort dropdown · display columns + brief/full/info view modes · clock ·
quick-search · file-mask filter · free-space footer · themes from `cc.ini`.
(Each lands as a `mod/*.inc`; settings persist via M1's loader.)

### M3 — Menu / shell
F9 pull-down menu bar · F1 help (`help.txt`) · F2 user menu (`cc.mnu`) ·
remappable keys (`keys.cfg`) · language files (ship `en.lng` + `da.lng`) ·
command-line history.

### M4 — LFN + file-op polish
Pick & implement the LFN storage strategy (§3) · attribute editor · touch ·
copy progress % · preserve timestamps · associations · bookmarks.

### M5 — Heavy / external
`CCEDIT.COM` (F4) · archive-as-folder (`CCZIP.COM` + virtual-dir browse) ·
find files / grep · hex view mode · file compare · checksums · multi-rename.
Revisit whether the editor or archive VFS earns a Layer-4 overlay.

---

## 6. Open questions / risks

- **LFN storage** is the one feature that genuinely fights the 64 KB wall;
  resolve the strategy at the top of M4, not before.
- **Byte-identical refactor**: M1 must prove the split didn't change output.
  If NASM section ordering shifts bytes, fall back to "behaviourally
  identical + harness-green" as the acceptance bar.
- **Archive browsing** as a true in-panel VFS is the most likely thing to
  outgrow [X] and want [O]; keep the virtual-dir path syntax (`zip:\...`)
  designed so an overlay could later take it over transparently.
