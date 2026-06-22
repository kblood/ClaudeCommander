; mod/shell.inc  --  extracted from cc.asm (M1 module split, byte-identical)
; Plain implicit-text code only; no section/equ/macro (see plan/m1_split.md).

run_command:
        ; switch to a clean text screen for the command's own output
        mov     ax, 0003h
        int     10h
        call    show_cursor
        ; show the command we are running
        mov     ah, 9
        mov     dx, s_runmsg
        int     21h
        call    get_comspec         ; -> comspec_buf
        call    build_tail          ; -> cmdtail (Pascal string)
        call    fill_epb
        call    run_exec            ; INT 21h 4Bh
        ; pause so output is readable, then rebuild UI
        mov     ah, 9
        mov     dx, s_anykey
        int     21h
        call    get_key
        mov     word [cmdlen], 0
        ; a command may have changed the filesystem -> re-read both panels
        mov     bx, panelL
        call    read_dir
        mov     bx, panelR
        call    read_dir
        mov     ax, 0003h           ; clear before redraw
        int     10h
        call    hide_cursor
        ret

; copy the COMSPEC value from the environment into comspec_buf (ASCIIZ)
get_comspec:
        push    es
        mov     ax, [2Ch]           ; PSP: environment segment
        mov     es, ax
        xor     di, di
.next:
        cmp     byte [es:di], 0
        je      .notfound           ; double-NUL -> end of environment
        mov     dx, di              ; remember string start
        mov     si, s_comspec
.cmp:
        mov     bl, [si]
        or      bl, bl
        jz      .found              ; matched whole "COMSPEC="
        mov     al, [es:di]
        cmp     al, bl
        jne     .nomatch
        inc     si
        inc     di
        jmp     .cmp
.nomatch:
        mov     di, dx
.skip:
        cmp     byte [es:di], 0
        je      .skipped
        inc     di
        jmp     .skip
.skipped:
        inc     di
        jmp     .next
.found:
        mov     si, comspec_buf
.cp:
        mov     al, [es:di]
        mov     [si], al
        inc     di
        inc     si
        or      al, al
        jnz     .cp
        pop     es
        ret
.notfound:
        mov     si, comspec_buf
        mov     di, s_defcom
.dc:
        mov     al, [di]
        mov     [si], al
        inc     di
        inc     si
        or      al, al
        jnz     .dc
        pop     es
        ret

; build the EXEC command tail (Pascal string) = " /C " + cmdbuf + CR
build_tail:
        mov     di, cmdtail+1
        mov     si, s_slashc
.s1:
        mov     al, [si]
        or      al, al
        jz      .s1e
        mov     [di], al
        inc     di
        inc     si
        jmp     .s1
.s1e:
        mov     si, cmdbuf
        mov     cx, [cmdlen]
        jcxz    .nb
.cb:
        mov     al, [si]
        mov     [di], al
        inc     di
        inc     si
        loop    .cb
.nb:
        mov     byte [di], 0Dh
        mov     ax, di
        sub     ax, cmdtail+1       ; tail length (excludes CR per spec? include text only)
        mov     [cmdtail], al
        ret

; fill the EXEC parameter block with our segment
fill_epb:
        mov     ax, ds
        mov     word [epb+0], 0     ; inherit environment
        mov     word [epb+2], cmdtail
        mov     [epb+4], ax
        mov     word [epb+6], 5Ch   ; default FCB #1 in PSP
        mov     [epb+8], ax
        mov     word [epb+10], 6Ch  ; default FCB #2 in PSP
        mov     [epb+12], ax
        ret

; perform the EXEC; ds:dx=program path, es:bx=param block
run_exec:
        mov     [save_sp], sp
        mov     [save_ss], ss
        push    ds
        pop     es                  ; es = our segment (param block lives here)
        mov     dx, comspec_buf
        mov     bx, epb
        mov     ax, 4B00h
        int     21h
        cli
        mov     ss, [save_ss]
        mov     sp, [save_sp]
        sti
        push    ds
        pop     es
        ; restore our DTA
        mov     ah, 1Ah
        mov     dx, dta_buf
        int     21h
        ret

