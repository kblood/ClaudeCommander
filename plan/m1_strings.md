# M1 — UI String Table + `MSG(id)` blueprint

Scope: ROADMAP §2 (the third foundation seam — "UI string table + `MSG(id)`")
and §3 (Layer-2 language files `*.lng`). READ-ONLY analysis of
`C:\llm\cc\cc.asm` (3722 lines, emitted `cc.com` = 7104 B). This doc is the
blueprint to be applied to `cc.asm` by hand next; **no edits were made**.

All user-visible `db` strings live in one contiguous block, the INITIALIZED
DATA section at **`cc.asm:3596`–`3639`**. There are **no** inline string
literals embedded in code paths — every displayed string is a named label in
that block, referenced by pointer. That makes the table migration mechanical.

---

## 0. How strings are emitted today (the DOS reality)

Two printing paths coexist in the current code:

| Path | Routine | Terminator | Used by |
|---|---|---|---|
| **Direct to B800 video RAM**, char+attr cell pairs | `putzstr` (`cc.asm:1904`), `draw_fkeys` (`883`), panel render (`1347`), `busy_box`/`busy_name` (`1927`+), `dlg_*` (`1974`+) | **NUL (`,0`)** | Everything on the live TUI: F-key bar, panel `<DIR>`/`<UP>`, dialog prompts, buttons, viewer header/footer |
| **DOS INT 21h AH=09h** (print string to stdout) | direct `mov ah,9` (`cc.asm:1667`, `1675`) | **`$` (24h)** | Only the two shell-out console messages: `s_runmsg`, `s_anykey` |

So the codebase **does mix both terminators**, but the split is clean and
tiny: exactly **2** strings are `$`-terminated (both shell-out console
notices), and **all other** UI strings are NUL-terminated because they are
poked straight into video memory by `putzstr`-style loops that stop on `0`.

`putzstr` (`cc.asm:1904`) is the canonical NUL writer:
```
.l: mov al,[si] / or al,al / jz .e / mov [es:di],al / mov [es:di+1],ah / inc si / add di,2 / jmp .l
```
The F-key bar loop (`draw_fkeys` `.ch` at `cc.asm:903`) and the panel-label
loop (`.lp` at `cc.asm:1347`) are independent NUL-stop copies of the same idea.

**Design choice (recommended): normalize the table to a single terminator =
NUL.** Keep the blob NUL-terminated for everything. For the 2 DOS-console
strings, print them through a tiny **NUL→DOS print shim** (`putz_dos`) that
walks the string writing one char at a time via INT 21h AH=02h, or copies into
a scratch buffer and appends `$`. This removes `$` from the data entirely so a
`.lng` file never has to carry two terminator conventions. (`s_runmsg` /
`s_anykey` also contain embedded `0Dh,0Ah` CRLFs — the shim must pass those
through verbatim; AH=02h does, naturally.) See §3 for the shim.

---

## 1. Complete string inventory

Grouped by UI area. "Term" = current terminator. Width-sensitive entries are
flagged in Notes; those are the ones a translator must not lengthen without
also touching geometry constants (see §5).

### A. F-key bar (`draw_fkeys`, slot = 8 cols each)

| Proposed MSG id | Label / line | Text | Notes |
|---|---|---|---|
| `MSG_FK_HELP`  | `fk0` 3598 | `1Help`  | NUL. Leading digit is rendered grey (the "1"), rest cyan (see `draw_fkeys` `'0'..'9'` test, `cc.asm:908`). **Width-sensitive: ≤8 cols incl. the digit(s); slot is overwritten by next slot so overflow is silently clipped, but keep ≤7 chars after the number.** |
| `MSG_FK_MENU2` | `fk1` 3599 | `2Menu`  | NUL. (F2 = user menu) |
| `MSG_FK_VIEW`  | `fk2` 3600 | `3View`  | NUL |
| `MSG_FK_EDIT`  | `fk3` 3601 | `4Edit`  | NUL |
| `MSG_FK_COPY`  | `fk4` 3602 | `5Copy`  | NUL |
| `MSG_FK_MOVE`  | `fk5` 3603 | `6Move`  | NUL |
| `MSG_FK_MKDIR` | `fk6` 3604 | `7MkDir` | NUL |
| `MSG_FK_DEL`   | `fk7` 3605 | `8Del`   | NUL |
| `MSG_FK_MENU9` | `fk8` 3606 | `9Menu`  | NUL. (F9 = pull-down bar) |
| `MSG_FK_QUIT`  | `fk9` 3607 | `10Quit` | NUL. **Two-digit prefix "10"; both digits render grey.** |

