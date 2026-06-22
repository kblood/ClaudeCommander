# Claude Commander (`cc`)

A Norton/Volkov-Commander-style two-panel file manager for DOS, written in
hand-tuned 16-bit x86 assembly. Targets 8086-and-up real mode (assembled for
`386` so it can use `movzx`/`imul-imm` — ideal on the 486-class ao486 core),
80×25 colour text mode, MS-DOS / FreeDOS / DOSBox.

```
nasm -f bin cc.asm -o cc.com
```

**The whole program is one `.COM` file of under 5 KB.**

---

## The size story — "less than 200 KB on a floppy"

The original goal was "small enough to live on a boot floppy, like Volkov
Commander (~64 KB)." Claude Commander lands far under that:

| Build | Size |
|---|---|
| `cc.com` (current, with viewer) | **4,781 bytes** |
| Stage A (panels + nav only) | 3,044 bytes |

That is ~0.4 % of a 1.44 MB floppy, and ~2.4 % of the 200 KB budget. How:

1. **Flat `.COM`, not `.EXE`.** No MZ header, no relocations, no segment
   tables. `org 100h`, one segment, code+data+stack share 64 KB.
2. **Reserved buffers live in `section .bss` (`nobits`).** The directory
   arrays (two panels × 700 entries × 24 bytes ≈ 33 KB *each*), the 32 KB
   viewer buffer, the line table, key/dump scratch — none of it is emitted
   into the file. The `.COM` only carries *code + initialized strings*; the
   ~70 KB of working RAM is claimed at runtime and zeroed by us as needed.
   This is the single biggest size lever: without it the file would be ~100 KB
   of zero-padding.
3. **No libc, no runtime.** Every service is a raw `INT 21h` / `INT 10h` /
   `INT 16h` call. There is nothing to link.
4. **Direct video writes to `B800:0000`.** No BIOS TTY, no ANSI driver. The
   renderer pokes character/attribute word-pairs straight into text VRAM.
5. **Shared code paths.** One frame-drawing routine for both panels, one
   modal-dialog box reused by every file operation, one path-builder helper
   family (`bp_copy_dir`/`bp_copy_name`) behind mkdir/copy/move/delete.

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
- `Tab` switches the active panel.
- `Enter` on a directory descends; on `..` goes up; on an `.EXE/.COM/.BAT`
  runs it from the panel's directory.

**Command line**
- Type a command after the `path>` prompt; `Enter` shells out through
  `COMSPEC /C`, with SS:SP and DTA saved/restored across the EXEC.
- `Esc` clears the line; `Backspace` edits it.

**File operations** (each pops a modal dialog and refreshes both panels)
- `F3`  **View** — scrollable text pager (↑↓, PgUp/PgDn, Home/End, Esc/F3).
- `F5`  **Copy** — copy the current file to the other panel's directory.
- `F6`  **Rename/Move** — rename or move via an input dialog (`INT 21h 56h`).
- `F7`  **MkDir** — create a directory (input dialog).
- `F8`  **Delete** — delete a file or empty directory (Y/N confirm).
- `Insert` — tag/untag the current entry (cursor advances).
- `Alt+F1` / `Alt+F2` — switch the left / right panel to another drive.
- `F10` — quit.

### Deliberately deferred (room in the budget for all of these)

- F2 user menu, F9 pull-down menu bar, F1 help screen.
- Operating on the whole *tagged set* (copy/delete many) — tagging UI exists;
  the ops currently act on the cursor entry.
- Copy/Move progress + overwrite prompts; recursive directory copy/delete.
- File-mask filter (`+`/`-` select), sort-order menu, quick-search by typing.
- Viewer: hex mode, files larger than 32 KB (seek-based windowing), search.

---

## Keyboard reference

| Key | Action | Key | Action |
|---|---|---|---|
| ↑ ↓ / PgUp PgDn / Home End | move cursor | `Tab` | switch panel |
| `Enter` | enter dir / run program | `Esc` | clear cmd line |
| `F3` | view file | `F5` | copy |
| `F6` | rename / move | `F7` | make directory |
| `F8` | delete | `Insert` | tag entry |
| `Alt+F1` / `Alt+F2` | left / right drive | `F10` | quit |

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
- `run_test.ps1 -ccArgs /T -keyfile keys_xxx.bin` assembles, runs the program
  under DOSBox Staging with a timeout, and prints `CCDUMP.TXT`.

---

## Source map (`cc.asm`)

| Area | Routines |
|---|---|
| Start / arg parse / memory shrink | `start` |
| Key dispatch | `dispatch`, `key_*`, `on_*` |
| Render | `render_all`, `draw_frames`, `draw_panel`, `pick_attr`, `draw_titles`, `draw_cmdline`, `draw_fkeys` |
| Directory model | `read_dir`, `accept_dta`, `build_search`, `sort_panel`, `order_cmp` |
| Paths | `path_append`, `path_up`, `bp_copy_dir`, `bp_copy_name`, `build_entry_path`, `build_target_path`, `build_other_path` |
| Modal dialogs | `dlg_box`, `dlg_input`, `dlg_confirm`, `dlg_field` |
| File ops | `key_mkdir`, `key_delete`, `key_copy`, `key_rename`, `copy_file`, `refresh_panels` |
| Viewer | `key_view`, `view_move`, `view_build_lines`, `render_view` |
| Shell-out | `run_command`, `get_comspec`, `build_tail`, `fill_epb`, `run_exec` |
| Test harness | `open_dump`, `dump_screen`, `load_keys`, `get_key`, `selftest` |
