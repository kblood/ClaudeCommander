# Claude Commander — Windows console port (`wincc`)

A native Win32 port of Claude Commander that runs **directly in a Windows
10/11 console** (cmd, Windows Terminal, PowerShell host) as a normal `.exe` —
no DOSBox, no 16-bit subsystem.

## Why a separate port?

The DOS build (`../cc.asm` → `cc.com`) is a 16-bit real-mode program. **64-bit
Windows cannot run 16-bit executables at all** (there is no NTVDM), so `cc.com`
only runs under DOSBox / on real DOS / on the MiSTer ao486 core. This port is a
fresh C implementation on the Win32 Console + File APIs that shares the DOS
version's *design* — the 80×25 char-cell UI and the same attribute palette —
but not its source. The key map is **similar but not identical** (see the key
table below): there is no command line, so typing letters starts a quick
search and `Esc` quits; `F2` renames (DOS: user menu); `Ctrl+S` cycles the sort
(DOS: `Ctrl-F1..F4`); and `F1` help / `F9` menu bar are not implemented, so
their slots on the F-key bar are left blank.

What the port gains by leaving DOS behind:

- **No 64 KB segment wall.** The single hardest DOS constraint is gone; every
  feature can live in one binary instead of being pushed to external helpers.
- **Native long filenames + 64-bit sizes** via `FindFirstFileW`.
- **One-call file ops** (`CopyFileW`/`MoveFileExW`/`DeleteFileW`).

### File-operation safety

- A folder is never copied or moved into itself or its own subfolder (checked
  on resolved, case-insensitive full paths; `A2` is not "inside" `A`).
- A folder move that can't be a rename (other volume, locked file) falls back
  to copy + delete, and the source is deleted **only if every item copied**.
- Junctions and symlinks are never followed: delete removes the link itself,
  copy skips folder links (reported as failures, so a move keeps its source)
  and copies file symlinks as the contents of their target.
- Existing targets are never overwritten silently: F5/F6 ask
  `[Y] Overwrite  [N] Skip  [Esc] Cancel`.
- Every failure is counted and shown on the status row (`Copy: 3 done, 1
  failed: <system error>`); the read-only bit is cleared only right before that
  item's own delete and put back if the delete fails.
- Paths that would exceed `MAX_PATH` are refused, never truncated.
- F3 shows at most the first 8 MB of a file.

The rendering and input models map almost 1:1 onto Win32: a `CHAR_INFO` cell is
a VGA text-mode word (same low-nibble-fg / high-nibble-bg attribute layout), and
`ReadConsoleInput` gives the same key info the DOS build read from INT 16h.

## Build

```powershell
.\build.ps1        # gcc -O2 -Wall -o cc.exe cc.c  (MinGW)
```

## Run

```
cc.exe             # opens both panels on the current directory
```

### "cd on exit" (leave the shell in the active panel's folder)

Like Norton/Volkov/Far, cc can drop you in the directory of its active panel
when you quit. On Windows a process can't change its parent shell's current
directory, so this needs a one-line wrapper that cc ships with:

```powershell
.\cc.ps1           # PowerShell: session ends in the active panel's folder
```
```
cc.cmd             # cmd.exe: same, for a classic console
```

Both set `%CC_CWD_FILE%`, run `cc.exe`, then `cd` to the path cc wrote there on
exit. Put this folder on your `PATH` (or copy the wrapper) to use `cc` everywhere.
Running `cc.exe` directly still works — it just can't move the shell afterwards.
The file is UTF-8 (no BOM): `cc.ps1` reads it with `-Encoding UTF8`, and
`cc.cmd` switches to `chcp 65001` just for the read and then restores your
codepage, so folders with non-ANSI names (e.g. `Æblegrød Ж中`) work from both.

`cc.exe` needs a real console on stdin/stdout; if either is redirected it exits
with a message (code 2) instead of running. Use the headless mode below for
scripting.

