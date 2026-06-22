# Claude Commander (`cc`) — session handoff

Cold-start brief for a fresh session. Read this first, then `ROADMAP.md` §0
(the delivered-feature table) and `README.md`. Last updated 2026-06-23.

`cc` is a Norton/Volkov-style two-panel DOS file manager in hand-written 16-bit
x86 NASM assembly, built as a flat `.COM`. The repo root **is** a git repo
(branch `master`); all feature work is committed locally but **not pushed** —
push only when the user explicitly asks.

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

Resident modules: clock · sort (Ctrl-F1..F4) · columns size/date/time/attrs
(Ctrl-F5) · free+tagged footer · quick-search (Ctrl-F6) · F9 menu · tag-by-mask
(Ctrl-F7/F8) · attribute editor R/H/S/A (Ctrl-A) · F1 help · language/F-key-bar
(cc.lng) · LFN cursor long-name · launchers F4/Alt-F7/Alt-F8/Ctrl-F9.

External helpers: CCEDIT · CCFIND · CCZIP · CCGREP · CCHEX · CCSUM.

Every feature the user originally asked for is shipped. All verified GREEN via
the harness or end-to-end (e.g. CCATTR sets the real host read-only bit; CCSUM
matches the canonical CRC-32 vector `CBF43926`).

---

## Open tasks / next moves (all optional)

The explicit ask list is 100% done; these are roadmap extras:

- **External (free, recommended next):** `CCDIFF` file compare · `CCREN`
  multi-rename · `CCSPLIT`/`CCJOIN`. Same pattern as CCGREP/CCHEX/CCSUM.
- **Needs resident reclaim:** full `MSG(id)` string-table i18n (today only the
  F-key bar is translated) · F2 user menu (`cc.mnu`) · remappable keys ·
  command-line history · bookmarks · themes · file associations · touch ·
  copy/move progress %.
- **LFN live render:** validated only as graceful 8.3 fallback (DOSBox-staging
  has no LFN API). To see a real long name, test under DOSBox-X with LFN on, an
  LFN provider (DOSLFN), or Win9x DOS — or on the MiSTer ao486 rig with DOSLFN.

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
- **The resident wall is full (~8 B).** Re-run `build.ps1` after every resident
  change; a green build is the gate.
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

- Branch `master`, latest commit `d36ef1b` (docs update). 10+ feature/tool
  commits this round, all local, **none pushed**.
- `build.ps1` → FEAT_STD PASS (64,504 B). All external helpers assemble clean.
