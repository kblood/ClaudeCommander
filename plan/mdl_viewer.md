# CCMDL — Quake .mdl Viewer Integration Design

**Status:** Design phase. No cc files have been modified; wiring happens in a later phase.
**Last updated:** 2026-06-30

---

## 1. Overview

CCMDL is a standalone `.COM` helper that renders Quake Alias `.mdl` models in
VGA mode 13h (320x200, 256-colour) using the streaming renderer already proven
in `C:\LLM\DOS\ASMQuake\src\m4_anim.asm`.  It plugs into cc's standard Layer-3
helper pattern: the file manager EXECs it with the cursor file's full path on
the command line, it renders the model, and exits back.  No resident changes to
`cc.com` are needed.

---

## 2. Naming convention

All cc Layer-3 helpers follow the pattern `c<name>.asm → CC<NAME>.COM`.
Existing viewers: `cimg.asm → CCIMG.COM`, `cwav.asm → CCWAV.COM`.

**This tool:**
- Source file: `C:\LLM\DOS\cc\cmdl.asm`
- Output binary: `CCMDL.COM`
- Consistent with the naming series.

---

## 3. cc Viewer Dispatch — how it currently works (with evidence)

### 3a. F3 key handler
`mod/viewer.inc` line 9 — `key_view:` is bound to scan-code `3Dh` (F3) in the
keytab (`cc.asm` line 3306: `KEYBIND_EXT 3Dh, key_view`).

### 3b. Extension lookup
Inside `key_view` (`mod/viewer.inc` lines 35–47), under `%ifdef FEAT_VIEW`:

```asm
call    view_lookup         ; CF=1 -> di = viewer helper
jnc     view_open_builtin
call    run_view_helper
ret
```

`view_lookup` (`mod/ini.inc` lines 600–604) looks up the file's extension in
`viewmap` using the shared `map_lookup` routine.  `viewmap` is populated from
`cc.ini`'s `[view]` section at startup (`ini_load`, `mod/ini.inc` lines 16–18
and 158–163).

### 3c. Running the helper
`run_view_helper` (`mod/viewer.inc` lines 168–181):

```asm
run_view_helper:
    mov     si, di              ; di -> helper name in viewmap
    mov     di, cmdbuf
    call    vfs_cat             ; append helper name
    mov     byte [di], ' '
    inc     di
    mov     si, targpath
    call    vfs_cat             ; append full file path
    mov     ax, di
    sub     ax, cmdbuf
    mov     [cmdlen], ax
    call    run_command         ; EXEC, wait, re-read panels
    ret
```

So the viewer is invoked as:
```
CCMDL C:\GAMES\QUAKE\PROGS\SOLDIER.MDL
```

