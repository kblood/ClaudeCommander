# M1 seam 1 — Data-driven key dispatch

Status: design, ready to apply by hand. Target: `C:\llm\cc\cc.asm`.
Scope: replace the flat `cmp ah,XX / je handler` chain at `dispatch:`
(`cc.asm:234-289`) with a table-walk driven by a `KEYBIND` macro, so each
`mod/*.inc` can register its own keys without editing a central routine.
**Behaviour must be byte-for-byte equivalent** (M1 acceptance bar).

---

## 1. The current dispatch — entry/exit register contract (documented reality)

### How dispatch is reached
Main loop (`cc.asm:205-216`):

```
main_loop:
        ...
        call    get_key             ; cc.asm:213  -> al=ascii, ah=scan
        call    dispatch            ; cc.asm:214
        cmp     byte [quit_flag], 0 ; cc.asm:215
        je      main_loop
```

`get_key` (`cc.asm:1626-1656`) is the **sole producer** of the input contract:

- **AL = ASCII** code, **AH = BIOS scan code** (INT 16h AH=00h legacy read,
  `cc.asm:1653`). For extended/grey keys (arrows, F-keys, Ins) BIOS returns
  **AL=0, AH=scan** — this is exactly the `al==0` test the dispatcher keys off.
- In test mode the bytes come verbatim from the key script (`al=[keybuf+bx]`,
  `ah=[keybuf+bx+1]`, `cc.asm:1634-1635`); end-of-script / no-driver synthesises
  **AL=0, AH=44h** (F10 → quit, `cc.asm:1639-1640`).

So the **two match classes are intrinsic to the producer**, not a convenience:
- AL==0  → it is an extended key; the discriminator is **AH (scan)**.
- AL!=0  → it is an ASCII key; the discriminator is **AL (ascii)**.

### `dispatch` contract (`cc.asm:234-289`)
- **Entry:** AL=ascii, AH=scan (as above). DS=ES=SS=PSP segment (flat .COM).
  Direction flag clear (`cld` set once at `start`, `cc.asm:87`, never set again
  on the main path).
- **Exit:** `ret` to `main_loop`. No documented register-preservation contract —
  `dispatch` and every handler **freely clobber AX/BX/CX/DX/SI/DI/BP**. The only
  state that matters across the call is memory: `[active]`, panel structs,
  `[cmdlen]`/`[cmdbuf]`, `[quit_flag]`. Nothing in `main_loop` reads a register
  after `dispatch` returns, so clobbering is safe and must stay allowed.
- **Reaching a handler:** the chain does `cmp ah,XX` / `je handler`. A taken `je`
  jumps **into** the handler label; the handler runs to its own `ret`, which
  returns directly to `main_loop` (one stack level — `dispatch` added none).
  i.e. handlers are **tail-called**, not `call`ed. Any table-walk replacement
  that uses `call handler` adds one extra `ret` worth of stack but is otherwise
  equivalent because handlers don't read the return address.

### The handlers — verified entry/exit (one line each)
All take the same AL/AH input (most ignore it and read `[active]` instead),
clobber freely, and terminate in `ret` (directly, via `.ret: ret`, or via a
`jmp` to a routine that returns). Confirmed by reading each label:

| Label | Line | Notes on contract |
|---|---|---|
| `key_up` | 336 | reads `[active]`, ignores AL/AH, `ret` |
| `key_down` | 347 | same; also **called by `key_tag`** (`cc.asm:3195`) |
| `key_pgup` | 363 | same |
| `key_pgdn` | 374 | same |
| `key_home` | 390 | same |
| `key_end` | 396 | same |
| `key_view` | 3239 | uses its own get_key loop; `ret` (uses AL/AH only inside `view_move`) |
| `key_copy` | 2457 | dialog-driven; `ret` |
| `key_rename` | 3080 | dialog-driven; `ret` |
| `key_mkdir` | 2366 | dialog-driven; `.ret: ret` |
| `key_delete` | 2381 | dialog-driven; `ret` |
| `key_tag` | 3183 | toggles tag then `call key_down`; `.ret: ret` |
| `key_drive_l` | 3199 | `jmp set_panel_drive` (which `ret`s) |
| `key_drive_r` | 3202 | `jmp set_panel_drive` (which `ret`s) |
| `key_quit` | 290 | sets `[quit_flag]`, `ret` |
| `key_tab` | 324 | swaps `[active]`, `ret` |
| `on_enter` | 295 | **ASCII handler**; branches to `run_command`/`key_enter`; returns |
| `on_esc` | 300 | clears `[cmdlen]`, `ret` |
| `on_bksp` | 304 | ASCII handler; `ret` (or `go_parent` then `ret`) |
| `cmd_addchar` | 315 | ASCII fallthrough handler; `ret`. **Entry: AL=char to append.** |

Key point for the redesign: **`cmd_addchar` is special** — it is not bound to a
single key, it is the *fallthrough* for the whole printable range
`20h..7Eh` (`cc.asm:282-286`) and it **consumes AL** as the character to append.

### The exact behaviours that must be reproduced 1:1
From `cc.asm:234-289`:

1. **AL==0 ⇒ scan-code (AH) match**, else **AL (ascii) match** (the `or al,al /
   jnz .ascii` split, lines 235-236).
2. **Aliases:** Left (AH=4Bh) → `key_pgup` (line 244); Right (AH=4Dh) →
   `key_pgdn` (line 248). i.e. two *different* scan codes map to the *same*
   handler. The table must allow duplicate handler targets.
3. **Printable-range fallthrough:** an ASCII key with `20h <= al <= 7Eh` that
   matched no explicit ASCII binding falls through to `call cmd_addchar`
   (lines 282-286). Below 20h or above 7Eh ⇒ do nothing.
4. **Default = do nothing** (`ret`) for any unmatched extended key (line 272)
   and any out-of-range ASCII key (lines 283/285 → `.ret`).
5. Order of the `cmp`s does not matter for correctness because every
   `{class,code}` pair is unique except the deliberate aliases — so a linear
   table scan reproduces it exactly.

The full current binding set (the rows we must reproduce), in file order:

| Class | Code | Handler | Line |
|---|---|---|---|
| ext | AH=48h Up        | key_up      | 238 |
| ext | AH=50h Down      | key_down    | 240 |
| ext | AH=49h PgUp      | key_pgup    | 242 |
| ext | AH=4Bh Left      | key_pgup    | 244 (alias) |
| ext | AH=51h PgDn      | key_pgdn    | 246 |
| ext | AH=4Dh Right     | key_pgdn    | 248 (alias) |
| ext | AH=47h Home      | key_home    | 250 |
| ext | AH=4Fh End       | key_end     | 252 |
| ext | AH=3Dh F3 View   | key_view    | 254 |
| ext | AH=3Fh F5 Copy   | key_copy    | 256 |
| ext | AH=40h F6 Ren    | key_rename  | 258 |
| ext | AH=41h F7 MkDir  | key_mkdir   | 260 |
| ext | AH=42h F8 Del    | key_delete  | 262 |
| ext | AH=52h Insert    | key_tag     | 264 |
| ext | AH=68h Alt+F1    | key_drive_l | 266 |
| ext | AH=69h Alt+F2    | key_drive_r | 268 |
| ext | AH=44h F10       | key_quit    | 270 |
| ascii | AL=09h Tab     | key_tab     | 274 |
| ascii | AL=0Dh Enter   | on_enter    | 276 |
| ascii | AL=1Bh Esc     | on_esc      | 278 |
| ascii | AL=08h Bksp    | on_bksp     | 280 |
| ascii | AL=20h..7Eh    | cmd_addchar | 282-286 (range fallthrough) |

