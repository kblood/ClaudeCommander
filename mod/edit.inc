; @feature EDIT
; @title   F4 launches the CCEDIT external editor
; @cost    115
;
; mod/edit.inc  --  FEAT_EDIT
; F4 launches an external editor on the current file.  Builds
; "<editor> <fullpath>" onto the command line and reuses run_command (the same
; COMSPEC /C EXEC path the command line uses), so cc stays small -- the editor
; is a separate Layer-3 binary shipped beside cc.com.  The editor name defaults
; to CCEDIT but is overridable from cc.ini ("editor = EDIT", "editor = CCHEXED",
; or any editor on the PATH); see set_editor_val in mod/ini.inc.

key_edit:
        mov     bx, [active]
        mov     cx, [bx+P_COUNT]
        jcxz    .ret
        call    cur_entry_ptr           ; -> si = entry ptr (name at si)
        test    byte [si+E_ATTR], 10h
        jnz     .ret                    ; don't "edit" a directory
        ; cmdbuf = "<editor> " + panelpath + "\" + name
        mov     di, cmdbuf
        mov     si, editor_name
        call    edit_catz
        mov     byte [di], ' '
        inc     di
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

; The editor command launched by F4. Default CCEDIT; cc.ini "editor =" rewrites
; this in place (set_editor_val caps it at 15 chars), so the buffer is sized for
; a name/short path, not the full command line.
editor_name db 'CCEDIT'
            times 16-6 db 0