The bar is reached from a `dw fk_tbl[10]` pointer array (`cc.asm:3597`) that
`draw_fkeys` indexes by slot (`mov si,[fk_tbl+bx]`, `cc.asm:902`).

### B. Panel markers (panel render, `cc.asm:1333`/`1338`)

| Proposed MSG id | Label / line | Text | Notes |
|---|---|---|---|
| `MSG_DIR` | `str_dir` 3608 | `<DIR>` | NUL. Right-justified into the SIZEW size column (`.putlabel` `cc.asm:1339`). **Width-sensitive: must fit SIZEW; longer text overruns the size field / left-pads negative.** |
| `MSG_UP`  | `str_up`  3609 | `<UP>`  | NUL. Same right-justify path. Width-sensitive (≤ SIZEW). |

### C. Dialog prompts / titles

| Proposed MSG id | Label / line | Text | Notes |
|---|---|---|---|
| `MSG_MKDIR_PROMPT`   | `s_mkdir`    3624 | `Create directory:` | NUL. Drawn at `DLG_C0+2` row `DLG_R0+1`; interior width = `DLG_C1-DLG_C0-3 = 48` cols (`cc.asm:1949`). Keep ≤ ~46. |
| `MSG_RENAME_PROMPT`  | `s_rename`   3625 | `Rename/move current entry to:` | NUL. Same field. |
| `MSG_DRIVE_PROMPT`   | `s_drive`    3626 | `Switch to drive (A-Z):` | NUL. |
| `MSG_DEL_CONFIRM`    | `s_delconf`  3627 | `Delete the current entry?` | NUL. Shown by `dlg_confirm`. |
| `MSG_COPY_CONFIRM`   | `s_copyconf` 3628 | `Copy this file to the other panel?` | NUL. `dlg_confirm`. |
| `MSG_OVERWRITE_MSG`  | `s_owmsg`    3633 | `File exists - overwrite?` | NUL. `dlg_overwrite` line 1 (`cc.asm:2155`). |

### D. Dialog buttons (width-critical — see §5)

| Proposed MSG id | Label / line | Text | Cols | Geometry constant pair | Notes |
|---|---|---|---|---|---|
| `MSG_BTN_YES`    | `s_btn_yes` 3631 | `[ Yes ]`    | 7 | `YES_C0=28 / YES_C1=34` (`cc.asm:1821`) | NUL. `dlg_draw_buttons`. Mouse hit-test `mouse_confirm` (`cc.asm:2980`). |
| `MSG_BTN_NO`     | `s_btn_no`  3632 | `[ No ]`     | 6 | `NO_C0=45 / NO_C1=50`  (`cc.asm:1823`) | NUL. |
| `MSG_BTN_OVERWRITE` | `s_btn_ovr` 3634 | `[Overwrite]` | 11 | `OWR_C0=17 / OWR_C1=27` (`cc.asm:1826`) | NUL. `ow_draw_buttons`. Hit-test `mouse_overwrite` (`cc.asm:3005`). |
| `MSG_BTN_SKIP`   | `s_btn_skp` 3635 | `[Skip]`     | 6 | `SKP_C0=31 / SKP_C1=36` (`cc.asm:1828`) | NUL. |
| `MSG_BTN_ALL`    | `s_btn_all` 3636 | `[All]`      | 5 | `OAL_C0=40 / OAL_C1=44` (`cc.asm:1830`) | NUL. |
| `MSG_BTN_CANCEL` | `s_btn_can` 3637 | `[Cancel]`   | 8 | `CAN_C0=48 / CAN_C1=55` (`cc.asm:1832`) | NUL. |

### E. Busy / "please wait" boxes

| Proposed MSG id | Label / line | Text | Notes |
|---|---|---|---|
| `MSG_BUSY_COPY` | `s_busy_copy` 3629 | `Copying, please wait...` | NUL. Title passed to `busy_box` (ds:si = title). |
| `MSG_BUSY_DEL`  | `s_busy_del`  3630 | `Deleting, please wait...` | NUL. |