That is **22 logical bindings** (21 single-key `je`s + 1 printable range).

---

## 2. The `KEYBIND` macro and the table row format

### Row format — 4 bytes per row
```
  db <class>      ; KB_EXT (0) or KB_ASC (1) — which register we match on
  db <code>       ; the AH scan (KB_EXT) or AL ascii (KB_ASC) to match
  dw <handler>    ; 16-bit NEAR offset of the handler in this segment
```
4 bytes is convenient (power-of-two; the walker can `add si,4`), and the `class`
byte cleanly encodes the two match classes instead of overloading "ascii==0".
(The `KEYBIND <ascii>,<scan>,<handler>` signature in the task maps to this:
exactly one of `<ascii>`/`<scan>` is non-zero per row, and the macro derives the
class from which one you give — see the two helper macros below. We keep a
single 2-arg form per row to avoid ambiguity.)

A `dw` handler offset is correct because all handlers live in the same 64 KB
`.COM` segment and are reached today by a near `je`/`jmp`; a near `call`
through the table is the same reachability. (See risks §6.)

### Constants and the macro
Place near the top with the other `equ`s (after `cc.asm:84`, before `start`):

```
KB_EXT      equ 0          ; match on AH (scan) — extended key (al was 0)
KB_ASC      equ 1          ; match on AL (ascii)

; --- KEYBIND emits one 4-byte table row into the keytab section ---
; Use exactly one of the two forms below per binding.

%macro KEYBIND_EXT 2        ; %1 = scan code (AH), %2 = handler label
        db      KB_EXT
        db      %1
        dw      %2
%endmacro

%macro KEYBIND_ASC 2        ; %1 = ascii code (AL), %2 = handler label
        db      KB_ASC
        db      %1
        dw      %2
%endmacro
```

If a single 3-arg `KEYBIND <ascii>,<scan>,<handler>` spelling is preferred (as
the task names it), define it to dispatch to the two helpers by which arg is
zero — this keeps call sites uniform:

```
; KEYBIND <ascii>, <scan>, <handler>
;   ascii==0 -> extended (match scan in AH); else ASCII (match ascii in AL)
%macro KEYBIND 3
  %if %1 == 0
        KEYBIND_EXT %2, %3
  %else
        KEYBIND_ASC %1, %3
  %endif
%endmacro
```

NASM evaluates `%if %1 == 0` at assemble time (both args are constants), so this
is zero-cost — it emits the same 4 bytes either way.

### Terminator / sentinel
End the table with a sentinel row whose class byte is `0FFh`:

```
KB_END      equ 0FFh
%macro KEYBIND_END 0
        db      KB_END
        db      0
        dw      0
%endmacro
```

The walker stops when it reads `class == KB_END`. (Alternatively, bound the
scan with a `keytab_end:` label and compare `si` against it — see §5 for why the
sentinel is the better fit for the scattered-include model.)

---

## 3. The new `dispatch:` loop

Drop-in replacement for `cc.asm:234-289`. Walks `keytab`, matches by class,
calls the handler, then applies the printable-range fallthrough exactly as
before. Preserves "do nothing" default.

