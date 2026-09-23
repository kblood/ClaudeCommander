# Claude Commander (`cc`)

A Norton/Volkov-Commander-style two-panel file manager for DOS, written in
hand-tuned 16-bit x86 assembly. Runs in real mode on a **386 or later**
(the source is assembled with `cpu 386` and uses `movzx` and friends; the
opt-in `FEAT_LFN_FULL` build also uses 32-bit `mul`/`div` — all 386-legal, and
ideal on the 486-class ao486 core), 80×25 colour text mode,
MS-DOS / FreeDOS / DOSBox.

```
nasm -f bin cc.asm -o cc.com
```

**The core is one `.COM` file of ~18 KB of code** — a full two-panel
manager with mouse, recursive copy/delete, and overwrite prompts — now grown
into a **modular** manager: compile-time feature modules (`mod/*.inc` behind
`%ifdef FEAT_*`), runtime data files (`cc.ini`, `cc.lng`, `cc.hlp`), and a
family of external Layer-3 helpers (`CCEDIT`, `CCFIND`, `CCZIP`, `CCGREP`,
`CCHEX`, `CCSUM`, … — see **Bundled tools** below). Build tiers:
`FEAT_MIN` / `FEAT_STD` (default) / `FEAT_FULL`. See `ROADMAP.md` §0 for the
full delivered list.

---

## The size story — "less than 200 KB on a floppy"

The original goal was "small enough to live on a boot floppy, like Volkov
Commander (~64 KB)." Claude Commander lands far under that:

| Build | Size |
|---|---|
| `cc.com` (FEAT_STD: all modules below) | **18,949 B code, 50,448 B resident** |
| `cc-lfn.com` (FEAT_STD + FEAT_LFN_FULL) | 19,711 B code, 51,267 B resident |
| `CCPOP.COM` (FEAT_STD without the menu bar) | 16,562 B code, 48,020 B resident |
| `ccmin.com` (FEAT_MIN) | 8,757 B code, 39,142 B resident |
| *historical:* earlier core-only build (mouse, recursive ops, overwrite prompts) | 7,104 bytes |
| *historical:* Stage B (viewer + snapshot, pre-mouse) | 4,883 bytes |
| *historical:* Stage A (panels + nav only) | 3,044 bytes |

`build.ps1` enforces a **63 KB (64,512 B) resident budget**, which keeps about
1 KB of slack under the 64 KB segment wall. The FEAT_STD build uses 50,448 B
of it (~14 KB headroom); the LFN build 51,267 B (~13 KB). The emitted `.com`
is only ~19 KB; the rest of the resident image is `.bss` working memory
(panel arrays, heaps, stack) claimed at load time. The big scratch buffers
(viewer, pager line table, results-path heap, ~13 KB) live outside the
segment in a far block (`xseg`, see `plan/memory_map.md`). The heavy tools
cost nothing resident — they are separate `.COM`s launched on demand.

The `.com` itself is ~1.3 % of a 1.44 MB floppy, and well under the 200 KB
budget. How:

1. **Flat `.COM`, not `.EXE`.** No MZ header, no relocations, no segment
   tables. `org 100h`, one segment, code+data+stack share 64 KB.
2. **Reserved buffers live in `section .bss` (`nobits`).** The directory
   arrays (two panels × 512 entries × 24 bytes ≈ 12 KB each), the 8 KB
   viewer buffer, the search-results path heap, the line table, key/dump
   scratch — none of it is emitted
   into the file. The `.COM` only carries *code + initialized strings*; the
   working RAM is claimed at runtime and zeroed at start-up. This is the
   single biggest size lever: without it the file would be tens of KB of
   zero-padding. (Because a flat `.COM` is one 64 KB segment, the *total*
   `.bss` is also capped at 64 KB — which is why the per-panel entry count is
   512 rather than larger, and why the biggest buffers moved to a far block.)
3. **No libc, no runtime.** Every service is a raw `INT 21h` / `INT 10h` /
   `INT 16h` call. There is nothing to link.
4. **Direct video writes to `B800:0000`.** No BIOS TTY, no ANSI driver. The
   renderer pokes character/attribute word-pairs straight into text VRAM.