### F. Viewer (F3)

| Proposed MSG id | Label / line | Text | Notes |
|---|---|---|---|
| `MSG_VIEW_HDR` | `s_viewhdr` 3638 | `   [ View ]` | NUL. Header at `cc.asm:3420`. Leading 3 spaces are intentional indent. |
| `MSG_VIEW_BAR` | `s_viewbar` 3639 | ` Up/Dn PgUp/PgDn Home/End: scroll      Esc or F3: quit` | NUL. Footer hint bar at `cc.asm:3495`. **Width-sensitive: ~54 cols, sits on the 80-col status row; embedded run of spaces is layout padding between the two hint groups.** |

### G. Shell-out console messages (the only `$`-terminated UI text)

| Proposed MSG id | Label / line | Text | Notes |
|---|---|---|---|
| `MSG_RUN_RUNNING` | `s_runmsg` 3622 | `\r\n[Claude Commander] running command...\r\n` | **`$`-term** + embedded `0Dh,0Ah` before and after. Printed by INT 21h AH=09h at `cc.asm:1667`. |
| `MSG_RUN_ANYKEY`  | `s_anykey` 3623 | `\r\n[Claude Commander] Press any key to return to Claude Commander...\r\n` | **`$`-term** + embedded CRLFs. AH=09h at `cc.asm:1675`. |

### NON-translatable bytes (explicitly EXCLUDED from the table)

These are `db` directives that are **not** user-visible UI text and must stay
as raw bytes / their own labels — do not route through `MSG()`:

| Label / line | Bytes | Why excluded |
|---|---|---|
| `dumpname` 3610 | `CCDUMP.TXT` | Filename literal (test-dump output path). |
| `snapname` 3611 | `CCSNAP.BIN` | Filename literal (snapshot path). |
| `keyname` 3612 | `cc.key` | Filename literal (test keyfile). |
| `dumpsep` 3613 | `==== FRAME ====`+CRLF | Test-harness dump separator (CCDUMP.TXT), never on screen. |
| `dbg_cnt` 3615 | `count=` | Debug-dump field label, written to CCDUMP.TXT only (`dbg_panel_line` `cc.asm:3559`), not the live UI. |
| `s_comspec` 3616 | `COMSPEC=` | Environment-var key for the EXEC path; protocol string, not UI. |
| `s_defcom` 3617 | `COMMAND.COM` | Fallback shell path; protocol, not UI. |
| `s_slashc` 3618 | ` /C ` | Command-tail switch for COMMAND.COM; protocol. |
| `s_exe`/`s_com`/`s_bat` 3619-3621 | `EXE`/`COM`/`BAT` | 3-byte, **un-terminated** extension-match constants (compared against entry extensions). Not displayed. |
| Frame-draw chars (`C_TL`/`C_H`/… equ constants) | box-drawing codes | Glyph constants, not strings. |
| `A_*` attribute equs (`A_FKL`, `A_DLG`, …) | color bytes | Attributes, not text. |

(Confirmed there are **no** other quoted `db` literals in the file — the
exhaustive grep for `db '`/`db "` returns only the block above; all remaining
`db`/`resb` are `.bss` buffers, byte vars, or numeric/byte constants.)

**Totals:** 24 translatable strings (10 F-key + 2 panel + 6 prompts + 6
buttons + 2 busy + 2 viewer + 2 shell-out). 22 are NUL-terminated; 2 are
`$`-terminated.

---

## 2. Proposed MSG id enum (sequential `equ`s)

Sequential, grouped, 0-based. Order chosen so the F-key bar (the most
layout-fragile group) is contiguous at the front and matches the existing
`fk_tbl` order, letting `fk_tbl` be rebuilt as `MSG(MSG_FK_HELP)..` directly.