```
; ============================================================================
;  DISPATCH  (data-driven; walks keytab built by KEYBIND rows)
;  Entry: al=ascii, ah=scan (from get_key). Clobbers freely. ret to main_loop.
; ============================================================================
dispatch:
        ; pick the class we are matching and the code byte, ONCE.
        ;   al==0  -> extended key, want class KB_EXT, code = ah (scan)
        ;   al!=0  -> ascii key,    want class KB_ASC, code = al (ascii)
        mov     dl, KB_ASC          ; assume ascii
        mov     dh, al              ; code to match = al
        or      al, al
        jnz     .haveclass
        mov     dl, KB_EXT          ; extended
        mov     dh, ah              ; code to match = scan
.haveclass:
        ; dl = wanted class, dh = wanted code. (al still = original ascii.)
        mov     si, keytab
.scan:
        mov     cl, [si]            ; row class
        cmp     cl, KB_END
        je      .nomatch            ; hit sentinel -> no explicit binding
        cmp     cl, dl
        jne     .nextrow            ; class differs (ext vs ascii)
        cmp     dh, [si+1]          ; code match?
        je      .hit
.nextrow:
        add     si, 4
        jmp     .scan
.hit:
        mov     bx, [si+2]          ; handler offset
        call    bx                  ; tail-equivalent; handler ret returns here
        ret
.nomatch:
        ; no explicit binding. ASCII printable range -> cmd_addchar.
        ; (al is still the original ascii here.)
        or      al, al
        jz      .ret                ; extended key with no binding -> nothing
        cmp     al, 20h
        jb      .ret
        cmp     al, 7Eh
        ja      .ret
        call    cmd_addchar         ; al = char to append (contract preserved)
.ret:
        ret
```

Notes:
- `call bx` then `ret` reproduces the old `je handler` tail-call: same one level
  of return into `main_loop`, handlers still see DS/ES/SS and AL/AH unchanged
  (we only used DL/DH/CL/SI/BX as scratch before the call, and explicit handlers
  ignore those — they read `[active]`; the one ascii handler that reads AL,
  `on_enter`/`on_bksp`/none-needed, still has AL intact because we never wrote
  AL). **AL is preserved into the handler**, matching the old behaviour where
  `cmd_addchar` and the ascii handlers ran with AL live.
- The fallthrough block is reached only when the scan found no row — identical
  to the old "fell off the end of the ascii `cmp`s" path.
- "Do nothing" default = both `.ret` paths, identical to old line 272 / 283-285.

DH/DL/CL are free scratch here (no handler depends on them on entry). If you
prefer not to touch DX, an equivalent version can keep the wanted code in a
register the table compare reads, but DX is the cleanest and is clobbered by
handlers anyway.

---

## 4. The KEYBIND rows — ready-to-paste, reproduces today 1:1

Put this where the table lives (see §5). Order is preserved from the current
chain for readability; order is not semantically required (all pairs unique
except the two intended aliases, which simply appear as two rows pointing at the
same handler).

```
keytab:
        ; ---- extended keys (al==0, match scan in ah) ----
        KEYBIND_EXT 48h, key_up         ; Up
        KEYBIND_EXT 50h, key_down       ; Down
        KEYBIND_EXT 49h, key_pgup       ; PgUp
        KEYBIND_EXT 4Bh, key_pgup       ; Left  -> page up   (alias)
        KEYBIND_EXT 51h, key_pgdn       ; PgDn
        KEYBIND_EXT 4Dh, key_pgdn       ; Right -> page down (alias)
        KEYBIND_EXT 47h, key_home       ; Home
        KEYBIND_EXT 4Fh, key_end        ; End
        KEYBIND_EXT 3Dh, key_view       ; F3  View
        KEYBIND_EXT 3Fh, key_copy       ; F5  Copy
        KEYBIND_EXT 40h, key_rename     ; F6  Rename/Move
        KEYBIND_EXT 41h, key_mkdir      ; F7  MkDir
        KEYBIND_EXT 42h, key_delete     ; F8  Delete
        KEYBIND_EXT 52h, key_tag        ; Insert  tag
        KEYBIND_EXT 68h, key_drive_l    ; Alt+F1  left drive
        KEYBIND_EXT 69h, key_drive_r    ; Alt+F2  right drive
        KEYBIND_EXT 44h, key_quit       ; F10
        ; ---- ascii keys (al!=0, match ascii in al) ----
        KEYBIND_ASC 09h, key_tab        ; Tab
        KEYBIND_ASC 0Dh, on_enter       ; Enter
        KEYBIND_ASC 1Bh, on_esc         ; Esc -> clear command line
        KEYBIND_ASC 08h, on_bksp        ; Backspace
        ; ---- printable range 20h..7Eh -> cmd_addchar is NOT a row; it is the
        ;      fallthrough handled inside dispatch (see §3). ----
        KEYBIND_END                     ; sentinel
```

