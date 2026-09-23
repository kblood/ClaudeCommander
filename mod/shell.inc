; @core (always compiled in; not a selectable feature)
;
; mod/shell.inc  --  extracted from cc.asm (M1 module split, byte-identical)
; Plain implicit-text code only; no section/equ/macro (see plan/m1_split.md).

; Run an external helper silently: COMSPEC /C <cmdbuf>, with its stdout meant
; to be redirected to a file.  Unlike run_command this does NOT clear the
; screen, wait for a key, or re-read the panels -- so it is safe to call from
; inside a handler (e.g. the container browser) and from the /T harness without
; consuming keystrokes or recursing through a virtual panel's read_dir.
run_helper:
        call    get_comspec
        call    build_tail
        jc      .ret                ; command too long for a DOS tail -> don't run
        call    fill_epb
        call    run_exec
.ret:   ret

; Typed commands and Tools items: run cmdbuf in the ACTIVE panel's directory.
run_in_panel:
        mov     byte [run_here], 1
; Everything else (F4 editor, viewers, CCZIP ...): run in cc's own directory,
; where the helpers have always been found.
run_command:
        ; switch to a clean text screen for the command's own output
        mov     ax, 0003h
        int     10h
        call    show_cursor
        ; show the command we are running
        mov     ah, 9
        mov     dx, s_runmsg
        int     21h
        ; save cc's own drive/dir and return to it afterwards (helper lookup,
        ; CCDUMP/FINDOUT and cc.hlp are relative to it)
        mov     ah, 19h
        int     21h
        push    ax                  ; al = cc's current drive
        mov     byte [srchbuf], '\'
        mov     si, srchbuf+1
        xor     dl, dl
        mov     ah, 47h             ; "\" + cwd of the current drive
        int     21h
        shr     byte [run_here], 1  ; CF = run_in_panel entry (flag cleared)
        jnc     .home
        call    set_active_cwd
.home:
        call    get_comspec         ; -> comspec_buf
        call    build_tail          ; -> cmdtail (Pascal string)
        mov     dx, s_toolong
        jc      .msg                ; too long for a DOS command tail
        call    fill_epb
        call    run_exec            ; INT 21h 4Bh
        mov     dx, s_anykey
.msg:
        pop     ax
        push    dx
        mov     dl, al
        mov     ah, 0Eh             ; back to cc's drive...
        int     21h
        mov     dx, srchbuf
        mov     ah, 3Bh             ; ...and directory
        int     21h
        pop     dx
        ; pause so output is readable, then rebuild UI
        mov     ah, 9
        int     21h
        call    get_key
        mov     byte [mouse_vis], 0 ; the program may have reset the mouse
                                    ; driver (cursor hidden): let mouse_show re-show
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

; build the EXEC command tail (Pascal string) = " /C " + cmdbuf + CR.
; CF=1 (nothing built) if it would not fit: DOS allows 126 chars + CR, and
; cmdtail is 132 bytes with comspec_buf right behind it. vfs/viewer builders
; can make up to ~175-char commands.
CMD_MAX     equ 122             ; 126 - len(" /C ")
build_tail:
        cmp     word [cmdlen], CMD_MAX+1
        cmc
        jc      .ret                ; cmdlen > CMD_MAX -> refuse
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
        sub     ax, cmdtail+1       ; tail length (text only, CR excluded); CF=0
        mov     [cmdtail], al
.ret:   ret

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
        mov     fs, [xseg]          ; the child may have clobbered FS (xseg ptr)
        ; restore our DTA
        mov     ah, 1Ah
        mov     dx, dta_buf
        int     21h
        ret

