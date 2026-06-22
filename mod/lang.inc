; mod/lang.inc  --  FEAT_LANG
; Optional UI translation.  If cc.lng exists, its first 10 lines replace the
; ten function-key bar labels (fk_tbl entries) -- the most visible UI text.
; Loaded once at startup; missing file -> English defaults are kept.  The
; labels are repointed in place into a loaded buffer, so draw_fkeys needs no
; changes.  A sample da.lng ships alongside; copy it to cc.lng to use it.

lang_load:
        mov     ax, 3D00h
        mov     dx, s_lngname
        int     21h
        jc      .ret
        mov     bx, ax
        mov     ah, 3Fh
        mov     cx, LNGMAX-1
        mov     dx, lngbuf
        int     21h
        jc      .close
        mov     [lng_n], ax
.close:
        mov     ah, 3Eh
        int     21h
        mov     bx, [lng_n]
        or      bx, bx
        jz      .ret
        mov     byte [lngbuf+bx], 0
        ; repoint fk_tbl[0..9] to successive lines
        mov     si, lngbuf
        xor     cx, cx
.line:
        cmp     cx, 10
        jae     .ret
        cmp     byte [si], 0
        je      .ret
        mov     bx, cx
        shl     bx, 1
        mov     [fk_tbl+bx], si         ; label cx now points at this line
.eol:
        mov     al, [si]
        or      al, al
        jz      .ret                    ; last line, no terminator
        cmp     al, 0Dh
        je      .term
        cmp     al, 0Ah
        je      .term
        inc     si
        jmp     .eol
.term:
        mov     byte [si], 0            ; terminate this label in place
        inc     si
        cmp     byte [si], 0Ah          ; step over LF of a CRLF pair
        jne     .nextline
        inc     si
.nextline:
        inc     cx
        jmp     .line
.ret:
        ret

s_lngname   db 'cc.lng',0