5. **Shared code paths.** One frame-drawing routine for both panels, one
   modal-dialog box reused by every file operation, one path-builder helper
   family (`bp_copy_dir`/`bp_copy_name`) behind mkdir/copy/move/delete, one
   recursive tree-walker each for copy and delete, and one `busy_name` helper
   that both the progress box and the overwrite dialog draw through.

Runtime memory: after start-up the program shrinks its DOS allocation
(`INT 21h AH=4Ah`) to just the resident image + stack, freeing the rest of
the 640 KB so shelled-out programs (`COMMAND.COM /C ...`) have room. It then
allocates two small DOS blocks: the 4,000-byte screen back buffer and the
~13 KB far data block. In total cc needs about 66 KB of free conventional
memory; if either allocation fails it prints `Not enough memory.` and exits
with code 8.

---

## Features

### Implemented and verified

**Two-panel browser**
- Side-by-side panels, shared single-line frame, path title per panel.
- Per-panel cursor + scroll; the active panel's title/frame is highlighted.
- Directory read via FindFirst/FindNext into a fixed entry array, then an
  in-place sort: `..` first, directories before files, case-insensitive by
  name. Sizes shown right-justified; `<DIR>` / `<UP>` labels.
- Colour coding: files grey, directories white, **tagged** entries yellow,
  cursor cyan (active) / grey (inactive).
- **Flicker-free**: each frame is composed off-screen in a back buffer and
  blitted to `B800:0000` in one `rep movsw`, so moving the cursor never shows a
  partial repaint (it degrades gracefully to live drawing if the buffer can't be
  allocated).

**Navigation**
- `↑ ↓`, `PgUp PgDn`, `Home End` move the cursor (scroll follows).
- `← →` page through the list in the full view (so `PgDn` and `→` now move by
  exactly the same step); in the 3-column brief view they step a whole column.
- `Tab` switches the active panel.
- `Enter` on a directory descends; on `..` goes up; on an `.EXE/.COM/.BAT`
  runs it from the panel's directory.
- `Backspace` on an empty command line jumps to the parent folder. Going up
  (either way) leaves the cursor **on the folder you just came from**, not at
  the top of the list.

**Mouse** (INT 33h — auto-detected; the program runs fine without a driver)
- Click an entry to select it and activate its panel.
- Double-click an entry to open it (same as `Enter`).
- Right-click an entry to tag/untag it.
- Click a title on the menu bar (Files / Commands / Options / Tools) to drop
  that menu straight from the file view — no need to press `F9` first. Inside an
  open menu the mouse picks items, hops between menus along the bar, and an
  outside click closes it.
- Click a label on the function-key bar to invoke that key (every bound key's
  label is clickable; `F2` is unbound, so its slot is blank).
- The modal dialogs are fully clickable too (see below).
- The cursor show/hide is reference-counted against our own flag, so it can no
  longer get "lost" (invisible-but-present) after a file op or an alt-tab.

**Command line**
- Type a command after the `path>` prompt; `Enter` shells out through
  `COMSPEC /C`, with SS:SP and DTA saved/restored across the EXEC.
- `Esc` clears the line (and, in a search-results or drives panel, leaves it
  and re-lists the real folder); `Backspace` edits it (or goes to the parent
  folder when the line is empty).
- Typed commands (and Tools-menu actions) run in the **active panel's folder**.

**File operations** (each pops a modal dialog and refreshes both panels)
- `F3`  **View** — scrollable text pager (↑↓, PgUp/PgDn, Home/End, Esc/F3).
- `F5`  **Copy** — copy to the other panel's directory. Acts on the whole
  **tagged set** if any entries are tagged, otherwise the cursor entry.
- `F6`  **Move** — move to the other panel's directory; the dialog shows an
  editable destination name so you can rename in flight. A same-drive move is
  one atomic DOS rename; a cross-drive move copies, then deletes the source
  only after a complete, successful copy.
- `Shift+F6` **Rename** — rename in place (same folder).
- `F7`  **MkDir** — create a directory (input dialog).
- `F8`  **Delete** — delete files or whole directory trees. Acts on the
  tagged set if any, otherwise the cursor entry (Y/N confirm).
- `Insert` — tag/untag the current entry (cursor advances).
- `Alt+F1` / `Alt+F2` — show all available drives in the left / right panel as a
  browsable list (`A:` `B:` `C:` …); `Enter` on one opens that drive's root,
  `Esc` / `..` returns to where you were. (In the CCPOP build, which lacks the
  results-panel machinery, these keys fall back to a type-the-letter prompt.)
