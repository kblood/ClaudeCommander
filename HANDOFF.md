# Claude Commander (`cc`) — session handoff

Cold-start brief for a fresh session. Read this first, then `ROADMAP.md` §0
(the delivered-feature table) and `README.md`. Last updated 2026-06-29.

`cc` is a Norton/Volkov-style two-panel DOS file manager in hand-written 16-bit
x86 NASM assembly, built as a flat `.COM`. The repo root **is** a git repo
(branch `main`); all feature work is committed locally but **not pushed** —
push only when the user explicitly asks.

---

## ⚠ Latest session (2026-06-29): UX fixes & features — UNCOMMITTED

Nine fixes/features from the last session. **All changes are in the working tree
only — nothing is committed yet.** The `FEAT_STD` (`CC.COM`) and the
`FEAT_MENU`/no-menubar `CCPOP.COM` builds both pass via `package.ps1` (exit 0).

| # | Change | Where |
|---|---|---|
| 1 | **PgDn now == Right arrow.** `key_pgdn` reloaded the page count that `VD_PAGE` had clobbered in `cl`. | `cc.asm` `key_pgdn` |
| 2 | **Flicker-free rendering.** Double-buffer: `render_all` composes into `bufseg` then `blit_buf` does one `rep movsw` to VRAM. `vseg`/`bufseg` vars; buffer alloc via `AH=48h` (250 paras) after the `AH=4Ah` shrink; `clear_bg` moved to startup. All `mov ax,VIDEO` → `mov ax,[vseg]` across `cc.asm` + 9 `.inc`s. | `cc.asm`, all `mod/*.inc` |
| 3 | **Top-right corner glyph.** `frame_row` used `imul ax,…;mov di,ax`, clobbering AL (the corner char). Now `imul bx,ROW_BYTES;mov di,bx`. | `cc.asm` `frame_row` |
| 4 | **Configurable clock.** `clock = cmdrow\|topright\|off` in `cc.ini`. `clock_pos` 0/1/2; `CLK_TR_ROW` guarded so the no-menubar CCPOP build still assembles. | `mod/clock.inc`, `mod/ini.inc`, `cc.ini` |
| 5 | **Mouse opens menus.** Click a bar title (Files/Commands/Options/Tools) from the file view → `mb_bar_hit` returns a synthetic F9 with `mb_click` set; `key_menubar` consumes it. In-menu modal loop also polls the mouse (pick item / hop menus / outside-click closes). | `mod/mouse.inc`, `mod/menubar.inc` |
| 6 | **3-column brief view reachable.** Always existed but `Ctrl-F10` is eaten by DOSBox → added `Alt-F3` keybind (scan 6Ah) + an Options-menu entry. | `cc.asm` keytab, `mod/menubar.inc` |
| 7 | **3-col LEFT-panel names visible.** `draw_panel_brief` gave cols 0,1 the full `pcw`, so the right panel's column wrapped onto the left panel's row. Now cols 0,1 = `BRIEF_PITCH` wide, last col takes the remainder. | `mod/views.inc` |
| 8 | **Mouse cursor can't get "lost".** `mouse_hide`/`mouse_show` are idempotent against a new `mouse_vis` flag so the INT 33h show/hide counter only sits at 0 or −1. | `mod/mouse.inc`, `cc.asm` `.bss` |
| 9 | **Clock paints over menubar** for `topright`: `mb_bar_draw` widget ordered before `draw_clock` in `wtab`. | `cc.asm` `wtab` |

**Verified headlessly** (`/D`, `/T` byte-identical dumps; budget green; CCPOP
build green). **NOT verifiable headlessly** — needs a real DOSBox run via
`.\run_cc.ps1`: actual mouse clicks (the `/T` harness injects keystrokes only,
never INT 33h events) and the visual absence of flicker. Ask the user to
sanity-check those interactively before committing.

---

## Where work happens

| Path | What |
|---|---|
| `cc.asm` | the host core + tier block + keytab + `.bss`; `%include`s every module |
| `mod/*.inc` | resident feature modules, each behind `%ifdef FEAT_*` |
| `cce.asm cfind.asm czip.asm cgrep.asm chex.asm csum.asm` | external Layer-3 helpers (separate `.COM`s) |
| `cc.ini cc.lng cc.hlp da.lng` | runtime data files (config, language, help, Danish sample) |
| `build.ps1` | builds all tiers, enforces the size budget |
| `run_test.ps1` + `keys_*.bin` | headless `/T` harness driver |
| `run_*.ps1` | per-helper test drivers (`run_grep`, `run_hex`, `run_attr`, `run_lfn`, …) |
| `ROADMAP.md` | architecture + full feature catalogue; §0 = delivered list |
| `plan/*.md` | M1 refactor notes (dispatch, split, strings) |

---

## Build & the size wall (the #1 constraint)

