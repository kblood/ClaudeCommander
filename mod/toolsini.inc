; @feature TOOLS_INI
; @title   cc.ini [tools] registry: drop-in helpers become Tools-menu rows + keys
; @needs   TOOLS INI
; @cost    320
;
; mod/toolsini.inc  --  FEAT_TOOLS_INI
; The opt-in runtime half of the [tools] registry (architecture doc S8.7): a
; user lists "label = program [key]" lines under [tools] in cc.ini and each one
; shows up as a new row on the Tools pull-down AND (if a key is named) claims a
; live hotkey -- no rebuild, no code change. That is the full "drop a .COM, get a
; feature" loop: both the menu surface and the keytab.
;
; ini.inc's parser (tools_add) fills utool_lbl[]/utool_cmd[]/utool_key[] at
; startup. Here we (1) splice the user rows onto the END of the static built-in
; Tools menu into a runtime table (tools_menu_rt) the menu bar points at, and
; (2) register each named hotkey into a small runtime keytab (ukeytab) that the
; main dispatcher consults after the static keytab misses -- conflicts with a
; built-in binding are rejected so a dropped-in tool can never shadow a core key.
; Both the menu pick and the hotkey funnel into exec_user_tool, which EXECs
; "<program> <cursor-path>" through the built-in Tools path (tools_exec ->
; run_command): the "action" contract, same as the built-in CCSUM/CCDIFF items.

; Build tools_menu_rt = the static mb_tools rows (copied verbatim) followed by
; one {label, run_user_tool} row per cc.ini [tools] entry, 0-terminated; then
; register the named hotkeys. Records how many built-in rows lead, so the menu
; handler can map a selection index back to its utool slot. Runs once at startup.
build_tools_menu:
        mov     si, mb_tools            ; the static built-in template
        mov     di, tools_menu_rt
        xor     cx, cx                  ; built-in row count
.copy:
        mov     ax, [si]                ; label ptr (0 terminates the template)
        or      ax, ax
        jz      .copied
        mov     [di], ax
        mov     ax, [si+2]              ; handler ptr
        mov     [di+2], ax
        add     si, 4
        add     di, 4
        inc     cx
        jmp     .copy
.copied:
        mov     [tools_builtin_n], cx
        mov     cx, [utool_n]
        jcxz    .term
        xor     bx, bx                  ; word index into utool_lbl (i*2)
.urow:
        mov     ax, [utool_lbl+bx]
        mov     [di], ax
        mov     word [di+2], run_user_tool
        add     di, 4
        add     bx, 2
        loop    .urow
.term:
        mov     word [di], 0            ; terminate the runtime menu
        ; fall through to hotkey registration

; Register every utool that carries a parsed hotkey (utool_key != 0) into
; ukeytab, skipping any whose (class,code) already belongs to a built-in or an
; earlier user tool. ukeytab rows are keytab-shaped: db class, db code, dw index.
register_user_hotkeys:
        mov     word [ukey_n], 0
        xor     si, si                  ; si = utool index i
.loop:
        cmp     si, [utool_n]
        jae     .done
        mov     bx, si
        shl     bx, 1
        mov     ax, [utool_key+bx]      ; lo=class, hi=code (0 = none)
        or      ax, ax
        jz      .next
        mov     dl, al                  ; class
        mov     dh, ah                  ; code
        push    si
        call    keybind_taken           ; CF=1 if (dl,dh) already bound
        pop     si
        jc      .next
        mov     di, [ukey_n]
        shl     di, 2                   ; *4
        add     di, ukeytab
        mov     [di], dl                ; class
        mov     [di+1], dh              ; code
        mov     [di+2], si              ; utool index
        inc     word [ukey_n]
.next:
        inc     si
        jmp     .loop
.done:
        ret

; dl=class, dh=code. CF=1 if that key is already bound by the static keytab or
; an already-registered ukeytab row; else CF=0. Preserves dl/dh; clobbers al/si/cx.
keybind_taken:
        mov     si, keytab
.s:
        mov     al, [si]
        cmp     al, KB_END
        je      .dyn
        cmp     al, dl
        jne     .sx
        mov     al, [si+1]
        cmp     al, dh
        je      .yes
.sx:
        add     si, 4
        jmp     .s
.dyn:
        mov     cx, [ukey_n]
        jcxz    .no
        mov     si, ukeytab
.d:
        mov     al, [si]
        cmp     al, dl
        jne     .dx
        mov     al, [si+1]
        cmp     al, dh
        je      .yes
.dx:
        add     si, 4
        loop    .d
.no:
        clc
        ret
.yes:
        stc
        ret

; Main-dispatch hook (called from dispatch:.nomatch). dl=class, dh=code of the
; unbound key. If a registered user hotkey matches, run its tool and return CF=1;
; otherwise CF=0 with al/ah preserved for the ascii-fallthrough.
ukey_dispatch:
        push    ax
        mov     cx, [ukey_n]
        jcxz    .no
        mov     si, ukeytab
.scan:
        mov     al, [si]                ; class
        cmp     al, dl
        jne     .nx
        mov     al, [si+1]              ; code
        cmp     al, dh
        je      .hit
.nx:
        add     si, 4
        loop    .scan
.no:
        pop     ax
        clc
        ret
.hit:
        add     sp, 2                   ; discard saved ax -- we're running the tool
        mov     ax, [si+2]              ; utool index
        call    exec_user_tool
        stc
        ret