- `Alt+F5` — pack the tagged set (or cursor entry) into an archive in the other
  panel (tagged folders recurse); `Alt+F9` — extract a whole archive to the
  other panel.
- `Alt+F10` — modal directory tree of the active panel's path; `Enter` jumps
  the panel there.
- `F10` — quit.

**Recursive directory copy / delete**
- `F5`/`F8` on a directory copy or delete the whole tree, including
  subfolders, via a per-recursion-level DTA stack so nested
  FindFirst/FindNext state isn't clobbered.
- Copying a folder into its own subtree copies the existing contents once and
  skips the destination directory during the walk — no runaway recursion.

**Overwrite handling**
- When a copy would clobber an existing file, a four-button dialog appears:
  **`[Overwrite]` `[Skip]` `[All]` `[Cancel]`**. `All` overwrites every
  remaining collision silently; `Cancel` cleanly unwinds the recursion and the
  tagged-set batch. Directories merge; only file collisions prompt.

**Navigable, clickable dialogs**
- The Yes/No confirm and the overwrite dialog support keyboard shortcuts,
  `←`/`→`/`Tab` to move focus, `Enter`/`Space` to activate the focused button,
  `Esc` to cancel, and mouse clicks on any button.
- Long copy/delete runs show a *"please wait"* box naming the current file, so
  the screen never looks frozen.

**Modular features (FEAT_STD default build)**
- **Clock** — live `HH:MM:SS`, placement set in `cc.ini` (`clock = cmdrow` on
  the command row, default; `topright` over the menu bar; `off` to hide it).
- **Panel views** — `Ctrl-F10` (or `Alt-F3`, which DOSBox doesn't swallow;
  also under the Options menu) **cycles** the panel body through three views:
  full single-column list → names-only brief 3-column layout → long-name (LFN)
  view (long names with an LFN provider, else 8.3). Each panel cycles
  independently.
- **Sort** — by name / extension / size / date (`Ctrl-F1..F4`); initial order
  from `cc.ini`.
- **Columns** — cycle the right column size / date / time / attributes
  (`Ctrl-F5`); initial column from `cc.ini`.
- **Footer** — per-panel file count, free space, and tagged count in the border.
- **Quick-search** — Norton-style incremental jump-to (`Ctrl-F6`).
- **Menu bar / F9 menu** — the `FEAT_STD` build shows a pull-down menu bar
  (Files / Commands / Options / Tools); `F9` drops the current menu, the arrows
  navigate, and the mouse opens/picks items directly. The `CCPOP.COM` build
  ships the classic single pop-up menu instead.
- **Tag by mask** — select / deselect by `*.wildcard` (`Ctrl-F7/F8`).
- **Attribute editor** — toggle Read-only/Hidden/System/Archive (`Ctrl-A`).
- **F1 help** — pages `cc.hlp` through the viewer.
- **Language** — `cc.lng` translates the F-key bar (`da.lng` Danish sample).
- **Long file names** — the cursor file's long name shows on the command row
  when an LFN provider is active (8.3 otherwise); see also the long-name panel
  view above. The opt-in `cc-lfn.com` build (`FEAT_LFN_FULL`) adds LFN file
  operations and long-name enumeration with real dates.
- **Search results panel** — `Alt-F7` (find by name, CCFIND) and `Alt-F8`
  (grep contents, CCGREP) run the helper silently and load the results into the
  other panel as a browsable list — the same virtual-panel mechanism as the zip
  browser, no screen takeover. Find lists every matching file; grep lists each
  file that contains a match (one row per file, with its first-match line shown
  in the size column). `Enter` on a find row jumps the panel to that file's
  folder (cursor on it); `Enter` on a grep row opens the F3 viewer at the first
  matching line. The list opens with a `..` row at the top — `Esc` (or `Enter`
  on `..`) leaves it and re-lists the real folder, just like backing out of a
  zip.
- **Launchers** — `F4` edit (CCEDIT), `Ctrl-F9` list archive (CCZIP).

**External tools** (type the name at the prompt, or via the keys above)
- `CCEDIT <file>` — full-screen text editor.
- `CCFIND <pat> [dir]` — recursive find by name.
- `CCGREP <word> [dir] [mask]` — recursive content search (`path:line`).
- `CCZIP <zip>` — list a ZIP's central directory.
- `CCHEX <file>` — hex + ASCII dump (binary viewer).
- `CCSUM <file>` — CRC-32 + byte size.

