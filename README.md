# Claude Commander (`cc`)

A Norton/Volkov-Commander-style two-panel file manager for DOS, written in
hand-tuned 16-bit x86 assembly. Targets 8086-and-up real mode (assembled for
`386` so it can use `movzx`/`imul-imm` — ideal on the 486-class ao486 core),
80×25 colour text mode, MS-DOS / FreeDOS / DOSBox.

```
nasm -f bin cc.asm -o cc.com
```

**The whole program is one `.COM` file of under 8 KB** — a full two-panel
manager with mouse, recursive copy/delete, and overwrite prompts.

---

## The size story — "less than 200 KB on a floppy"

The original goal was "small enough to live on a boot floppy, like Volkov
Commander (~64 KB)." Claude Commander lands far under that:

| Build | Size |
|---|---|
| `cc.com` (current: mouse, recursive ops, overwrite prompts) | **7,104 bytes** |
| Stage B (viewer + snapshot, pre-mouse) | 4,883 bytes |
| Stage A (panels + nav only) | 3,044 bytes |

That is ~0.5 % of a 1.44 MB floppy, and ~3.6 % of the 200 KB budget. How:

1. **Flat `.COM`, not `.EXE`.** No MZ header, no relocations, no segment
   tables. `org 100h`, one segment, code+data+stack share 64 KB.
2. **Reserved buffers live in `section .bss` (`nobits`).** The directory
   arrays (two panels × 512 entries × 24 bytes ≈ 12 KB each), the 16 KB
   viewer buffer, the line table, key/dump scratch — none of it is emitted
   into the file. The `.COM` only carries *code + initialized strings*; the
   working RAM is claimed at runtime and zeroed by us as needed. This is the
   single biggest size lever: without it the file would be tens of KB of
   zero-padding. (Because a flat `.COM` is one 64 KB segment, the *total*
   `.bss` is also capped at 64 KB — the resident image lands at ~51 KB, which
   is why the per-panel entry count is 512 rather than larger.)
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
the 640 KB so shelled-out programs (`COMMAND.COM /C ...`) have room.

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

**Navigation**
- `↑ ↓`, `PgUp PgDn`, `Home End` move the cursor (scroll follows).
- `← →` act as PgUp/PgDn (the panels are single-column, so the left/right
  arrows would otherwise do nothing).
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
- Click a label on the function-key bar to invoke that key.
- The modal dialogs are fully clickable too (see below).

**Command line**
- Type a command after the `path>` prompt; `Enter` shells out through
  `COMSPEC /C`, with SS:SP and DTA saved/restored across the EXEC.
- `Esc` clears the line; `Backspace` edits it (or goes to the parent folder
  when the line is empty).

**File operations** (each pops a modal dialog and refreshes both panels)
- `F3`  **View** — scrollable text pager (↑↓, PgUp/PgDn, Home/End, Esc/F3).
- `F5`  **Copy** — copy to the other panel's directory. Acts on the whole
  **tagged set** if any entries are tagged, otherwise the cursor entry.
- `F6`  **Rename/Move** — rename or move via an input dialog (`INT 21h 56h`).
- `F7`  **MkDir** — create a directory (input dialog).
- `F8`  **Delete** — delete files or whole directory trees. Acts on the
  tagged set if any, otherwise the cursor entry (Y/N confirm).
- `Insert` — tag/untag the current entry (cursor advances).
- `Alt+F1` / `Alt+F2` — switch the left / right panel to another drive.
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

### Deliberately deferred (room in the budget for all of these)

- F2 user menu, F9 pull-down menu bar, F1 help screen.
- Copy/Move byte-progress percentage; preserving timestamps/attributes.
- File-mask filter (`+`/`-` select), sort-order menu, quick-search by typing.
- Viewer: hex mode, files larger than 16 KB (seek-based windowing), search.

---

## Keyboard reference

| Key | Action | Key | Action |
|---|---|---|---|
| ↑ ↓ / PgUp PgDn / Home End | move cursor | `Tab` | switch panel |
| ← → | PgUp / PgDn | `Backspace` | parent folder (empty cmd line) |
| `Enter` | enter dir / run program | `Esc` | clear cmd line |
| `F3` | view file | `F5` | copy (tagged set or cursor) |
| `F6` | rename / move | `F7` | make directory |
| `F8` | delete (tagged set or cursor) | `Insert` | tag entry |
| `Alt+F1` / `Alt+F2` | left / right drive | `F10` | quit |
| click | select entry | dbl-click | open entry |
| right-click | tag entry | click F-bar | invoke that F-key |

---

## Build & test

- **Assemble:** `nasm -f bin cc.asm -o cc.com` (NASM 2.x).
- **Run:** `cc.com` on any DOS, or `MOUNT C <dir>` in DOSBox.

The repo includes a headless regression harness used during development:

- `cc.com /D` renders one frame, dumps the 80×25 screen (characters only) to
  `CCDUMP.TXT`, and exits.
- `cc.com /T` plays a scripted keystroke file `cc.key` (byte pairs of
  AL=ascii, AH=scan), dumping a frame after every step. This is how every
  feature above was verified without a human at the keyboard.
- `cc.com /S` copies the raw 80×25 video page to `CCSNAP.BIN`;
  `render_snap.ps1` turns it into a colour PNG with the real VGA text
  palette — used to produce the screenshot above.
- `run_test.ps1 -ccArgs /T -keyfile keys_xxx.bin` assembles, runs the program
  under DOSBox Staging with a timeout, and prints `CCDUMP.TXT`.

---

## Source map (`cc.asm`)

| Area | Routines |
|---|---|
| Start / arg parse / memory shrink / mouse init | `start` |
| Key dispatch | `dispatch`, `key_*`, `on_*` |
| Render | `render_all`, `draw_frames`, `draw_panel`, `pick_attr`, `draw_titles`, `draw_cmdline`, `draw_fkeys` |
| Directory model | `read_dir`, `accept_dta`, `build_search`, `sort_panel`, `order_cmp` |
| Paths | `path_append`, `path_up`, `go_parent`, `bp_copy_dir`, `bp_copy_name`, `build_entry_path`, `build_target_path`, `build_other_path` |
| Modal dialogs | `dlg_box`, `dlg_input`, `dlg_confirm`, `dlg_draw_buttons`, `dlg_overwrite`, `ow_draw_buttons`, `dlg_field`, `busy_box`, `busy_name` |
| File ops | `key_mkdir`, `key_delete`, `key_copy`, `key_rename`, `count_tagged`, `copy_one`, `delete_one`, `copy_file`, `refresh_panels` |
| Recursive trees | `copy_tree`, `del_tree`, `set_dta_cur`, `cur_dta_ptr`, `make_findpat` |
| Mouse (INT 33h) | `mouse_poll`, `mouse_hit`, `mouse_left`, `mouse_right`, `mouse_confirm`, `mouse_overwrite`, `mouse_show`, `mouse_hide`, `fbar_to_key` |
| Viewer | `key_view`, `view_move`, `view_build_lines`, `render_view` |
| Shell-out | `run_command`, `get_comspec`, `build_tail`, `fill_epb`, `run_exec` |
| Test harness | `open_dump`, `dump_screen`, `load_keys`, `get_key`, `selftest` |
