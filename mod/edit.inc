; mod/edit.inc  --  FEAT_EDIT
; F4 launches the external editor CCEDIT.COM on the current file.  Builds
; "CCEDIT <fullpath>" onto the command line and reuses run_command (the same
; COMSPEC /C EXEC path the command line uses), so cc stays small -- the editor
; is a separate Layer-3 binary shipped beside cc.com.

key_edit:
        mov     bx, [active]
        mov     cx, [bx+P_COUNT]
        jcxz    .ret
        call    cur_entry_ptr           ; -> si = entry ptr (name at si)
        test    byte [si+E_ATTR], 10h
        jnz     .ret                    ; don't "edit" a directory
        ; cmdbuf = "CCEDIT " + panelpath + "\" + name
        mov     di, cmdbuf
        mov     si, s_editpfx
        call    edit_catz
        mov     bx, [active]
        lea     si, [bx+P_PATH]
        call    edit_catz
        cmp     byte [di-1], '\'        ; path already ends in '\' (root)?
        je      .noslash
        mov     byte [di], '\'
        inc     di
.noslash:
        call    cur_entry_ptr           ; si -> name again
        call    edit_catz
        mov     ax, di
        sub     ax, cmdbuf
        mov     [cmdlen], ax
        call    run_command
.ret:
        ret

; append ASCIIZ ds:si at [di] (no terminator); di advanced.
edit_catz:
        mov     al, [si]
        or      al, al
        jz      .d
        mov     [di], al
        inc     si
        inc     di
        jmp     edit_catz
.d:     ret

s_editpfx   db 'CCEDIT ',0