**Safety & robustness** (2026-09 hardening pass; details in `ROADMAP.md` §0)
- `F6` move never deletes the source after a failed or partial copy, refuses
  to move a folder into its own subfolder, and detects copy-onto-self (via
  `TRUENAME`). File ops that make no sense on an archive, search-results or
  drives panel (`F8`, `F6`, `Shift-F6`, `Ctrl-A`, `F4`, hex edit) refuse there.
- A critical-error (`INT 24h`) handler, bounded command line / F-key labels /
  command tail / panel paths, and a zeroed `.bss` at start-up.
- Helpers: archive extraction can't escape the destination folder and
  extract-all never overwrites; malformed ZIP/GIF/BMP/PCX/WAV/RAR/D64 input
  can't hang or overrun; CCEDIT saves via a temp file + rename; CCEDIT/CCHEXED
  prompt to save on quit; helpers return meaningful exit codes.

### Still deferred

- Full `MSG(id)` string-table i18n (only the F-key bar is translated today).
- F2 user menu (`cc.mnu`), remappable keys, command-line history, bookmarks,
  colour themes. (File associations shipped: the `cc.ini` `[open]` / `[view]`
  maps below.)
- Copy/move progress %.
- Viewer: files larger than the 8 KB buffer cap (seek windowing), in-pager search.

---

## Bundled tools & file associations

cc stays small by pushing heavy features into standalone helper `.COM`s (each a
separate `nasm -f bin` binary). They're invoked from the menus/hotkeys, by typing
the name at cc's command line, or automatically through a file association.

**File & text tools**

| Tool | What it does | How to run |
|---|---|---|
| `CCEDIT` | text editor | `F4`, or `CCEDIT <file>` |
| `CCHEXED` | hex editor (F2 save, Esc quit) | `F3`→`H`→`E`, or `CCHEXED <file>` |
| `CCFIND` | find files by name | `Alt-F7`, or `CCFIND <pattern> [dir]` |
| `CCGREP` | search file contents | `Alt-F8`, or `CCGREP <word> [dir] [mask]` |
| `CCSUM` | CRC-32 + byte size | `CCSUM <file>` |
| `CCDIFF` | byte-compare two files | `CCDIFF <a> <b>` |
| `CCSPLIT` / `CCJOIN` | split a file / rejoin the parts | `CCSPLIT <file> <size>[K]` · `CCJOIN <out> <base>` |
| `CCREN` | wildcard batch rename | `CCREN <srcmask> <dstmask>` |
| `CCTOUCH` | set a file's date/time | `CCTOUCH <file> [YYYY-MM-DD [HH:MM[:SS]]]` |

**Viewers** (`F3` on a mapped extension, else the built-in text/hex pager)

| Tool | Views | Extensions |
|---|---|---|
| `CCHEX` | hex + ASCII dump | (any, via the built-in F3 hex mode) |
| `CCIMG` | images, VGA mode 13h | `.bmp` `.pcx` `.gif` |
| `CCWAV` | PCM audio, Sound Blaster | `.wav` |
| `CCMDL` | Quake .mdl 3D model viewer (arrows rotate, Space spin, A animate, N/P frames) | `.mdl` (F3), or in-place from a browsed `.pak` |

**Archives & containers** — press `Enter` to browse one *as a folder*, `F5` to
extract a member:

| Tool | Container | Extension |
|---|---|---|
| `CCZIP` | ZIP archive | `.zip` |
| `CCD64` / `CCT64` | C64 disk / tape image | `.d64` `.t64` |
| `CCARJ` | ARJ archive | `.arj` |
| `CCRAR` | RAR 4.x archive | `.rar` |
| `CCPAK` | Quake PAK archive (F3 on a `.mdl` member opens it in `CCMDL` in place, no extraction) | `.pak` |

**Gold Box game data** (SSI AD&D: Pool of Radiance, the Krynn trilogy, …) — the
helpers browse/view the data files of these games in place:

| Tool | Handles | Extension |
|---|---|---|
| `CCGLB` | `.glb` master library — a dispatcher that sniffs each chunk and hands it to CCSND / CCHLIB / CCGEO | `.glb` (Enter) |
| `CCGEO` | area maps | `.geo` (F3) / GEO members of a `.glb` |
| `CCHLIB` | image master libraries | `.tlb` (Enter) · `.hti` (F3) |
| `CCDAA` | data records | `.daa` (Enter) · `.dai` (F3) |
| `CCSND` | DIG4 digitized sound | dispatched from `CCGLB` |
| `CCGB` | game images | `.gbi` (F3) |
| `CCGBC` | DAX container | `.dax` (Enter) |

**Adding your own** — associations live in `cc.ini`, read at startup, so a new
file type needs **no recompile of `cc.com`**: drop the helper `.COM` on the drive
and add one line.

- `[open]` — `ext = HELPER` → `Enter` browses that type as a folder (the helper
  lists members; cc shows them in a panel).
- `[view]` — `ext = HELPER` → `F3` runs your viewer instead of the text pager.
- `[tools]` — `Label = PROG [key]` → adds a Tools-menu entry / hotkey that runs
  `PROG <cursor-file>`. This is an opt-in build feature (`FEAT_TOOLS_INI`);
  the packaged `CCUSER.COM` build includes it and ships `TOOLSAMP\*.BAT`
  examples that receive the selected file as `%1`.

Each is `HELPER <file>`; unknown or missing helpers are ignored, so the routing
is safe even when a tool isn't installed.

---

## Keyboard reference

| Key | Action | Key | Action |
|---|---|---|---|
| ↑ ↓ / PgUp PgDn / Home End | move cursor | `Tab` | switch panel |
| ← → | page (full view) / column (brief view) | `Backspace` | parent folder (empty cmd line) |
| `Enter` | enter dir / run program | `Esc` | clear cmd line |
| `F3` | view file | `F5` | copy (tagged set or cursor) |
| `F6` | move to other panel (editable dest name) | `Shift-F6` | rename in place |
| `F7` | make directory | `F8` | delete (tagged set or cursor) |
| `Insert` | tag entry | `Esc` (results/drives panel) | leave the list |
| `Alt+F1` / `Alt+F2` | left / right drive list | `F10` | quit |
| `F1` | help (`cc.hlp`) | `F4` | edit file (CCEDIT) |
| `F9` | menu bar (pop-up in CCPOP) | `Ctrl-A` | edit attributes (R/H/S/A) |
| `Ctrl-F1..F4` | sort name/ext/size/date | `Ctrl-F5` | cycle column |
| `Ctrl-F6` | quick-search | `Ctrl-F7/F8` | tag/untag by mask |
| `Ctrl-F10` / `Alt-F3` | cycle view: full → brief → long-name | `Alt-F7` | find files → results panel |
| `Alt-F8` | grep contents → results panel | `Ctrl-F9` | list archive (CCZIP) |
| `Alt-F5` | pack into archive (other panel) | `Alt-F9` | extract whole archive |
| `Alt-F10` | directory tree | | |
| click | select entry | dbl-click | open entry |
| right-click | tag entry | click F-bar | invoke that F-key |
| click menu title | open that menu (no F9 needed) | | |

---

## Build & test

- **Assemble:** `nasm -f bin cc.asm -o cc.com` (NASM 2.x).
- **Build profiles + size budgets:** `.\build.ps1 -All` builds `min` / `std` /
  `full` / `lfn` and fails if any exceeds its budget (min code ≤ 9 KB; std code
  ≤ 19 KB and resident < 63 KB; full resident < 63.5 KB; lfn resident < 63 KB).
  A failed build never overwrites an existing binary.
- **Regression gate:** `.\run_all.ps1` (PowerShell 7, from the repo root) runs
  the budget check and then every headless `run_*.ps1` test, exiting nonzero on
  any failure. `-Only <pattern>` runs a subset, `-ShowLog` echoes failing logs.
- **Run:** `cc.com` on any DOS, or `MOUNT C <dir>` in DOSBox.

The repo includes a headless regression harness used during development:

- `cc.com /D` renders one frame, dumps the 80×25 screen (characters only) to
  `CCDUMP.TXT`, and exits.
- `cc.com /T` plays a scripted keystroke file `cc.key` (byte pairs of
  AL=ascii, AH=scan), dumping a frame after every step. This is how every
  feature above was verified without a human at the keyboard.