```
nasm -f bin cc.asm -o cc.com          # bare build == FEAT_STD (default tier)
powershell .\build.ps1                # builds all tiers + budget check
```

- Flat `.COM` = **one 64 KB segment** shared by code + data + `.bss` + stack.
- `build.ps1` fails the build if resident ≥ **64,512 B**. Resident =
  `0x100` + emitted code + all `.bss` (the `resb` reserves count even though
  they're not in the file).
- **FEAT_STD is AT THE WALL: 64,504 B resident, ~8 bytes free.** Any new
  *resident* code/`.bss` overflows. To add resident features you must first
  reclaim space (trim a buffer under a flag, e.g. `viewbuf`/`snapbuf`/
  `MAX_FILES`). Otherwise ship the feature as an **external helper** (free).
- Tiers: `FEAT_MIN` / `FEAT_STD` (default) / `FEAT_FULL`. Cumulative, selected
  by `-d<flag>`. The tier block is near the top of `cc.asm` (`%if _TIER >= 2`
  defines the STD feature set; `>= 3` is reserved/empty now).

---

## Test harness

```
# ALWAYS run from PowerShell, NOT the Bash tool (see gotchas):
.\run_test.ps1 -ccArgs "/T" -keyfile keys_xxx.bin
```

- `cc.com /T` replays a keystroke file `cc.key` (byte pairs `[ascii, scan]`),
  dumping the 80×25 screen to `CCDUMP.TXT` after every frame. Exhausted keys
  return F10 (`00 44`) so sub-loops exit cleanly.
- `cc.com /D` dumps one frame and exits. `/S` snaps VRAM to `CCSNAP.BIN`.
- `cc.key` must live in the **CWD cc runs from** (cc opens it relative). Same
  for `cc.ini`/`cc.lng`/`cc.hlp`.
- Self-contained key sub-loops (menu, search, help, viewer, attr editor) all
  call `get_key`, so the harness drives them too.
- External helpers print to stdout → test by redirecting (`> out.txt`) and
  inspecting, or (CCEDIT) by checking the saved file, or (CCATTR) by checking
  the host file's attributes after.

---

## Adding a resident feature (the module pattern)

1. `mod/<name>.inc` — handler(s), self-contained, with its own `.bss` if any.
2. `%define FEAT_<NAME>` in the tier block in `cc.asm`.
3. `%include "mod/<name>.inc"` in the includes section (inside `%ifdef`).
4. A `KEYBIND_EXT`/`KEYBIND_ASC` row in `keytab` (inside `%ifdef`).
5. Optional: a `menu_tbl` row + label in `mod/menu.inc`.
6. Optional: a line in `cc.hlp`.
7. Build; confirm still under the wall. Test via `/T`.

Adding an **external helper**: write `cXXX.asm` (`org 100h`, `nasm -f bin`),
print to stdout. No cc change needed — `on_enter` already shells out anything
typed at the prompt, so `CCXXX <args>` just works. Optionally add a launcher
module (costs resident bytes — mind the wall) and a `cc.hlp` line.

---

## Delivered (see ROADMAP.md §0 for the full table + commits)

Resident modules: clock (cmdrow/topright/off via cc.ini) · sort (Ctrl-F1..F4) ·
columns size/date/time/attrs (Ctrl-F5) · free+tagged footer · quick-search
(Ctrl-F6) · F9 pull-down menu bar (mouse-openable) · brief 3-col view
(Ctrl-F10/Alt-F3) · tag-by-mask (Ctrl-F7/F8) · attribute editor R/H/S/A (Ctrl-A) ·
F1 help · language/F-key-bar (cc.lng) · LFN cursor long-name · launchers
F4/Alt-F7/Alt-F8/Ctrl-F9. Rendering is double-buffered (flicker-free).

External helpers: CCEDIT · CCFIND · CCZIP · CCGREP · CCHEX · CCSUM.

F5/F6 (commit 6510e14): F5 copies and F6 *moves* the cursor entry (or all
tagged) to the OTHER panel; both prompt with the destination name pre-filled so
editing it renames in flight. Same-drive moves use one DOS rename (files +
trees); cross-drive falls back to copy+delete. Shift-F6 = rename in place.

---

## Container browser — the [open] plugin framework (IN PROGRESS)

Total-Commander-style packer plugins; ext→helper map in cc.ini `[open]`.

- **DONE — browse (commit 9594ef8):** Enter on a `.zip` opens it as a folder
  (virtual panel: P_VFS + P_CNAME). cc runs `<helper> L <file> >CCVFS.LST` via a
  silent `run_helper` (NOT run_command — that re-reads panels and would recurse
  through a VFS panel's read_dir), parses `<size> <name>` lines into the entry
  array with a synthetic `..`, deletes the scratch file. Backspace / `..`
  (go_parent) exits and re-reads the real folder (P_PATH is preserved). Panel
  title shows the container name. CCZIP gained an `L` machine-list mode;
  ext→helper parsed by `open_lookup`/`openmap` (ini.inc). Verified GREEN: Enter
  on TEST.ZIP lists its members; Backspace returns clean.
- **NEXT (recommended move): F5 EXTRACT.** When the active panel is P_VFS, F5
  runs `<helper> X <container> <member-index> <destdir>` instead of copy_one;
  add an `X` mode to CCZIP that extracts the Nth FILE member (index matches `L`,
  dirs skipped). STORED = copy bytes at the local-header data offset; DEFLATED
  needs a small INFLATE in CCZIP (the bulk — free resident).
- **THEN:** more packers, one helper + one cc.ini line each — CCRAR, CCARJ,
  CCD64/CCT64 (C64 images, no decompression); plus a `[view]` section for
  per-extension viewers (image/audio) dispatched from F3.

## Open tasks / next moves (lower priority)

- **External (free):** `CCDIFF` · `CCREN` multi-rename · `CCSPLIT`/`CCJOIN`.
- **Needs resident reclaim:** full `MSG(id)` i18n · F2 user menu · remappable
  keys · history · bookmarks · themes · touch · copy/move progress %.
- **LFN live render:** validated only as 8.3 fallback (DOSBox-staging has no LFN
  API). Test under DOSBox-X / DOSLFN / Win9x DOS for a real long name.

---

## Gotchas (you'll burn cycles without these)

- **Drive the harness from PowerShell, never the Bash tool.** Git Bash/MSYS
  rewrites the `/T` argument into a Windows path `T:/`, so cc never enters test
  mode → no dump. PowerShell passes `/T` literally.
- **`dump_screen` records characters only, no attributes.** Cursor/tag/highlight
  colours are invisible in `CCDUMP.TXT`. Make state observable via *text*
  (that's why tagging shows a "N tagged" footer and the attr editor prints
  `R . . A`), or check side effects (saved file, host attribute).
- **DOSBox-staging has no LFN API** (714Eh/7160h return CF=1). Don't try to
  validate LFN rendering there. DOSBox-X supports it but is unreliable headless
  in this setup (detached launcher / no host flush).
- **Resident headroom is now ~2.6 KB** (the `/S` VRAM-snapshot debug feature is
  gated behind `FEAT_SNAP`, off by default, freeing its 4 KB snapbuf). Still
  re-run `build.ps1` after every resident change; a green build is the gate.
- **Don't shell out with `run_command` from inside a handler** — it clears the
  screen, waits on `get_key` (eats a harness keystroke), and re-reads both
  panels (which recurses through a P_VFS panel). Use `run_helper` for silent,
  redirect-to-file helper calls.
- **`cc.ini` is read up to `INIMAX` (1024) bytes**, whole-file; keep it under
  that or raise INIMAX, or trailing sections (like `[open]`) get truncated.
- **`.bss` counts toward resident** even though it's not in the `.com` on disk.
- **`cc.lng` overrides the F-key bar if present** — keep it out of the working
  dir for English-bar tests (it's gitignored; `da.lng` is the tracked sample).
- Menu labels draw past `MENU_IW` without clipping; keep new labels ≤ ~23 chars.

---

## Toolchain

| Tool | Path |
|---|---|
| NASM | `C:\Users\Caldor\AppData\Local\bin\NASM\nasm.exe` |
| DOSBox-staging | `dbstaging\dosbox-staging-v0.82.2\dosbox.exe` |
| DOSBox-X | `dosbox-x\dosbox-x_XPx64_SDL2.exe` (LFN-capable, flaky headless) |

---

## State

- Branch `main`, latest commit `324785f` (README bundled-tools reference).
  Recent: `0d74e43`/`a226440`/`c92e20c` Gold Box helpers + file-type routing.
  All local, **none pushed**.
- **Uncommitted working tree:** the nine UX fixes in the §"Latest session" table
  above (`cc.asm`, `mod/{clock,ini,mouse,menubar,views}.inc`, the VIDEO→`vseg`
  sweep across the `.inc`s, `cc.ini`) plus the docs refreshed this turn
  (`README.md`, `ROADMAP.md`, `cc.hlp`, this `HANDOFF.md`). Plus pre-existing
  scratch dirs (`_*test/`, `_dump_*.txt`, `ai-out/…`) that are not part of the
  feature work — don't stage those.
- `build.ps1` / `package.ps1` → both `CC.COM` (FEAT_STD) and `CCPOP.COM`
  (FEAT_MENU, no menubar) build green (exit 0). All external helpers assemble
  clean. Try the dist interactively with `.\run_cc.ps1`.
- **Before committing:** have the user verify the mouse-driven menu open/select
  and the flicker fix in a real DOSBox session (neither is headless-testable).