The `cmd_addchar` printable-range behaviour is intentionally **not** a table
row, because it is a *range* (20h..7Eh) plus the consumes-AL semantics, not a
single `{code,handler}` pair. Encoding it as the dispatch fallthrough keeps the
table a pure exact-match structure and reproduces lines 282-286 verbatim. (If a
future module wants range bindings, add a `KB_RANGE` class with lo/hi bytes —
out of scope for the 1:1 M1 port.)

---

## 5. Where the table lives + assembler ordering

**Decision: the table is "host-anchored, module-contributed" via a NASM accumulator
macro.** The host core owns the `keytab:` start label and the `KEYBIND_END`
sentinel; modules contribute rows that NASM splices in **between** them at
assemble time. Two viable patterns:

### Pattern A (recommended) — fixed anchors + includes in the middle
The host defines the start label, then `%include`s every `mod/*.inc` (each of
which expands its `KEYBIND_*` rows inline at that point), then emits the
sentinel:

```
; in cc.asm data section:
keytab:
        ; core bindings (the §4 block, minus the sentinel)
        KEYBIND_EXT 48h, key_up
        ...
        KEYBIND_ASC 08h, on_bksp
%ifdef FEAT_SORT
        %include "mod/sort.keys.inc"   ; expands KEYBIND_* rows for sort
%endif
%ifdef FEAT_CLOCK
        %include "mod/clock.keys.inc"
%endif
        ; ... more module key-includes here ...
        KEYBIND_END                    ; sentinel closes the table
```

NASM processes `%include` **top-to-bottom, in place**, so each included file's
`KEYBIND_*` invocations emit their 4-byte rows exactly where the `%include`
sits — contiguously between `keytab:` and `KEYBIND_END`. This needs **no
linker, no relocation, no second pass**: it is a single flat `.COM` so every
handler label referenced by a row is resolved by NASM in the same assembly unit
(forward references are fine — `dw key_up` resolves even though `key_up` is
defined later). The module file only needs its handler labels in scope, which
they are because the same module's handler bodies are `%include`d elsewhere in
the file (per the §3 module convention in ROADMAP).

This keeps a module self-describing: `mod/sort.inc` has its handlers; its
`mod/sort.keys.inc` (or a `%ifdef`-gated block inside the same file, included at
the table point) has its `KEYBIND` rows. Adding a feature = add an `%include`;
**no edit to `dispatch:`**, which is the whole point of the seam.

### Pattern B — `%macro` accumulation (if you cannot interleave includes)
If modules are all `%include`d in one block and you do not want a key-include
split, accumulate rows into a macro-grown list and emit it once. NASM has no
mutable global list, but you can emulate it with a context/`%assign` counter or,
more simply, with a single-level `%define` chain. In practice Pattern A is
simpler and avoids NASM's macro-recursion limits, so **prefer A**; document B
only as the fallback when a module truly cannot own a key-include file.

### Why the sentinel, not a `keytab_end:` length compare
Both work. The sentinel (`KB_END`) is chosen because with scattered includes the
`keytab_end:` label must be emitted *after* the last include — which the host
already controls — but the sentinel also self-documents the table's end inside
the data and lets the walker be a pure forward scan with no end-pointer math
(one fewer thing for a module author to get wrong). If you want both, emit
`keytab_end:` right after `KEYBIND_END` and keep the sentinel as the primary
stop; they are not in conflict.

**Ordering implication to respect:** the start label, all module key-includes,
and the sentinel must be emitted in that order, and all within the same section
so the rows are physically contiguous (no other `db`/`dw` data interleaved).
Put `keytab` in the existing initialized-data area (near `fk_tbl`,
`cc.asm:3597`) so it is part of the emitted image, not `.bss`.

