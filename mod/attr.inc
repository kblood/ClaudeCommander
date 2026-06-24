; @feature ATTR
; @title   Ctrl-A edit file attributes
; @needs   INI
; @cost    355
;
; mod/attr.inc  --  FEAT_ATTR
; Ctrl-A edits the cursor file's DOS attributes (Read-only / Hidden / System /
; Archive).  Reads the current bits with INT 21h 4300h, runs a small key
; sub-loop where R/H/S/A toggle each flag, Enter applies them with 4301h and
; Esc cancels.  The status is shown on the command row; the four attribute
; letters appear in upper-case when set and as a dot when clear, so the result
; is visible in the /T harness and matches the Ctrl-F5 attribute column.

key_attr:
        mov     bx, [active]
        mov     cx, [bx+P_COUNT]
        jcxz    .bail
        call    cur_entry_ptr           ; si = cursor entry
        cmp     byte [si+E_NAME], '.'   ; skip "." / ".."
        je      .bail
        test    byte [si+E_ATTR], 10h   ; skip directories
        jnz     .bail
        call    build_entry_path        ; targpath = full 8.3 path
        mov     ax, 4300h               ; get attributes -> CX
        mov     dx, targpath
        int     21h
        jc      .bail
        and     cl, 27h                 ; keep R(01) H(02) S(04) A(20)
        mov     [attr_cur], cl
        jmp     .loop
.bail:
        ret
.loop:
        call    mouse_hide
        call    render_all
        call    attr_overlay
        call    mouse_show
        cmp     byte [test_mode], 0
        je      .live
        call    dump_screen
.live:
        call    get_key
        or      al, al
        jz      .ext
        cmp     al, 1Bh                 ; Esc -> cancel
        je      .ret
        cmp     al, 0Dh                 ; Enter -> apply
        je      .apply
        and     al, 0DFh                ; fold to upper-case
        cmp     al, 'R'
        je      .tR
        cmp     al, 'H'
        je      .tH
        cmp     al, 'S'
        je      .tS
        cmp     al, 'A'
        je      .tA
        jmp     .loop
.ext:
        cmp     ah, 44h                 ; F10 (harness exhaustion) -> leave
        je      .ret
        jmp     .loop
.tR:    xor     byte [attr_cur], 01h
        jmp     .loop
.tH:    xor     byte [attr_cur], 02h
        jmp     .loop
.tS:    xor     byte [attr_cur], 04h
        jmp     .loop
.tA:    xor     byte [attr_cur], 20h
        jmp     .loop
.apply:
        mov     ax, 4301h               ; set attributes
        xor     ch, ch
        mov     cl, [attr_cur]
        mov     dx, targpath
        int     21h
        mov     bx, [active]            ; refresh panel so the column updates
        call    read_dir
.ret:
        ret

; draw the editor status on the command row.  es=VIDEO set here.
attr_overlay:
        push    es
        mov     ax, VIDEO
        mov     es, ax
        mov     di, CMD_ROW*ROW_BYTES
        mov     ax, (A_CMD<<8)|' '      ; clear the row
        mov     cx, SCR_W
        rep     stosw
        mov     di, CMD_ROW*ROW_BYTES
        mov     si, s_attrlbl
        mov     ah, A_CMD
.l:     mov     al, [si]
        or      al, al
        jz      .flags
        mov     [es:di], al
        mov     [es:di+1], ah
        inc     si
        add     di, 2
        jmp     .l
.flags:
        mov     bl, [attr_cur]
        mov     al, 'R'
        test    bl, 01h
        call    attr_putflag
        mov     al, 'H'
        test    bl, 02h
        call    attr_putflag
        mov     al, 'S'
        test    bl, 04h
        call    attr_putflag
        mov     al, 'A'
        test    bl, 20h
        call    attr_putflag
        ; trailing hint
        mov     si, s_attrhint
.h:     mov     al, [si]
        or      al, al
        jz      .done
        mov     [es:di], al
        mov     byte [es:di+1], A_CMD
        inc     si
        add     di, 2
        jmp     .h
.done:
        pop     es
        ret

; put one flag letter at di: upper-case (al) if ZF=0 (bit set), else '.'  Adds a
; trailing space.  es=VIDEO, di advanced.  Preserves bl.
attr_putflag:
        jnz     .set
        mov     al, '.'
.set:
        mov     [es:di], al
        mov     byte [es:di+1], A_CMD
        add     di, 2
        mov     byte [es:di], ' '
        mov     byte [es:di+1], A_CMD
        add     di, 2
        ret

s_attrlbl   db 'Attributes: ',0
s_attrhint  db ' (R/H/S/A toggle, Enter apply, Esc cancel)',0
