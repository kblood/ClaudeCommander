; mod/ini.inc  --  FEAT_INI
; Minimal cc.ini reader, run once at startup before the panels are read.  Parses
; "key = value" lines (";", "#" and "[section]" lines ignored) and applies the
; recognised options to the panel state:
;     sort    = name | ext | size | date
;     columns = size | date | time | attr
; Unknown keys/values are ignored.  This is the backbone for persisted options;
; more keys can be added by extending the dispatch below.

ini_load:
        mov     ax, 3D00h
        mov     dx, s_ininame
        int     21h
        jc      .ret
        mov     bx, ax
        mov     ah, 3Fh
        mov     cx, INIMAX-1
        mov     dx, inibuf
        int     21h
        jc      .close
        mov     [ini_n], ax
.close:
        mov     ah, 3Eh             ; close (bx still = handle)
        int     21h
        mov     bx, [ini_n]
        or      bx, bx
        jz      .ret
        mov     byte [inibuf+bx], 0 ; NUL-terminate the text
        mov     si, inibuf
.line:
        ; skip leading blanks
.lead:
        mov     al, [si]
        cmp     al, ' '
        je      .adv
        cmp     al, 9
        jne     .first
.adv:
        inc     si
        jmp     .lead
.first:
        or      al, al
        jz      .done
        cmp     al, 0Dh
        je      .eol
        cmp     al, 0Ah
        je      .eol
        cmp     al, ';'
        je      .skip
        cmp     al, '#'
        je      .skip
        cmp     al, '['
        je      .skip
        ; try recognised keys
        push    si
        mov     di, k_sort
        call    kw_match
        jc      .dosort
        pop     si
        push    si
        mov     di, k_cols
        call    kw_match
        jc      .docols
        pop     si
        jmp     .skip
.dosort:
        add     sp, 2               ; keep the advanced si
        call    set_sort_val
        jmp     .skip
.docols:
        add     sp, 2
        call    set_cols_val
        jmp     .skip
.skip:
        mov     al, [si]
        or      al, al
        jz      .done
        cmp     al, 0Ah
        je      .eol
        inc     si
        jmp     .skip
.eol:
        inc     si
        jmp     .line
.done:
.ret:
        ret

; kw_match: di=keyword ASCIIZ, si=text.  On a case-insensitive match of
; "<keyword> [spaces] = [spaces]", returns CF=1 with si at the value; else CF=0.
kw_match:
.cmp:
        mov     al, [di]
        or      al, al
        jz      .kwend
        mov     ah, [si]
        mov     cl, al
        and     cl, 0DFh
        mov     ch, ah
        and     ch, 0DFh
        cmp     cl, ch
        jne     .no
        inc     si
        inc     di
        jmp     .cmp
.kwend:
.sp1:
        cmp     byte [si], ' '
        jne     .eq
        inc     si
        jmp     .sp1
.eq:
        cmp     byte [si], '='
        jne     .no
        inc     si
.sp2:
        cmp     byte [si], ' '
        jne     .ok
        inc     si
        jmp     .sp2
.ok:
        stc
        ret
.no:
        clc
        ret

; val_is: di=keyword, si=value.  CF=1 if the value token equals keyword
; (case-insensitive, terminated by space/CR/LF/tab/NUL).  si preserved.
val_is:
        push    si
.cmp:
        mov     al, [di]
        or      al, al
        jz      .end
        mov     ah, [si]
        mov     cl, al
        and     cl, 0DFh
        mov     ch, ah
        and     ch, 0DFh
        cmp     cl, ch
        jne     .no
        inc     si
        inc     di
        jmp     .cmp
.end:
        mov     al, [si]
        cmp     al, ' '
        je      .ok
        cmp     al, 0Dh
        je      .ok
        cmp     al, 0Ah
        je      .ok
        cmp     al, 9
        je      .ok
        or      al, al
        jz      .ok
.no:
        pop     si
        clc
        ret
.ok:
        pop     si
        stc
        ret

set_sort_val:
        mov     di, v_name
        call    val_is
        jc      .n
        mov     di, v_ext
        call    val_is
        jc      .e
        mov     di, v_size
        call    val_is
        jc      .s
        mov     di, v_date
        call    val_is
        jc      .d
        ret
.n:     mov     byte [sort_mode], 0
        ret
.e:     mov     byte [sort_mode], 1
        ret
.s:     mov     byte [sort_mode], 2
        ret
.d:     mov     byte [sort_mode], 3
        ret

set_cols_val:
        mov     di, v_size
        call    val_is
        jc      .s
        mov     di, v_date
        call    val_is
        jc      .d
        mov     di, v_time
        call    val_is
        jc      .t
        mov     di, v_attr
        call    val_is
        jc      .a
        ret
.s:     mov     byte [col_mode], 0
        ret
.d:     mov     byte [col_mode], 1
        ret
.t:     mov     byte [col_mode], 2
        ret
.a:     mov     byte [col_mode], 3
        ret

s_ininame   db 'cc.ini',0
k_sort      db 'sort',0
k_cols      db 'columns',0
v_name      db 'name',0
v_ext       db 'ext',0
v_size      db 'size',0
v_date      db 'date',0
v_time      db 'time',0
v_attr      db 'attr',0
