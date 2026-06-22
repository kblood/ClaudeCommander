; mod/harness.inc  --  extracted from cc.asm (M1 module split, byte-identical)
; Plain implicit-text code only; no section/equ/macro (see plan/m1_split.md).

; ============================================================================
;  SNAPSHOT: copy the 4000-byte B800 text page to CCSNAP.BIN (for PNG render)
; ============================================================================
snap_vram:
        push    ds
        push    es
        mov     ax, cs              ; our segment (COM: cs=ds=ss=es)
        mov     es, ax
        mov     di, snapbuf
        mov     ax, VIDEO
        mov     ds, ax
        xor     si, si
        mov     cx, 2000            ; 4000 bytes = 2000 words
        rep     movsw
        pop     es
        pop     ds
        mov     ah, 3Ch
        xor     cx, cx
        mov     dx, snapname
        int     21h
        jc      .ret
        mov     bx, ax
        mov     ah, 40h
        mov     cx, 4000
        mov     dx, snapbuf
        int     21h
        mov     ah, 3Eh
        int     21h
.ret:
        ret

; ============================================================================
;  SELF-TEST (diagnostic): write panel counts + first names to dump
; ============================================================================
selftest:
        mov     bx, panelL
        mov     al, 'L'
        call    dbg_panel_line
        mov     bx, panelR
        mov     al, 'R'
        call    dbg_panel_line
        ret

; bx=panel, al=tag -> "<tag> count=NNN name=XXXX\r\n" to dump
dbg_panel_line:
        mov     di, linebuf
        mov     [di], al
        inc     di
        mov     byte [di], ' '
        inc     di
        mov     si, dbg_cnt
.c1:    mov al,[si]; or al,al; jz .c1e
        mov [di],al; inc di; inc si; jmp .c1
.c1e:
        push    bx
        mov     ax, [bx+P_COUNT]
        xor     dx, dx
        call    u32toa              ; si=numbuf, ends with NUL
.n1:    mov al,[si]; or al,al; jz .n1e
        mov [di],al; inc di; inc si; jmp .n1
.n1e:
        pop     bx
        mov     byte [di], ' '
        inc     di
        mov     cx, [bx+P_COUNT]
        jcxz    .noname
        mov     [ppanel], bx
        xor     ax, ax
        call    entry_ptr           ; si = entry0
        lea     si, [si+E_NAME]
.nm:    mov al,[si]; or al,al; jz .nme
        mov [di],al; inc di; inc si; jmp .nm
.nme:
.noname:
        mov     word [di], 0A0Dh
        add     di, 2
        mov     cx, di
        sub     cx, linebuf
        mov     dx, linebuf
        mov     bx, [dumph]
        mov     ah, 40h
        int     21h
        ret
