# Claude Commander — modularity & feature roadmap

Status: **M2–M5 largely delivered.** Last updated 2026-06-23. See §0.

This document plans turning `cc` from a monolithic 7 KB `.COM` into a **modular**
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

## 0. Delivered (2026-06-23)

Every feature the user originally asked for is shipped, plus several roadmap
extras. The default `cc.com` (FEAT_STD) build is **at the resident wall**
(64,504 B, ~8 B free), so further *resident* features now require buffer
reclaim; new tools ship as external Layer-3 helpers (invoked by typing their
name at cc's prompt — `on_enter` already shells out via `run_command`).

**Resident modules (Layer 1, `mod/*.inc`, gated by `%ifdef`):**

| Feature | Key | Module | Commit |
|---|---|---|---|
| Clock (top-right HH:MM:SS) | — | clock.inc | c007c84 |
| Sort: name/ext/size/date | Ctrl-F1..F4 | sort.inc | 70c044d |
| Columns: size/date/time/attrs | Ctrl-F5 | cols.inc | 3e299b0 / 1ff023b |
| File-count + free-space + tagged footer | — | free.inc | f4dffce |
| Incremental quick-search | Ctrl-F6 | search.inc | b0fa646 |
| F9 pop-up command menu | F9 | menu.inc | d096a4a |
| Tag/untag by `*.mask` | Ctrl-F7/F8 | mask.inc | 8552881 |
| Edit file (launches CCEDIT) | F4 | edit.inc | b5aa5a4 |
| Find files (launches CCFIND) | Alt-F7 | find.inc | 0a33090 |
| List archive (launches CCZIP) | Ctrl-F9 | zip.inc | 2714b8b |
| `cc.ini` options loader (sort+columns) | — | ini.inc | a635151 |
| F1 help screen (pages `cc.hlp`) | F1 | help.inc | 7e796ea |
| Language: translate F-key bar via `cc.lng` | — | lang.inc | 20e8692 |
| LFN: cursor file's long name on command row | — | lfn.inc | c3a93ad |
| Grep contents (launches CCGREP) | Alt-F8 | grep.inc | 0ddd13c |
| Attribute editor (R/H/S/A) | Ctrl-A | attr.inc | 671ba32 |

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

**Runtime data files (Layer 2):** `cc.ini` (sort/columns), `cc.lng` (F-key bar
translation; `da.lng` shipped as a Danish sample), `cc.hlp` (F1 help text).

Notes on the two hard ones:
- **LFN** uses the memory-safe strategy from §3 option (a): panels keep 8.3
  names; only the cursor entry's long name is resolved on demand (INT 21h
  714Eh) and shown on the command row. Falls back to 8.3 cleanly when no LFN
  provider is present (bare DOS / DOSBox-staging). The fallback is verified;
  live long-name rendering needs an LFN provider (Win9x DOS / DOSLFN).
- **Language** currently translates the F-key bar (the most visible UI text)
  via `cc.lng`. A full `MSG(id)` string-table i18n (M1 seam #4) is not done;
  the F-key bar override is the pragmatic subset that fit the resident wall.

**Still open** (would need resident reclaim or stay external): full `MSG` string
table, F2 user menu (`cc.mnu`), remappable keys, command-line history,
bookmarks, colour themes, file associations, copy progress %, file
compare (CCDIFF), split/combine, multi-rename, brief/full/info view modes.
(Touch shipped as the CCTOUCH.COM helper, commit 8c004dc.)

---

## 1. The hard constraint: the 64 KB segment

A flat `.COM` is **one 64 KB segment** shared by code + data + `.bss` + stack.
Today (`cc.asm`):

| Consumer | Size |
|---|---|
| Code + initialized data (the emitted `cc.com`) | 7,104 B |
| `.bss` — `panelL`+`panelR` (2 × `PANELSIZE`, 512 entries × 24 B) | ~24.7 KB |
| `.bss` — `viewbuf` (`VIEW_MAX`, 16 KB viewer) | 16 KB |
| `.bss` — `snapbuf` (4000), stack (2048), small scratch | ~7 KB |
| **Resident image total** (measured by `build.ps1`: `0x100` PSP + code + all `.bss` + 2 KB stack) | **60,714 B (~59.3 KB)** |
| **Headroom left in the segment** (65,536 − 60,714) | **~4.7 KB** |

> The measured 60,714 B is authoritative — it equals the `mov ax, prog_end`
> immediate (`0xED2A`) the assembler bakes into `start` (`cc.asm:128`). The
> README's older "~51 KB" prose under-counted; treat **~4.7 KB** as the real
> resident headroom for the default build.

**Everything resident must fit in that ~4.7 KB.** This is *the* number to
respect — and it is far tighter than first assumed, which reshapes the plan:
the full `FEAT_FULL` resident set will **not** fit on top of today's image
without trading down a big buffer. The realistic levers are (a) push heavy
features external/overlay, and (b) under `FEAT_*` flags **reclaim** the two
fat buffers — `viewbuf` (16 KB) and the panel arrays (`MAX_FILES`, 24.7 KB) —
to make room. `build.ps1` enforces the wall so this can't be violated silently.
Consequences, baked into the plan below:

- Cheap resident features (sort, clock, columns, quick-search, menu bar,
  config loader, string table) each cost hundreds of bytes to ~2 KB — so even
  these must be **counted against the ~4.7 KB**, and a couple of them together
  already approach the wall. Build profiles, not "add everything," are how the
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

| Profile | Flags | Intended set | Target size |
|---|---|---|---|
| `ccmin.com` | `FEAT_MIN` | nav + view + basic file ops only | ≤ 5 KB |
| `cc.com` (default) | `FEAT_STD` | min + sort + columns + clock + quick-search + menu + config | ≤ 13 KB code; resident < 60 KB |
| `ccfull.com` | `FEAT_FULL` | std + LFN + find + hex + attrs + history + bookmarks | resident < 64 KB (hard) |

Budget guardrail: the script computes the resident paragraph count (same math
as `start` at `cc.asm:130`) and refuses anything that would push the segment
over ~63 KB, leaving stack room.

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