- `cc.com /S` copies the raw 80×25 video page to `CCSNAP.BIN`;
  `render_snap.ps1` turns it into a colour PNG with the real VGA text
  palette (handy for documentation screenshots).
- `run_test.ps1 -ccArgs /T -keyfile keys_xxx.bin` assembles, runs the program
  under DOSBox Staging with a timeout, and prints `CCDUMP.TXT`.

---

## Source map (`cc.asm`)

| Area | Routines |
|---|---|
| Start / arg parse / memory shrink / mouse init | `start` |
| Key dispatch | `dispatch`, `key_*`, `on_*` |
| Render | `render_all` (composes into the back buffer), `blit_buf` (one-shot blit to VRAM), `widgets_draw`, `draw_frames`, `draw_panel`, `pick_attr`, `draw_titles`, `draw_cmdline`, `draw_fkeys` |
| Directory model | `read_dir`, `accept_dta`, `build_search`, `sort_panel`, `order_cmp` |
| Paths | `path_append`, `path_up`, `go_parent`, `bp_copy_dir`, `bp_copy_name`, `build_entry_path`, `build_target_path`, `build_other_path` |
| Modal dialogs | `dlg_box`, `dlg_input`, `dlg_confirm`, `dlg_draw_buttons`, `dlg_overwrite`, `ow_draw_buttons`, `dlg_field`, `busy_box`, `busy_name` |
| File ops | `key_mkdir`, `key_delete`, `key_copy`, `key_move`, `key_rename`, `count_tagged`, `copy_one`, `delete_one`, `copy_file`, `refresh_panels` |
| Recursive trees | `copy_tree`, `del_tree`, `set_dta_cur`, `cur_dta_ptr`, `make_findpat` |
| Mouse (INT 33h) | `mouse_poll`, `mouse_hit`, `mouse_left`, `mouse_right`, `mouse_confirm`, `mouse_overwrite`, `mouse_show`, `mouse_hide`, `fbar_to_key` |
| Viewer | `key_view`, `view_move`, `view_build_lines`, `render_view` |
| Shell-out | `run_command`, `get_comspec`, `build_tail`, `fill_epb`, `run_exec` |
| Test harness | `open_dump`, `dump_screen`, `load_keys`, `get_key`, `selftest` |

### Modules (`mod/*.inc`, gated by `%ifdef FEAT_*`)

`shell` `fileops` `recurse` `mouse` `viewer` `harness` (core splits) ·
`clock` `sort` `cols` `free` `widgets` `search` `menu` `menubar` `tools`
`toolsini` `discover` `views` `tree` `mask` `edit` `find` `grep` `results`
`zip` `vfs` `ini` `help` `lang` `lfn` `lfnview` `attr` (features). Each owns
its handlers, optional menu entry, and `.bss`. The key bindings themselves all
live in the single `keytab` in `cc.asm` (each row inside its feature's
`%ifdef`), so adding a feature is one `%include`, one tier `%define`, and a
`keytab` row.

### External helpers (separate binaries)

Each helper is a standalone `nasm -f bin` `.COM`, invoked through cc's
`run_command` EXEC path, by typing its name at the prompt, or via a `cc.ini`
association — see **Bundled tools & file associations** above for what each one
does. Source → binary:

- in-tree: `cce`→CCEDIT · `cfind`→CCFIND · `czip`→CCZIP · `cgrep`→CCGREP ·
  `chex`→CCHEX · `chexed`→CCHEXED · `csum`→CCSUM · `cdiff`→CCDIFF ·
  `csplit`→CCSPLIT · `cjoin`→CCJOIN · `cren`→CCREN · `ctouch`→CCTOUCH ·
  `cd64`→CCD64 · `ct64`→CCT64 · `carj`→CCARJ · `crar`→CCRAR · `cpak`→CCPAK ·
  `cmdl`→CCMDL · `cimg`→CCIMG · `cwav`→CCWAV. (`experiments/` holds the
  CCMDL rigging experiments; they are not part of the distribution.)
- Gold Box helpers (`CCGLB/CCGEO/CCHLIB/CCDAA/CCSND/CCGB/CCGBC`) build from the
  GoldBox modding project's `native/src`; `package.ps1` assembles them into the
  distribution (falling back to prebuilt `.COM`s if the source tree is absent).
