; mod/ini.inc  --  FEAT_INI
; Minimal cc.ini reader, run once at startup before the panels are read.  Parses
; "key = value" lines (";", "#" and "[section]" lines ignored) and applies the
; recognised options to the panel state:
;     sort    = name | ext | size | date
;     columns = size | date | time | attr
; Unknown keys/values are ignored.  This is the backbone for persisted options;
; more keys can be added by extending the dispatch below.

ini_load:
        mov     word [open_n], 0
        mov     byte [cur_sect], 0
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
        je      .section
        ; inside an [open] section, every "ext = helper" line is a mapping
        cmp     byte [cur_sect], 1
        jne     .keys
        call    openmap_add
        jmp     .skip
.keys:
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
.section:
        push    si
        inc     si                  ; past '['
        mov     di, k_open
        call    sect_is             ; CF=1 if section name is "open"
        pop     si
        mov     byte [cur_sect], 0
        jc      .secopen
        jmp     .skip
.secopen:
        mov     byte [cur_sect], 1
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

; si -> char after '['. di = section name ASCIIZ. CF=1 if the bracketed name
; matches (case-insensitive) followed by ']'. si/di not preserved.
sect_is:
        push    si
.c:     mov     al, [di]
        or      al, al
        jz      .end
        mov     ah, [si]
        and     al, 0DFh
        and     ah, 0DFh
        cmp     al, ah
        jne     .no
        inc     si
        inc     di
        jmp     .c
.end:   cmp     byte [si], ']'
        jne     .no
        pop     ax                  ; discard saved si
        stc
        ret
.no:    pop     si
        clc
        ret

; si -> "ext = helper" line. Parse one [open] mapping into openmap.
openmap_add:
        mov     ax, [open_n]
        cmp     ax, OPENMAX
        jae     .done
        mov     bx, OPENROW
        mul     bx                  ; ax = open_n * OPENROW
        mov     bp, openmap
        add     bp, ax
        mov     byte [bp], 0        ; clear the 4-byte ext field
        mov     byte [bp+1], 0
        mov     byte [bp+2], 0
        mov     byte [bp+3], 0
        mov     di, bp              ; write cursor for the ext (max 3, upper)
        mov     cx, 3
.ext:
        mov     al, [si]
        or      al, al
        jz      .bad
        cmp     al, 0Dh
        je      .bad
        cmp     al, 0Ah
        je      .bad
        cmp     al, '='
        je      .exte
        cmp     al, ' '
        je      .exte
        cmp     al, 9
        je      .exte
        jcxz    .extn
        cmp     al, 'a'
        jb      .st
        cmp     al, 'z'
        ja      .st
        sub     al, 20h
.st:    mov     [di], al
        inc     di
        dec     cx
.extn:  inc     si
        jmp     .ext
.exte:
        ; skip spaces/tabs and the '='
.sk:    mov     al, [si]
        cmp     al, ' '
        je      .ska
        cmp     al, 9
        je      .ska
        cmp     al, '='
        je      .ska
        jmp     .hel
.ska:   inc     si
        jmp     .sk
.hel:
        lea     di, [bp+4]          ; helper field (max 13 + NUL)
        mov     cx, 13
.hl:    mov     al, [si]
        or      al, al
        jz      .hend
        cmp     al, 0Dh
        je      .hend
        cmp     al, 0Ah
        je      .hend
        cmp     al, ' '
        je      .hend
        jcxz    .hadv
        mov     [di], al
        inc     di
        dec     cx
.hadv:  inc     si
        jmp     .hl
.hend:
        mov     byte [di], 0
        cmp     byte [bp], 0        ; need a non-empty ext and helper
        je      .done
        cmp     byte [bp+4], 0
        je      .done
        inc     word [open_n]
.done:
        ret
.bad:
        ret

; si -> a filename ASCIIZ. If its extension is in openmap, CF=1 and di -> the
; helper name; otherwise CF=0. si preserved.
open_lookup:
        push    si
        xor     bx, bx              ; bx -> char after last '.', 0 if none
.fe:    mov     al, [si]
        or      al, al
        jz      .got
        cmp     al, '.'
        jne     .fn
        lea     bx, [si+1]
.fn:    inc     si
        jmp     .fe
.got:
        or      bx, bx
        jz      .no
        mov     si, bx              ; uppercase ext (max 3) into ext_tmp
        mov     di, ext_tmp
        mov     byte [di], 0
        mov     byte [di+1], 0
        mov     byte [di+2], 0
        mov     byte [di+3], 0
        mov     cx, 3
.uc:    mov     al, [si]
        or      al, al
        jz      .ucd
        jcxz    .ucd
        cmp     al, 'a'
        jb      .us
        cmp     al, 'z'
        ja      .us
        sub     al, 20h
.us:    mov     [di], al
        inc     di
        inc     si
        dec     cx
        jmp     .uc
.ucd:
        mov     cx, [open_n]
        jcxz    .no
        mov     bx, openmap
.row:
        mov     si, ext_tmp
        mov     di, bx
        mov     al, [si]
        cmp     al, [di]
        jne     .nx
        mov     al, [si+1]
        cmp     al, [di+1]
        jne     .nx
        mov     al, [si+2]
        cmp     al, [di+2]
        jne     .nx
        mov     al, [si+3]
        cmp     al, [di+3]
        jne     .nx
        lea     di, [bx+4]          ; match -> helper
        pop     si
        stc
        ret
.nx:    add     bx, OPENROW
        loop    .row
.no:
        pop     si
        clc
        ret

s_ininame   db 'cc.ini',0
k_sort      db 'sort',0
k_cols      db 'columns',0
k_open      db 'open',0
v_name      db 'name',0
v_ext       db 'ext',0
v_size      db 'size',0
v_date      db 'date',0
v_time      db 'time',0
v_attr      db 'attr',0