```nasm
; ---- M1 string-table IDs (count must equal MSG_COUNT) ----
; F-key bar (slot order = draw order)
MSG_FK_HELP       equ 0
MSG_FK_MENU2      equ 1
MSG_FK_VIEW       equ 2
MSG_FK_EDIT       equ 3
MSG_FK_COPY       equ 4
MSG_FK_MOVE       equ 5
MSG_FK_MKDIR      equ 6
MSG_FK_DEL        equ 7
MSG_FK_MENU9      equ 8
MSG_FK_QUIT       equ 9
; Panel markers
MSG_DIR           equ 10
MSG_UP            equ 11
; Dialog prompts / titles
MSG_MKDIR_PROMPT  equ 12
MSG_RENAME_PROMPT equ 13
MSG_DRIVE_PROMPT  equ 14
MSG_DEL_CONFIRM   equ 15
MSG_COPY_CONFIRM  equ 16
MSG_OVERWRITE_MSG equ 17
; Dialog buttons
MSG_BTN_YES       equ 18
MSG_BTN_NO        equ 19
MSG_BTN_OVERWRITE equ 20
MSG_BTN_SKIP      equ 21
MSG_BTN_ALL       equ 22
MSG_BTN_CANCEL    equ 23
; Busy boxes
MSG_BUSY_COPY     equ 24
MSG_BUSY_DEL      equ 25
; Viewer
MSG_VIEW_HDR      equ 26
MSG_VIEW_BAR      equ 27
; Shell-out console (printed via the DOS shim, see §3)
MSG_RUN_RUNNING   equ 28
MSG_RUN_ANYKEY    equ 29
MSG_COUNT         equ 30
```

---

## 3. The `MSG(id)` mechanism (NASM)

### 3.1 Storage — offset table + packed blob (recommended)

A `dw` table of **near offsets into the blob** (not full pointers), so a
`.lng` override only has to rewrite the table words, and the blob stays a
single relocatable region. In a `.COM` everything is one segment, so a 16-bit
offset is a complete pointer; `MSG(id)` resolves to a `ds:`-relative address.

```nasm
; ---- string table: word offsets into msgblob ----
msgtab:
    dw m_fk_help, m_fk_menu2, m_fk_view, m_fk_edit, m_fk_copy
    dw m_fk_move, m_fk_mkdir, m_fk_del, m_fk_menu9, m_fk_quit
    dw m_dir, m_up
    dw m_mkdir_p, m_rename_p, m_drive_p, m_delconf, m_copyconf, m_owmsg
    dw m_btn_yes, m_btn_no, m_btn_ovr, m_btn_skp, m_btn_all, m_btn_can
    dw m_busy_copy, m_busy_del
    dw m_view_hdr, m_view_bar
    dw m_run_running, m_run_anykey
; assert table length:
%if ($-msgtab)/2 != MSG_COUNT
  %error "msgtab length != MSG_COUNT"
%endif

; ---- packed blob: every entry NUL-terminated (normalized) ----
msgblob:
m_fk_help:   db '1Help',0
m_fk_menu2:  db '2Menu',0
m_fk_view:   db '3View',0
m_fk_edit:   db '4Edit',0
m_fk_copy:   db '5Copy',0
m_fk_move:   db '6Move',0
m_fk_mkdir:  db '7MkDir',0
m_fk_del:    db '8Del',0
m_fk_menu9:  db '9Menu',0
m_fk_quit:   db '10Quit',0
m_dir:       db '<DIR>',0
m_up:        db '<UP>',0
m_mkdir_p:   db 'Create directory:',0
m_rename_p:  db 'Rename/move current entry to:',0
m_drive_p:   db 'Switch to drive (A-Z):',0
m_delconf:   db 'Delete the current entry?',0
m_copyconf:  db 'Copy this file to the other panel?',0
m_owmsg:     db 'File exists - overwrite?',0
m_btn_yes:   db '[ Yes ]',0
m_btn_no:    db '[ No ]',0
m_btn_ovr:   db '[Overwrite]',0
m_btn_skp:   db '[Skip]',0
m_btn_all:   db '[All]',0
m_btn_can:   db '[Cancel]',0
m_busy_copy: db 'Copying, please wait...',0
m_busy_del:  db 'Deleting, please wait...',0
m_view_hdr:  db '   [ View ]',0
m_view_bar:  db ' Up/Dn PgUp/PgDn Home/End: scroll      Esc or F3: quit',0
; shell-out notices: keep the CRLFs in-blob, but NUL-terminate (no '$').
m_run_running: db 0Dh,0Ah,'[Claude Commander] running command...',0Dh,0Ah,0
m_run_anykey:  db 0Dh,0Ah,'[Claude Commander] Press any key to return to Claude Commander...',0Dh,0Ah,0
msgblob_end:
MSGBLOB_LEN equ msgblob_end - msgblob
```