---

## 6. Risks / edge cases

1. **Handler offsets are 16-bit NEAR.** `dw <handler>` + `call bx` is a near
   call within the one 64 KB `.COM` segment. Correct here (same reachability as
   the current near `je`). If the image ever exceeds 64 KB this breaks — but the
   whole design already assumes a single segment (ROADMAP §1), so this is a
   non-risk for `cc`. Do **not** use `call far` or a `dw`+segment pair.

2. **`call bx` vs the old `je` (one extra stack word).** The old chain
   tail-jumped into handlers; the new walker `call`s them, pushing one return
   address. Handlers never read their return address and all end in `ret`, so
   behaviour is identical; the only cost is 2 bytes of stack during a handler,
   negligible against the 2048-byte stack. If you want to eliminate even that,
   replace `call bx` / `ret` with `jmp bx` (true tail-call) — but then the
   printable-range fallthrough cannot live after it, so keep `call bx; ret`.

3. **AL/AH must survive into the handler.** The walker uses DL/DH/CL/SI/BX as
   scratch and must **not** touch AL or AH before `call bx` (the ascii handlers
   and `cmd_addchar` read AL). The §3 code preserves AL/AH. Double-check no edit
   later clobbers AL in `.haveclass`.

4. **The two aliases (Left→PgUp, Right→PgDn).** Reproduced as two separate rows
   with the same handler offset. A linear exact-match scan handles duplicate
   targets with no special case — verify both rows are present (4Bh and 4Dh).

5. **`cmd_addchar` is a range, not a row.** It must stay as the dispatch
   fallthrough (lines 282-286 semantics: `20h<=al<=7Eh`). Encoding it as a
   single table row would be wrong (it would only match one code). Keep it out
   of the table.

6. **`key_tag` calls `key_down`.** Internal call, unaffected by the dispatch
   change — but note that `key_down` is now also reachable both via the table
   and via `key_tag`'s direct `call key_down` (`cc.asm:3195`). Both paths are
   fine; do not "optimize" `key_down` to assume it is only entered from the
   table.

7. **Default "do nothing".** Unmatched extended keys and out-of-range ascii must
   `ret` with no side effects (old lines 272, 283-285). The §3 `.nomatch`/`.ret`
   paths reproduce this. In particular AL between 01h..1Fh that is not Tab/Enter
   /Esc/Bksp (e.g. Ctrl-letters) must do nothing — the `cmp al,20h / jb .ret`
   guard preserves that.

8. **Sentinel collision.** `KB_END = 0FFh` is used as a class byte; ensure no
   real class value equals 0FFh (we use 0 and 1). Safe. Do not let a module
   emit a row with class 0FFh.

9. **Table must be in initialized data, not `.bss`.** If accidentally placed
   after the `.bss`/`resb` region it would not be emitted into `cc.com` and the
   walker would read garbage. Anchor it beside `fk_tbl` (`cc.asm:3597`), which
   is emitted.

10. **Byte-identical-output caveat (M1 acceptance).** This change *will* alter
    the emitted bytes (a table + a different `dispatch`), so the "byte-identical
    `.com`" goal from ROADMAP §6 cannot hold for this seam; fall back to the
    documented secondary bar: **behaviourally identical + headless harness
    (`/T`, `/D`) green**. The `/T` key-script path goes through this exact
    `dispatch`, so the existing CCDUMP comparison is the regression test.

---

### Apply order (suggested)
1. Add the `KB_*` equs + `KEYBIND*` macros near `cc.asm:84`.
2. Add the `keytab` block (§4) beside `fk_tbl` (`cc.asm:3597`).
3. Replace `dispatch:` body `cc.asm:234-289` with §3.
4. Build `FEAT_STD`, run the `/T` harness, diff CCDUMP against a pre-change
   baseline. Expect zero behavioural diff.
