# Claude Commander (`cc`) — session handoff

Cold-start brief for a fresh session. Read this first, then `ROADMAP.md` §0
(the delivered-feature table) and `README.md`. `HANDOFF.md` is only a pointer
here — keep a single brief. Last updated 2026-09-23.

`cc` is a Norton/Volkov-style two-panel DOS file manager in hand-written 16-bit
x86 NASM assembly, built as a flat `.COM`. The repo root **is** a git repo
(branch `main`); commit locally, **push only when the user explicitly asks**.
There is also a native Windows console port in C under `wincc/`.

---

## Where work happens

| Path | What |
|---|---|
| `cc.asm` | host core + tier block + keytab + `.bss`; `%include`s every module |
| `mod/*.inc` | resident feature modules, each behind `%ifdef FEAT_*` |
| `c*.asm` (cce, cfind, cgrep, chex, chexed, csum, czip, crar, carj, cd64, ct64, cpak, cimg, cwav, cdiff, cren, csplit, cjoin, ctouch, ted) | external Layer-3 helpers (separate `.COM`s, zero resident cost) |
| `cmdl.asm` / `experiments/` | CCMDL model viewer helper / MDL rigging **experiments** (`cmdl_exp*`, notes in `experiments/ccmdl-rig-results.md`, `plan/mdl_viewer.md`) |
| `ccpop.asm` | wrapper that `%define`s the CCPOP flags and `%include`s `cc.asm` (keeps DOS command lines < 127 chars for `INSTALL.BAT`) |
| `cc.ini cc.hlp da.lng` | runtime data (config, help, Danish language sample; `cc.lng` is the user's active copy, gitignored) |
| `build.ps1` | builds the min/std/full tiers and enforces the size budget |
| `run_all.ps1` | **the regression gate**: budget check + every headless `run_*.ps1` test |
| `run_*.ps1` | per-feature headless tests (`run_cc.ps1` is the *interactive* launcher) |
| `package.ps1` / `build_dist.ps1` | `dist\` folder / release zips (CC.COM + CCPOP.COM + helpers) |
| `configure.ps1`, `CONFIGURE.md` | custom à-la-carte builds (`FEAT_CUSTOM` + chosen flags) |
| `INSTALL.BAT`, `CCSETUP.BAT`, `BUILDING.TXT` | DOS-side installer / build-from-source |
| `ROADMAP.md` | architecture + feature catalogue; §0 = delivered list |
| `plan/*.md` | design notes (M1 split/dispatch/strings, widget plugins, MDL viewer) |

---

## Build & the size wall (the #1 constraint)

```
nasm -f bin cc.asm -o cc.com          # bare build == FEAT_STD (default tier)
.\build.ps1 -All                      # builds min/std/full + budget check
```

- Flat `.COM` = **one 64 KB segment** shared by code + data + `.bss` + stack.
- Resident = `0x100` + emitted code + all `.bss` (`resb` counts even though it
  is not in the file). `build.ps1` recovers it from the NASM listing.
- Budgets: std code ≤ 19,456 B and program-segment resident < 64,512 B; min code ≤ 9,216 B;
  full resident < 65,024 B; lfn (std + `FEAT_LFN_FULL`) resident < 64,512 B.
- **Current STD: code 18,949 B, resident 50,448 B → ~14 KB headroom;
  `FEAT_LFN_FULL` 51,267 B (~13 KB); CCPOP 48,020 B; MIN 39,142 B.**
- **Far data segment (`xseg`, 2026-09-23):** `viewbuf`, `lineoff` and
  `res_heap` live in a DOS block allocated at startup (`INT 21h/48h`) and are
  addressed through **FS** (`x_viewbuf`, `x_lineoff`, `x_res_heap`, declared
  in the `[absolute 0]` block just before `section .bss` — keep it there or
  `build.ps1`'s .bss scan miscounts). "Resident" in `build.ps1` now means the
  program segment only. See `plan/memory_map.md` for the next steps (panels →
  far segment, code overlays).
- `build.ps1` assembles to a temp file and only replaces the `.com` when NASM
  succeeds *and* the budget passes; `-Profile std,lfn` takes a list.
- Big new *buffers* belong in `xseg` (or a new far block), not `.bss`.
  Size knobs: `VIEW_MAX` 8192, `RESHEAP_MAX` 3072, `MAX_FILES` 512. Heavy,
  rarely used tools are still best as external helpers (free). Re-run
  `build.ps1` after every resident change.
- Tiers: `FEAT_MIN` / `FEAT_STD` (default) / `FEAT_FULL` (currently == STD).
  `FEAT_CUSTOM` + individual `-dFEAT_x` flags gives à-la-carte builds; the
  dependency block below the tier block pulls in prerequisites.
- `package.ps1` assembles `cc.asm` **twice**: `CC.COM` and `CCPOP.COM`
  (no `FEAT_MENUBAR`). Guard menubar-only symbols or the dist breaks.

---

## Test harness

```
# ALWAYS from PowerShell, NOT the Bash tool (see gotchas):
.\run_all.ps1                     # full gate; nonzero exit on any failure
.\run_all.ps1 -Only zip -ShowLog  # subset, echo failing logs
.\run_test.ps1 -ccArgs "/T" -keyfile keys_xxx.bin [-flags "FEAT_LFN_FULL"]
```

- `cc.com /T` replays keystroke file `cc.key` (byte pairs `[ascii, scan]`),
  dumping the 80×25 screen to `CCDUMP.TXT` after every frame. Exhausted keys
  return F10 (`00 44`) so sub-loops exit cleanly. `/D` dumps one frame and
  exits. `/S` (only with `FEAT_SNAP`) snaps VRAM to `CCSNAP.BIN`.
- `cc.key`, `cc.ini`, `cc.lng`, `cc.hlp` are opened relative to the **CWD**.
- Each `run_*.ps1` builds its own `.COM`, stages a scratch dir, writes its own
  key file, runs DOSBox-staging minimized with **`--exit`**, asserts on the
  dump/output, and exits 0/1. A DOSBox that has to be killed at the timeout
  counts as a FAIL (hang). The older scripts share repo-root files
  (`CCDUMP.TXT`, `cc.com`, conf files) — run only one of those at a time.
- The `run_*safety.ps1` suites (`run_safety` = resident core,
  `run_czip_safety`, `run_fileops_safety`, `run_parsers_safety`) stage
  everything under `$env:TEMP` and can run alongside other work. Put new tests
  in that style. `wincc\run_test.ps1` is the Windows-port suite (no DOSBox).
- Full `run_all.ps1` takes ~2.5 min.
- `FEAT_LFN_FULL` self-test vectors for `ft2dos` live in `mod/harness.inc`.

---

## Adding a resident feature (the module pattern)

1. `mod/<name>.inc` — handler(s), self-contained, with its own `.bss` if any.
2. `%define FEAT_<NAME>` in the tier block in `cc.asm` (+ any dependency).
3. `%include "mod/<name>.inc"` in the includes section (inside `%ifdef`).
4. A `KEYBIND_EXT`/`KEYBIND_ASC` row in `keytab` (inside `%ifdef`).
5. Optional: a menu row (`mod/menu.inc` / `mod/menubar.inc`), a `cc.hlp` line.
6. Build; confirm still under the wall; add a `run_<name>.ps1` test and list
   it in `run_all.ps1`.

Adding an **external helper**: write `cXXX.asm` (`org 100h`, `nasm -f bin`),
print to stdout. `on_enter` already shells out anything typed at the prompt;
map extensions in `cc.ini` (`[open]` browse / `[view]` F3) and add it to
`package.ps1`.

---

## Current state (2026-09-23)

- All originally requested features are shipped (ROADMAP §0). Latest releases:
  v1.0.5 (nine UX fixes), v1.0.6 (search-results panel), then drives view
  (Alt-F1/F2), human-readable size column, LFN view mode, DOS installer.
- **`FEAT_LFN_FULL`** (opt-in build, `cc-lfn` zip): LFN file ops
  (716Ch/7141h/7156h/7139h), 714Eh/714Fh enumeration, and a working
  `ft2dos` FILETIME→DOS converter (commit 39ccfe0) so LFN entries show real
  dates. Validated via the harness self-test vectors under DOSBox; a real
  long-name listing still needs an LFN-capable DOS (DOSBox-X / DOSLFN / Win9x).
- **2026-09 safety pass** (see ROADMAP §0): ~50 data-loss, overflow and hang
  fixes across the resident core, all helpers, wincc and the build/packaging
  scripts, each covered by the `run_*safety.ps1` suites.
- **Interactive sanity-check still owed** (not headless-testable): mouse menu
  open/select (incl. the new brief-view click column fix and pointer re-show
  after EXEC), the flicker-free render, floppy free-space, INT 24h on a real
  empty drive, disk-full copy handling, and the `FEAT_LFN_FULL` build on an
  LFN-capable DOS (its `run_safety` cases can't run on DOSBox-staging).

## Open tasks / next moves

- **External (free):** more `[open]` packers; `[view]` per-extension viewers.
- **Now affordable (~14 KB headroom since xseg):** full `MSG(id)` i18n · F2 user menu · remappable
  keys · history · bookmarks · themes · copy/move progress %.
- Viewer next/prev-match stepping (`n`/`N`) keyed off the stored grep word.

**Known issues found in the 2026-09 audit but not fixed yet** (low impact or
needs design):
- Resident: config/help/lng (`cc.ini`, `cc.hlp`, `cc.lng`) are opened from the
  CWD, not cc's program dir (`discover.inc` has `progdir_buf` logic to reuse);
  no user-visible error when a copy fails (source is kept, but silently);
  `FINDOUT.TXT`/`GREPOUT.TXT` scratch never deleted; `CCVFS.LST` is written
  next to the archive, so archives on read-only media open empty; archive
  folder names > 13 chars open empty; find/grep text isn't shell-escaped
  (`< > |`); clock repaints over full-screen modals; menu bar lacks "Tag by
  mask" (pop-up menu has it).
- Helpers: no CRC check on extract (zip/rar/arj); DOS device names (`CON`,
  `NUL`) as member names; CCZIP AP trusts the EOCD offset (SFX stubs) and caps
  the file list at 4 KB; CCREN caps at 128 matches and exits 0 on no match;
  CCHEXED edits only the first 48 KB of larger files without saying so; CCWAV
  ignores the audio format field (compressed WAVs play as noise); ARJ headers
  > 512 B stop the walk; T64 names stop at the first space.
- LFN detection (AH=71h) now does `stc` first everywhere (resident code and
  the `cfind`/`cgrep` probes, which also treat `AX=7100h` as unsupported),
  because pre-DOS-7 leaves CF unchanged. DOSBox always sets CF, so confirm on
  a real MS-DOS 6.22 box.

---

## Gotchas (you'll burn cycles without these)

- **Drive the harness from PowerShell, never the Bash tool.** Git Bash/MSYS
  rewrites `/T` into the path `T:/`, so cc never enters test mode → no dump.
- **DOSBox-staging 0.82 ignores a bare `exit` in `[autoexec]`** ("Exit blocked
  because program quit after only 0.9 seconds") — always pass `--exit` on the
  command line, or every test silently waits out its timeout.
- **Working directory for launches:** typed commands, Enter on an
  `.EXE/.COM/.BAT` and Tools items run in the *active panel's* folder; cc
  switches back to its own folder afterwards. Helpers cc launches internally
  (viewers, archive helpers, F4 editor) run from cc's folder, because they are
  started by bare name.
- **Virtual panels are read-only for destructive keys.** F8/F6/Shift-F6/
  Ctrl-A/F4/hex refuse on archive, results and drives panels (they used to hit
  same-named real files). New file-op keys must use the same guard.
- **Extractors never overwrite.** All archive helpers create outputs with
  INT 21h/5Bh and fall back to `NAME~1..~9`; member names are sanitised
  (no `..`, drive, or absolute paths). Keep it that way in new helpers.
- **F6 move deletes the source only if the copy fully succeeded** (`cp_fail`
  is set on every copy failure path). Any new failure path in
  `copy_file`/`copy_tree` must set it.
- `.bss` is zeroed at startup — don't rely on anything in `.bss` surviving
  from before `start` runs.
- **FS belongs to `xseg`.** Every access to `x_viewbuf`/`x_lineoff`/
  `x_res_heap` (and to pointers into them, e.g. results rows' `E_RES_OFF`,
  `rl_path`) needs an `fs:` override; DOS calls that read into them swap
  `DS` to FS around the `int 21h`; `stos`/`movs` write via `ES:DI` (not
  overridable). FS is reloaded after EXEC (`run_exec`) and in `get_key`.
  Shared string helpers (`path_append`, `streqi`, …) are DS-only — copy far
  data into a DS buffer first. `x_res_heap` must not sit at offset 0
  (`rl_lastpath = 0` means "none").
- **`dump_screen` records characters only, no attributes.** Cursor/tag colours
  are invisible in `CCDUMP.TXT`; make state observable via text or side effects.
- **DOSBox-staging has no LFN API** (714Eh/7160h return CF=1). DOSBox-X has
  it but is unreliable headless here (see the GameLink memory note).
- **Don't shell out with `run_command` from inside a handler** — it clears the
  screen, waits on `get_key` (eats a harness keystroke) and re-reads both
  panels (recursing through a P_VFS panel). Use `run_helper` for silent,
  redirect-to-file helper calls.
- **`cc.ini` is read into the viewbuf** (commit 95a7ad9), so it may grow up to
  `VIEW_MAX`; `cc.lng` overrides the F-key bar if present in the CWD.
- **32-bit instructions are legal** (486 target) but `div` uses `DX:AX` /
  `EDX:EAX` — zero the high half first or you get #DE.
- Menu labels draw past `MENU_IW` without clipping; keep labels ≤ ~23 chars.
- Many scratch files/dirs in the root (`_*`, `*.com`, `*.lst`, `*.conf`) are
  gitignored build/test output — never stage them.

---

## Toolchain

| Tool | Path |
|---|---|
| NASM | `C:\Users\Caldor\AppData\Local\bin\NASM\nasm.exe` |
| DOSBox-staging | `dbstaging\dosbox-staging-v0.82.2\dosbox.exe` |
| DOSBox-X | `dosbox-x\dosbox-x_XPx64_SDL2.exe` (LFN-capable, flaky headless) |