### 3.2 The `MSG` macro — id → string pointer

Since `msgtab` holds offsets, the resolver is one indexed load. Provide it as
a macro that leaves the pointer in `si` (the register every existing draw
routine already expects):

```nasm
; MSG id  -> si = pointer to NUL-terminated string for that id
%macro MSG 1
    mov     si, [msgtab + (%1)*2]
%endmacro
```

Then every call site changes from e.g. `mov si, s_btn_yes` to `MSG MSG_BTN_YES`.
`fk_tbl` is no longer needed as a separate array — `draw_fkeys` can index
`msgtab` directly with the slot number (slots 0..9 == ids 0..9 by construction):
```nasm
;   mov bx, bp / shl bx,1 / mov si,[msgtab+bx]      ; replaces [fk_tbl+bx]
```
(If keeping the change minimal, leave `fk_tbl` as an alias: `fk_tbl equ msgtab`.)

### 3.3 Handling the two terminators — the print shim

Because the blob is normalized to **NUL**, the live-TUI sites are unchanged
(`putzstr`, the fkey/panel loops, busy/dialog draws all already stop on `0`).
Only the two DOS-console prints (`cc.asm:1667`, `1675`) must change from
`mov ah,9 / mov dx,s_runmsg / int 21h` to a NUL-aware shim:

```nasm
; putz_dos: ds:si = NUL-terminated string -> stdout via INT 21h AH=02h
putz_dos:
    push    ax
    push    dx
.l: mov     dl, [si]
    or      dl, dl
    jz      .e
    mov     ah, 02h
    int     21h
    inc     si
    jmp     .l
.e: pop     dx
    pop     ax
    ret
```
Call site becomes `MSG MSG_RUN_RUNNING` / `call putz_dos`. AH=02h emits each
byte literally, so the embedded `0Dh,0Ah` CRLFs pass through unchanged. This
keeps **one** terminator across the whole table — important so a `.lng` author
never has to know about `$`.

(Alternative if you prefer to keep AH=09h: append `$` at build time only for
those two ids via a second tiny blob, but that reintroduces dual terminators in
the data and complicates `.lng` override — not recommended.)

---

## 4. Runtime `.lng` override (design only)

Goal (ROADMAP §3, Layer 2): ship the compiled-in English table; let
`<lang>.lng` replace entries at startup without a rebuild. High-level flow,
all within the single `.COM` segment:

1. **Reserve a RAM override blob** in `.bss` (e.g. `lngblob resb ~1200`) sized
   to the worst-case translated text, plus a writable copy of `msgtab`
   (`msgtab_ram resw MSG_COUNT`). On startup, `rep movsw` the ROM `msgtab` into
   `msgtab_ram` and point `MSG` at `msgtab_ram` instead of the ROM table:
   `%macro MSG 1 / mov si,[msgtab_ram + (%1)*2] / %endmacro`. (Now an override
   = just rewriting a word in `msgtab_ram`.)
2. **File format** — line-oriented `ID=text`, one per line, ID = the numeric
   MSG id (or a symbolic name mapped by a small name table; numeric is
   smallest). Example `da.lng`:
   ```
   18=[ Ja ]
   19=[ Nej ]
   15=Slet markeret post?
   ```
   Escapes for control bytes: `\r` `\n` for CRLF in the two shell-out lines.
3. **Loader** (runs once, after the existing INI load seam):
   - Open `<lang>.lng` (lang name from `cc.ini` `[general] lang=` or default
     skip if absent). INT 21h 3Dh/3Fh into a read buffer.
   - For each `ID=text` line: parse the decimal id; copy `text` (translating
     `\r`/`\n`) into the next free spot in `lngblob`, append `0`; set
     `msgtab_ram[id] = offset_of(that_copy)`. Lines with no override leave the
     ROM offset intact, so partial translations are fine.
   - Bounds-check: ignore ids ≥ `MSG_COUNT`; stop if `lngblob` would overflow
     (translation truncated, not a crash).
4. **No pointer fix-ups elsewhere** — every UI site already goes through
   `MSG(id)`, so swapping the table words is the entire mechanism. `draw_fkeys`
   reading `msgtab_ram[0..9]` picks up translated F-key labels for free.