### 3d. Viewer exit convention
`run_command` (cc's EXEC path) simply waits for the child to exit.  The helper
must:
1. Restore 80x25 text mode (`INT 10h AX=0003h`) before exiting.
2. Exit with `INT 21h AH=4Ch AL=0` (DOS terminate, exit-code 0 on success,
   non-zero on error — cc does not currently check the code, but 0 is the
   convention).

No IPC, no shared memory, no special exit code format beyond the above.

### 3e. Filename acquisition
Helper reads PSP command tail: `[80h]` = tail length (byte), `[81h..]` = the
text (space + args).  Identical approach to `cimg.asm` (`parse_args` at line
833 of `cimg.asm`): skip leading spaces, copy until space or CR/NUL.

### 3f. cc.ini [view] map
`cc.ini` (root copy, line 38 onward):
```
[view]
gif = CCIMG
pcx = CCIMG
bmp = CCIMG
wav = CCWAV
...
```
Each `ext = HELPER` line maps a lowercase extension to an external viewer COM
(without `.COM` suffix; cc appends nothing — the name is passed directly to the
EXEC path via `COMSPEC /C`).

The map holds up to `OPENMAX` (12) entries (`cc.asm` line 87).  Currently 9
`[view]` entries are used, leaving room for `mdl`.

---

## 4. Screen-mode save / restore

**No save needed for the panel screen.**  `run_command` already blanks and
re-reads both panels when the helper exits.  The helper just needs to:

1. Switch to mode 13h (`INT 10h AX=0013h`) AFTER a successful parse (so any
   error message can be printed in text mode first).
2. Exit by calling `INT 10h AX=0003h` to restore text mode.

This matches `cimg.asm` (`show_image` at line 769) and `m4_anim.asm`
(`set_mode13` / `set_text_mode` via `vga.inc`).

---

## 5. Memory model

The ASMQuake renderer uses a streaming approach: the `.mdl` file stays open and
only small blocks are buffered at a time.  Key constants from `m4_anim.asm`:

```
MAXVERTS  equ 600    ; real models: soldier=170, player=212, dog=236, ogre=296
MAXTRIS   equ 1024   ; real models: soldier=328, player=408, dog=426
MAXPOSES  equ 256    ; real models: soldier=114, ogre=147, player=143
```

Working arrays (initialised data, NOT `.bss`):
- `mverts`: MAXVERTS × 3 × 4 B = 7200 B
- `vvx/vvy/vvz`: 3 × MAXVERTS × 4 B = 7200 B
- `scrx/scry`: 2 × MAXVERTS × 2 B = 2400 B
- `tri_idx`: MAXTRIS × 3 × 2 B = 6144 B
- `pose_ofs`: MAXPOSES × 4 B = 1024 B
- `vbufA/vbufB`: 2 × MAXVERTS × 4 B = 4800 B
- `vt0x..vkey`: 8 × MAXTRIS × 2 B = 16384 B

Total working arrays: ~45 KB.  Plus code + data headers + strings: ~3 KB.
Plus 64000-byte back-buffer allocated from DOS heap (not in the segment).
Total resident: ~48 KB, well under the 64 KB `.COM` limit.

The back-buffer is allocated with `INT 21h AH=48h` (same as `m4_anim.asm`).
If the allocation fails, the viewer can fall back to drawing directly to
`A000:0000` (no double-buffering) rather than aborting.

---

## 6. Key controls

| Key | Action |
|-----|--------|
| `ESC` | Exit viewer, return to cc |
| `Left` / `Right` arrows | Yaw model left / right (manual rotation) |
| `Up` / `Down` arrows | Pitch model up / down |
| `Space` | Toggle auto-tumble on/off (default: on) |
| `N` | Next animation frame (manual step, pauses auto) |
| `P` | Previous animation frame (manual step, pauses auto) |
| `A` | Toggle animation play/pause (keeps current angle) |
| `F3` or `Q` | Also quit (mirrors cc's built-in viewer) |

Auto-tumble rotates yaw+pitch each frame (same as `m4_anim.asm`'s `update_angles`).
Animation auto-play steps through poses (same as `advance_pose`).
Manual keys override auto-tumble / auto-animation for that frame.

---

## 7. Build recipe

### Standalone assemble (development):
```
nasm -f bin cmdl.asm -o CCMDL.COM
```

The skeleton uses `%include "vga.inc"` to pull in the shared VGA helpers.
When porting the ASMQuake core, the include path `-isrc\` used in ASMQuake
maps to a local include in the cc tree: copy `vga.inc` into the cc root (or
a local `inc/` subdir) and `%include "vga.inc"` (or `%include "inc/vga.inc"`).

### Integration into package.ps1 (LATER phase):
In `package.ps1`, add to the `$bins` array (after the `cwav.asm` entry):
```powershell
@{ src = "cmdl.asm"; com = "CCMDL.COM" },
```

### Integration into cc.ini (LATER phase):
Under the `[view]` section, add:
```ini
mdl = CCMDL
```

### Verification driver (LATER phase):
Create `run_mdl.ps1` following the pattern of `run_img.ps1`: assemble
`cmdl.asm`, mount the cc dir in DOSBox, run `CCMDL <mdl-file>`, capture a
screenshot, verify the mode was entered and the viewer exited cleanly.

---

## 8. Changes needed in cc's existing files (LATER implementation phase)

The following changes to **existing** cc files are deferred until the renderer
is verified.  Listed precisely so a follow-up agent can apply them:

### 8a. `C:\LLM\DOS\cc\cc.ini` — add one line under `[view]`
**After** the line `wav = CCWAV` (currently line 44 of cc.ini), add:
```
mdl = CCMDL
```
Note: `OPENMAX` (12) allows 12 `[view]` entries; currently 9 are used, so
there is room.

### 8b. `C:\LLM\DOS\cc\package.ps1` — add CCMDL to the build list
In `package.ps1` at line 32 (after `cwav.asm` entry), insert:
```powershell
    @{ src = "cmdl.asm";  com = "CCMDL.COM"  },
```

### 8c. `C:\LLM\DOS\cc\cc.hlp` — add viewer documentation
Find the "Viewers" section in `cc.hlp` and add:
```
CCMDL <file>    Quake Alias .mdl viewer (VGA mode 13h, flat-shaded, animated)
```

### 8d. `C:\LLM\DOS\cc\README.md` — add CCMDL to the viewers table
In the "Bundled tools & file associations" section, under the Viewers table,
add a row:
```
| `CCMDL` | Quake Alias .mdl models (flat-shaded 3D, animated) | `.mdl` |
```

No changes to `cc.asm`, `mod/*.inc`, or any build profile define are needed.
The `viewmap` (OPENMAX=12 slots) has capacity; the `FEAT_VIEW` path is already
in the STD build.

---

## 9. Implementation phase checklist (for the porting agent)

Use this ordered checklist when the rendering agent runs. All work should be
done in `C:\LLM\DOS\cc\cmdl.asm` (fill the TODOs in the skeleton) unless
noted.

- [ ] Copy `C:\LLM\DOS\ASMQuake\src\vga.inc` into the cc root (or reference
      it from the ASMQuake tree with an absolute include if NASM supports it).
- [ ] Port `open_model` from `m4_anim.asm` (trivial: open by `mdlname` -> open
      by the arg in `fname`; just change the `mov dx, mdlname` to `mov dx, fname`).
- [ ] Port `seek_cursor`, `read_chunk`, `skip32`, `parse_model`, `record_pose`
      verbatim from `m4_anim.asm` — no changes needed beyond the fname fix.
- [ ] Port `load_pose_buf`, `advance_pose`, `unpack_pose` verbatim.
- [ ] Port `transform_verts`, `build_vislist`, `sort_vislist`, `draw_vislist`,
      `swap_records`, `scan_right`, `fill_scan` (rasteriser) verbatim.
- [ ] Port `clear_back`, `flip`, `update_angles`, `wait_vsync` verbatim (or
      include `vga.inc` for `set_mode13`/`set_text_mode`/`wait_vsync`).
- [ ] Port `set_gray_palette` verbatim (or from `vga.inc`).
- [ ] Wire the main key loop: map arrow keys, Space, N/P, A, ESC, F3/Q.
- [ ] Add the back-buffer allocation path and its failure fallback.
- [ ] Add the error path: if `parse_model` fails, print an error message to
      stdout in text mode, close the file handle, exit with code 1.
- [ ] Assemble: `nasm -f bin cmdl.asm -o CCMDL.COM` and check for errors.
- [ ] Test with `C:\LLM\DOS\ASMQuake\models\soldier.mdl` (the simplest known-
      good model: 170 verts, 328 tris, 114 poses).
- [ ] Apply the cc.ini, package.ps1, cc.hlp, README.md changes listed in §8.
- [ ] Optionally write `run_mdl.ps1` test driver.
- [ ] Smoke-test from cc: navigate to a .mdl file, press F3, verify viewer
      loads and ESC returns cleanly.
