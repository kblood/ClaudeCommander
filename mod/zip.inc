; mod/zip.inc  --  FEAT_ZIP
; Ctrl-F9 lists the contents of the archive under the cursor by launching the
; external CCZIP.COM (which parses the ZIP central directory) via run_command.
; CCZIP reports "not a ZIP" for non-archives, so it is safe on any file.

key_zip:
        mov     bx, [active]
        mov     cx, [bx+P_COUNT]
        jcxz    .ret
        call    cur_entry_ptr           ; -> si = entry ptr
        test    byte [si+E_ATTR], 10h
        jnz     .ret                    ; not a directory
        mov     di, cmdbuf
        mov     si, s_zippfx
        call    zip_catz
        mov     bx, [active]
        lea     si, [bx+P_PATH]
        call    zip_catz
        cmp     byte [di-1], '\'
        je      .noslash
        mov     byte [di], '\'
        inc     di
.noslash:
        call    cur_entry_ptr
        call    zip_catz
        mov     ax, di
        sub     ax, cmdbuf
        mov     [cmdlen], ax
        call    run_command
.ret:
        ret

zip_catz:
        mov     al, [si]
        or      al, al
        jz      .d
        mov     [di], al
        inc     si
        inc     di
        jmp     zip_catz
.d:     ret

s_zippfx    db 'CCZIP ',0