| Key | Action |
|---|---|
| ↑ ↓ PgUp PgDn Home End | move cursor |
| Enter | descend into dir / `..` to go up |
| Tab | switch active panel |
| Ins / Space | tag / untag |
| F2 | rename cursor entry |
| F3 | view file (scroll, Esc/F3 to close) |
| F4 | edit cursor file (`%EDITOR%`, else notepad) |
| F5 | copy cursor / tagged set to the other panel |
| F6 | move cursor / tagged set to the other panel |
| F7 | make directory |
| F8 / Del | delete cursor / tagged set (with confirm) |
| Alt+F1 / Alt+F2 | choose drive for left / right panel |
| Ctrl+S | cycle sort: name → ext → size → date |
| Ctrl+T | cycle colour theme: blue → black → mono |
| (type letters) | quick incremental search; Backspace edits, Esc clears |
| F10 / Esc | quit (Esc first clears an active quick search) |
| F1 / F9 | not bound in this port (blank on the F-key bar) |

The active panel's sort mode and the current theme are shown on the status row;
while quick-searching it shows the search string.

The UI **follows the live console window size**: grab a corner and drag, or
maximise, and both panels, the status row and the F-key bar re-lay-out on the
next frame (down to a 24×8 floor, up to a 512×256 ceiling). Resize is driven
by `ENABLE_WINDOW_INPUT` + a per-frame `GetConsoleScreenBufferInfo` poll, so it
tracks font/zoom changes too, not just window drags.

## Headless self-test

The same render path can run without an interactive console, for CI:

```
cc.exe --dir <path> [--rdir <path>] [--keys <file>] --dump <out> [--dumpa <out>]
```

- `--keys` replays a whitespace-separated token script (`UP DOWN ENTER TAB TAG
  PGUP PGDN HOME END QUIT COPY MOVE DEL VIEW SORT THEME EDIT DRIVESL DRIVESR
  RENBOX`, plus arg-carrying `MKDIR:<name>`, `REN:<name>`, `SORT:name|ext|size|date`,
  `TYPE:<text>` (quick search), `DRIVE:<letter>`). `DEL` deletes without the
  confirm dialog; when `COPY`/`MOVE` open the overwrite dialog, it is answered
  with `YES` / `NO` / `CANCEL` (any other token is ignored while it is open).
- `run_test.ps1 [-Work <dir>]` puts its test data (including junctions and
  deletes) under `<dir>` instead of this folder.
- `--size WxH` composes the frame at an arbitrary size (default 80×25), so the
  resize layout can be regression-tested without a real console.
- `--dump` writes the final screen as UTF-8 text; `--dumpa` writes the
  per-cell attribute bytes as hex. `run_test.ps1` asserts against both.
- if `%CC_CWD_FILE%` is set, the active panel's path is written there on exit
  (also in `--dump` mode), so the cd-on-exit path is regression-tested headlessly.

## Status

- **Milestone 1 (done):** framebuffer, dual panels, directory read (LFN),
  navigation, Tab, descend/ascend, tagging, quit.
- **Milestone 2 (done):** file operations — copy / move (recursive for dir
  trees), delete (recursive, with confirm dialog), mkdir, rename — on the
  cursor entry or the tagged set; modal text-input widget; F3 file viewer
  (scrollable).
- **Milestone 3 (done):** sort modes (name / ext / size / date) per panel, and
  runtime colour themes (blue / black / mono), both shown on the status row.
- **Milestone 4 (done):** quick incremental search (type to jump), drive
  selection (Alt+F1/F2 picker + direct), F4 edit launch.
- **Milestone 5 (done):** live console resize — the layout follows the terminal
  window size each frame; `--size WxH` headless seam.
- **Milestone 6 (done):** cd-on-exit — the active panel's folder is exported via
  `%CC_CWD_FILE%`, and `cc.cmd` / `cc.ps1` wrappers leave the shell there.
  `run_test.ps1` 38/38 green.
- **Hardening (2026-09):** file-op safety rules above (move/copy into self,
  junction-safe delete/copy, overwrite confirm, failure reporting), viewer
  line-table overflow, `MAX_PATH` truncation, no-console spin, UTF-8
  cd-on-exit. `run_test.ps1` 53/53 green.
- **Next:** command line with history, directory bookmarks/hotlist, copy
  progress for large files.
