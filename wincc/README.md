# Claude Commander — Windows console port (`wincc`)

A native Win32 port of Claude Commander that runs **directly in a Windows
10/11 console** (cmd, Windows Terminal, PowerShell host) as a normal `.exe` —
no DOSBox, no 16-bit subsystem.

## Why a separate port?

The DOS build (`../cc.asm` → `cc.com`) is a 16-bit real-mode program. **64-bit
Windows cannot run 16-bit executables at all** (there is no NTVDM), so `cc.com`
only runs under DOSBox / on real DOS / on the MiSTer ao486 core. This port is a
fresh C implementation on the Win32 Console + File APIs that shares the DOS
version's *design* — the 80×25 char-cell UI, the same attribute palette, the
same key map — but not its source.

What the port gains by leaving DOS behind:

- **No 64 KB segment wall.** The single hardest DOS constraint is gone; every
  feature can live in one binary instead of being pushed to external helpers.
- **Native long filenames + 64-bit sizes** via `FindFirstFileW`.
- **One-call file ops** (`CopyFileW`/`MoveFileExW`/`SetFileTime`).

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

| Key | Action |
|---|---|
| ↑ ↓ PgUp PgDn Home End | move cursor |
| Enter | descend into dir / `..` to go up |
| Tab | switch active panel |
| Ins / Space | tag / untag |
| F10 / Esc | quit |

## Headless self-test

The same render path can run without an interactive console, for CI:

```
cc.exe --dir <path> [--rdir <path>] [--keys <file>] --dump <out> [--dumpa <out>]
```

- `--keys` replays a whitespace-separated token script (`UP DOWN ENTER TAB TAG
  PGUP PGDN HOME END QUIT`).
- `--dump` writes the final 80×25 screen as UTF-8 text; `--dumpa` writes the
  per-cell attribute bytes as hex. `run_test.ps1` asserts against both.

## Status

- **Milestone 1 (done):** framebuffer, dual panels, directory read (LFN),
  navigation, Tab, descend/ascend, tagging, quit. `run_test.ps1` 9/9 green.
- **Next:** file operations (copy/move/delete/mkdir/rename), F3 viewer, then the
  features the DOS build couldn't fit (command history, bookmarks, colour
  themes, view modes).