; Menu handler shared by every cc.ini [tools] row. The menu bar leaves [mb_sel] =
; the picked row's absolute index in tools_menu_rt; subtract the built-in lead
; count to recover the utool slot, then run it.
run_user_tool:
        mov     ax, [mb_sel]
        sub     ax, [tools_builtin_n]
        js      .ret                    ; defensive: a built-in row shouldn't land here
        jmp     exec_user_tool
.ret:
        ret

; AX = utool slot index. Build and EXEC "<program> <cursor-path>" via the same
; path the built-in Tools items use (tools_exec -> run_command). NOTE: build the
; cursor path FIRST -- tools_cur_path clobbers di, so the program/path must be
; copied into cmdbuf only AFTER it (exactly the order key_tools_sum uses).
exec_user_tool:
        cmp     ax, [utool_n]
        jae     .ret
        shl     ax, 1
        mov     bx, ax
        mov     si, [utool_cmd+bx]      ; program name (ASCIIZ)
        push    si                      ; ...preserve it across tools_cur_path
        call    tools_cur_path          ; targpath = cursor file; CF=1 if none/dir
        pop     si
        mov     di, cmdbuf
        jc      .bare                   ; no usable cursor -> run the program bare
        call    bp_copy_name            ; program (di left AT its NUL)
        mov     byte [di], ' '          ; overwrite NUL with the separator
        inc     di
        mov     si, targpath
        call    bp_copy_name
        jmp     tools_exec              ; sets cmdlen, tail-calls run_command, ret
.bare:
        call    bp_copy_name
        jmp     tools_exec
.ret:
        ret

; --- key-name parsing -------------------------------------------------------
; si -> a key-name token (terminated by space/tab/CR/LF/NUL). On a recognised
; name returns CF=1 with dl=class (KB_EXT/KB_ASC) and dh=scan/ascii code; else
; CF=0. Recognises [Alt-|Ctrl-|Shift-]Fn (n=1..10) and Ctrl-<letter>; the
; modifier and the 'F' are case-insensitive. si may be advanced either way.
parse_key:
        push    bx
        push    cx
        xor     ch, ch                  ; modifier: 0 none, 1 alt, 2 ctrl, 3 shift
        mov     di, pk_alt
        call    pk_pfx
        jnc     .ntalt
        mov     ch, 1
        jmp     .havemod
.ntalt:
        mov     di, pk_ctrl
        call    pk_pfx
        jnc     .ntctrl
        mov     ch, 2
        jmp     .havemod
.ntctrl:
        mov     di, pk_shift
        call    pk_pfx
        jnc     .havemod                ; ch stays 0 (no modifier)
        mov     ch, 3
.havemod:
        mov     al, [si]
        and     al, 0DFh
        cmp     al, 'F'                 ; function key?
        jne     .ctl
        inc     si
        mov     al, [si]
        cmp     al, '0'
        jb      .fail
        cmp     al, '9'
        ja      .fail
        sub     al, '0'
        mov     cl, al                  ; cl = first digit
        inc     si
        mov     al, [si]
        cmp     al, '0'
        jb      .fnum
        cmp     al, '9'
        ja      .fnum
        sub     al, '0'                 ; two-digit: n = first*10 + second
        push    ax
        mov     al, cl
        mov     bl, 10
        mul     bl
        mov     cl, al
        pop     ax
        add     cl, al
        inc     si
.fnum:
        cmp     cl, 1                   ; only F1..F10
        jb      .fail
        cmp     cl, 10
        ja      .fail
        mov     al, 3Bh                 ; base: plain F1 = 0x3B
        cmp     ch, 1
        jne     .nbA
        mov     al, 68h                 ; Alt-F1  = 0x68
.nbA:
        cmp     ch, 2
        jne     .nbC
        mov     al, 5Eh                 ; Ctrl-F1 = 0x5E
.nbC:
        cmp     ch, 3
        jne     .nbS
        mov     al, 54h                 ; Shift-F1 = 0x54
.nbS:
        add     al, cl
        dec     al                      ; base + (n-1)
        mov     dh, al                  ; code
        xor     dl, dl                  ; KB_EXT
        jmp     .ok
.ctl:
        cmp     ch, 2                   ; only Ctrl-<letter> for the non-Fn case
        jne     .fail
        mov     al, [si]
        and     al, 0DFh
        cmp     al, 'A'
        jb      .fail
        cmp     al, 'Z'
        ja      .fail
        sub     al, 'A'-1               ; Ctrl-A = 1
        mov     dh, al
        mov     dl, 1                   ; KB_ASC
        jmp     .ok
.fail:
        pop     cx
        pop     bx
        clc
        ret
.ok:
        pop     cx
        pop     bx
        stc
        ret

; di -> ASCIIZ modifier word ("ALT"/"CTRL"/"SHIFT"). If si matches it
; (case-insensitive) immediately followed by '-', advance si past word+'-' and
; return CF=1; else leave si unchanged and return CF=0. Clobbers al/ah/di.
pk_pfx:
        push    si
.c:
        mov     al, [di]
        or      al, al
        jz      .end
        mov     ah, [si]
        and     al, 0DFh
        and     ah, 0DFh
        cmp     al, ah
        jne     .no
        inc     si
        inc     di
        jmp     .c
.end:
        cmp     byte [si], '-'
        jne     .no
        inc     si
        add     sp, 2                   ; commit the advanced si
        stc
        ret
.no:
        pop     si
        clc
        ret

pk_alt      db 'ALT',0
pk_ctrl     db 'CTRL',0
pk_shift    db 'SHIFT',0
