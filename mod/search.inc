; mod/search.inc  --  FEAT_SEARCH
; Norton-style incremental quick-search.  Bound to Ctrl-F6.  Runs its own
; key sub-loop (sharing get_key, so the /T harness drives it too): printable
; chars extend the search prefix and jump the cursor to the first matching
; entry in the active panel; Backspace shortens it; Esc / Enter / any nav key
; ends the search.  State (qsbuf/qslen) lives in cc.asm's .bss under FEAT_SEARCH.

key_qsearch:
        mov     word [qslen], 0
.loop:
        call    mouse_hide
        call    render_all
        call    qs_overlay              ; draw "Search: <prefix>_" on the cmd row
        call    mouse_show
        cmp     byte [test_mode], 0
        je      .live
        call    dump_screen
.live:
        call    get_key
        cmp     al, 08h                 ; Backspace
        je      .bksp
        cmp     al, 20h                 ; control char / al==0 extended -> exit
        jb      .done
        cmp     al, 7Eh                 ; above printable -> exit
        ja      .done
        ; printable: append to the prefix (cap at 14)
        mov     bx, [qslen]
        cmp     bx, 14
        jae     .loop
        mov     [qsbuf+bx], al
        inc     word [qslen]
        call    qs_find
        jmp     .loop
.bksp:
        cmp     word [qslen], 0
        je      .loop
        dec     word [qslen]
        call    qs_find
        jmp     .loop
.done:
        ret

; Find the first entry in the active panel whose name starts with qsbuf
; (case-insensitive); move the cursor there.  No match / empty prefix -> leave
; the cursor where it is.
qs_find:
        cmp     word [qslen], 0
        je      .ret
        mov     ax, [active]
        mov     [ppanel], ax            ; entry_ptr reads [ppanel]
        mov     bx, ax
        mov     dx, [bx+P_COUNT]
        xor     bp, bp                  ; entry index
.scan:
        cmp     bp, dx
        jae     .ret                    ; ran off the end -> no match
        push    dx
        push    bp
        mov     ax, bp
        call    entry_ptr               ; -> si = entry ptr (name at si+E_NAME=0)
        mov     di, qsbuf
        mov     cx, [qslen]
.cmp:
        mov     al, [si]
        and     al, 0DFh                ; rough uppercase (same map both sides)
        mov     ah, [di]
        and     ah, 0DFh
        cmp     al, ah
        jne     .miss
        inc     si
        inc     di
        loop    .cmp
        ; full prefix matched -> land the cursor here
        pop     bp
        pop     dx
        mov     bx, [active]
        mov     [bx+P_CUR], bp
        call    fix_scroll
        ret
.miss:
        pop     bp
        pop     dx
        inc     bp
        jmp     .scan
.ret:
        ret

; Draw "Search: <prefix>_" at the left of the command row (es=VIDEO set here).
qs_overlay:
        push    es
        mov     ax, VIDEO
        mov     es, ax
        mov     di, CMD_ROW*ROW_BYTES   ; col 0 (fully cover the C:\> prompt)
        mov     ah, 0Fh                 ; bright white on black
        mov     si, txt_search
.tl:
        lodsb
        or      al, al
        jz      .pre
        mov     [es:di], al
        mov     [es:di+1], ah
        add     di, 2
        jmp     .tl
.pre:
        mov     cx, [qslen]
        mov     si, qsbuf
.bl:
        jcxz    .cur
        lodsb
        mov     [es:di], al
        mov     [es:di+1], ah
        add     di, 2
        dec     cx
        jmp     .bl
.cur:
        mov     byte [es:di], '_'       ; caret
        mov     [es:di+1], ah
        pop     es
        ret

txt_search  db 'Search: ',0