5. **Width safety at load** — optionally clamp each override copy to the field
   width for width-sensitive ids (the F-key 8-col slot, `<DIR>`/`<UP>` SIZEW,
   the buttons). Cheapest is "translator's responsibility + a debug-build
   length assert"; see §5.

RAM cost: `msgtab_ram` = 60 B, `lngblob` ≈ 1 KB — comfortably inside the
~13 KB headroom (ROADMAP §1). Both go in `.bss` so they cost **0** image bytes.

---

## 5. Risks

1. **Button widths are double-bound to geometry constants.** Each button's
   on-screen width is implied by its `*_C0/*_C1` column-span equ pair
   (`cc.asm:1821`–`1833`) AND used by the **mouse hit-test** (`mouse_confirm`
   `cc.asm:2980`, `mouse_overwrite` `cc.asm:3005`). The comments even pin the
   counts (`"[ Yes ]" (7 cols)` etc.). If a `.lng` lengthens `[Overwrite]` to a
   longer word, the text overdraws past `OWR_C1`, may collide with `[Skip]` at
   `SKP_C0=31`, and the click region no longer matches the glyphs. **Buttons
   are fixed-width: a translation must keep each button's printed length ≤ its
   `C1-C0+1` span, or the geometry equs + hit-tests must be regenerated.** This
   is the single biggest correctness risk in the whole seam.

2. **F-key bar column layout.** `draw_fkeys` (`cc.asm:883`) lays 10 labels on a
   strict **8-column grid** (`shl ax,4` = slot*16 bytes, `cc.asm:897`). Labels
   are not length-checked; a label longer than 8 cols is overwritten by the
   next slot (silent clip), and the leading-digit grey/cyan coloring keys off
   the chars being `'0'..'9'` (`cc.asm:908`) — a translation that drops the
   leading number breaks the two-tone coloring. **Keep the leading digit(s) and
   ≤7 trailing chars.** `fk9`/`MSG_FK_QUIT` already uses two digits ("10").

3. **`<DIR>`/`<UP>` are right-justified into the fixed SIZEW size column**
   (`.putlabel` `cc.asm:1339`–`1345`: `cx = SIZEW - strlen`). If a translation
   makes either longer than `SIZEW`, `cx` underflows (negative → huge unsigned)
   and the copy walks off the size field. **Must stay ≤ SIZEW chars.**

4. **Embedded control bytes** in `s_runmsg`/`s_anykey` (`0Dh,0Ah` CRLFs) — the
   `.lng` format needs `\r\n` escapes and the shim must emit them literally
   (AH=02h does). These two are also the only `$`-terminated strings today; the
   normalize-to-NUL + `putz_dos` shim (§3.3) removes that special case.

5. **`fk_tbl` is a second pointer array** (`cc.asm:3597`) that aliases the same
   strings as the proposed `msgtab`. Either rebuild `fk_tbl` from `MSG`s,
   `equ` it to `msgtab` (ids 0..9 align by construction), or delete it and index
   `msgtab` directly in `draw_fkeys`. Don't leave two divergent copies.

6. **Dialog prompt field width** = `DLG_C1-DLG_C0-3 = 48` cols
   (`cc.asm:1949`). Prompts/titles longer than ~46 chars overrun the box
   interior. The longest current prompt (`Copy this file to the other panel?`,
   34) has margin; Danish translations tend longer — watch this.

7. **Viewer footer bar** (`s_viewbar`, ~54 cols) lives on the 80-col status
   row; the run of spaces mid-string is deliberate spacing between the two hint
   groups. A translator must preserve total ≤ ~78 and may rebalance the gap.

8. **No strings are concatenated at runtime** (good): the only runtime string
   composition is the debug `dbg_panel_line` (`cc.asm:3553`) which is
   dump-file-only and excluded. Filenames (`dumpname`, etc.) and the EXEC
   protocol strings (`s_comspec`, `s_slashc`, ext constants) are **not** UI and
   must stay literal — translating them would break file I/O and shell-out.

9. **Byte-identical refactor goal (ROADMAP §6).** Moving labels into a blob +
   adding `msgtab` reorders/relocates data; the emitted `.com` bytes will
   change (new `dw` table, possibly different label order). Accept the
   "behaviourally identical + harness-green" bar for this seam rather than
   byte-identity. The keyfile harness (`keys_*.bin`, `/T` mode) exercises the
   dialogs/buttons and will catch a broken pointer or width regression.
