; mod/find.inc  --  FEAT_FIND
; Alt-F7 finds files by name across the active panel's directory tree.  Prompts
; for a pattern, then launches the external CCFIND.COM (which walks the tree and
; lists matches) via the run_command EXEC path -- so cc stays small and the
; heavy recursion lives in a separate Layer-3 binary.

key_find:
        mov     si, s_findprompt
        call    dlg_input               ; -> dlgbuf, CF=1 if cancelled
        jc      .ret
        cmp     byte [dlgbuf], 0
        je      .ret
        ; cmdbuf = "CCFIND " + pattern + " " + panelpath
        mov     di, cmdbuf
        mov     si, s_findpfx
        call    find_catz
        mov     si, dlgbuf
        call    find_catz
        mov     byte [di], ' '
        inc     di
        mov     bx, [active]
        lea     si, [bx+P_PATH]
        call    find_catz
        mov     ax, di
        sub     ax, cmdbuf
        mov     [cmdlen], ax
        call    run_command
.ret:
        ret

; append ASCIIZ ds:si at [di] (no terminator); di advanced.
find_catz:
        mov     al, [si]
        or      al, al
        jz      .d
        mov     [di], al
        inc     si
        inc     di
        jmp     find_catz
.d:     ret

s_findpfx       db 'CCFIND ',0
s_findprompt    db 'Find files (name pattern, e.g. *.TXT):',0
