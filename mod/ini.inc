; @feature INI
; @title   cc.ini / cc.lng config parsing (needed by several below)
; @cost    2245
;
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
%ifdef FEAT_VIEW
        mov     word [view_n], 0
%endif
%ifdef FEAT_TOOLS_INI
        mov     word [utool_n], 0
        mov     word [ut_pp], utbuf     ; reset the label/program text cursor
%endif
        mov     byte [cur_sect], 0
        mov     ax, 3D00h
        mov     dx, s_ininame
        int     21h
        jc      .ret
        mov     bx, ax
        mov     ah, 3Fh
        mov     cx, VIEW_MAX-1      ; reuse the 12 KB F3/vfs scratch (startup-only,
        mov     dx, viewbuf         ; runs before any panel read or file view)
        int     21h
        jc      .close
        mov     [ini_n], ax
.close:
        mov     ah, 3Eh             ; close (bx still = handle)
        int     21h
        mov     bx, [ini_n]
        or      bx, bx
        jz      .ret
        mov     byte [viewbuf+bx], 0 ; NUL-terminate the text
        mov     si, viewbuf
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
        ; inside a map section ([open] / [view]) every "ext = helper" maps
        cmp     byte [cur_sect], 0
        je      .keys
%ifdef FEAT_TOOLS_INI
        cmp     byte [cur_sect], 3      ; [tools] uses "label = program" not "ext ="
        je      .dotools
%endif
        call    map_add
        jmp     .skip
%ifdef FEAT_TOOLS_INI
.dotools:
        call    tools_add
        jmp     .skip
%endif
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
%ifdef FEAT_CLOCK
        push    si
        mov     di, k_clock
        call    kw_match
        jc      .doclock
        pop     si
%endif
%ifdef FEAT_EDIT
        push    si
        mov     di, k_editor
        call    kw_match
        jc      .doeditor
        pop     si
%endif
        jmp     .skip
.dosort:
        add     sp, 2               ; keep the advanced si
        call    set_sort_val
        jmp     .skip
.docols:
        add     sp, 2
        call    set_cols_val
        jmp     .skip
%ifdef FEAT_CLOCK
.doclock:
        add     sp, 2
        call    set_clock_val
        jmp     .skip
%endif
%ifdef FEAT_EDIT
.doeditor:
        add     sp, 2
        call    set_editor_val
        jmp     .skip
%endif
.section:
        mov     byte [cur_sect], 0
        push    si
        inc     si                  ; past '['
        mov     di, k_open
        call    sect_is             ; CF=1 if section name is "open"
        pop     si
        jc      .secopen
%ifdef FEAT_VIEW
        push    si
        inc     si
        mov     di, k_view
        call    sect_is             ; CF=1 if section name is "view"
        pop     si
        jc      .secview
%endif
%ifdef FEAT_TOOLS_INI
        push    si
        inc     si
        mov     di, k_tools
        call    sect_is             ; CF=1 if section name is "tools"
        pop     si
        jc      .sectools
%endif
        jmp     .skip
.secopen:
        mov     byte [cur_sect], 1
        mov     word [cur_map_base], openmap
        mov     word [cur_map_n], open_n
        jmp     .skip
%ifdef FEAT_VIEW
.secview:
        mov     byte [cur_sect], 2
        mov     word [cur_map_base], viewmap
        mov     word [cur_map_n], view_n
        jmp     .skip
%endif
%ifdef FEAT_TOOLS_INI
.sectools:
        mov     byte [cur_sect], 3      ; lines now parse as "label = program"
        jmp     .skip
%endif
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

%ifdef FEAT_EDIT
; si -> value token -> copy into editor_name (max 15 chars, NUL-terminated),
; stopping at the first space / tab / CR / LF / NUL.
set_editor_val:
        mov     di, editor_name
        mov     cx, 15
.cp:
        mov     al, [si]
        or      al, al
        jz      .end
        cmp     al, ' '
        je      .end
        cmp     al, 9
        je      .end
        cmp     al, 0Dh
        je      .end
        cmp     al, 0Ah
        je      .end
        jcxz    .end
        mov     [di], al
        inc     di
        inc     si
        dec     cx
        jmp     .cp
.end:
        mov     byte [di], 0
        ret
%endif

%ifdef FEAT_CLOCK
set_clock_val:
        mov     di, v_cmdrow
        call    val_is
        jc      .c
        mov     di, v_topright
        call    val_is
        jc      .t
        mov     di, v_off
        call    val_is
        jc      .o
        ret
.c:     mov     byte [clock_pos], 0
        ret
.t:     mov     byte [clock_pos], 1
        ret
.o:     mov     byte [clock_pos], 2
        ret
%endif

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

; si -> "ext = helper" line. Parse one mapping into the current section's map
; (base [cur_map_base], count word at [cur_map_n]).
map_add:
        mov     bx, [cur_map_n]
        mov     ax, [bx]
        cmp     ax, OPENMAX
        jae     .done
        mov     bx, OPENROW
        mul     bx                  ; ax = count * OPENROW
        mov     bp, [cur_map_base]
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
        mov     bx, [cur_map_n]
        inc     word [bx]
.done:
        ret
.bad:
        ret

%ifdef FEAT_TOOLS_INI
; si -> "label = program ..." line in the [tools] section. Parse one entry:
;   label   = text left of '=' (trailing blanks trimmed) -> the menu row caption
;   program = the FIRST token right of '='               -> the .COM to EXEC
; trailing columns (key / contract / menu) from the doc format are ignored for
; now (the action contract: run "<program> <cursor-path>" like a built-in Tools
; item). Both strings are appended ASCIIZ to utbuf and their pointers recorded
; in utool_lbl/utool_cmd. Malformed/empty/overflowing lines are dropped whole.
tools_add:
        mov     ax, [utool_n]
        cmp     ax, UTOOL_MAX
        jae     .done
        mov     di, [ut_pp]             ; write cursor in utbuf
        mov     bx, di                  ; bx = label start (preserved throughout)
.lbl:
        mov     al, [si]
        or      al, al
        jz      .bad
        cmp     al, 0Dh
        je      .bad
        cmp     al, 0Ah
        je      .bad
        cmp     al, '='
        je      .lble
        cmp     di, utbuf+UTBUF_SZ-2
        jae     .bad
        mov     [di], al
        inc     di
        inc     si
        jmp     .lbl
.lble:
        ; trim trailing spaces/tabs from the label
.trim:
        cmp     di, bx
        jbe     .lblz
        cmp     byte [di-1], ' '
        je      .trimd
        cmp     byte [di-1], 9
        jne     .lblz
.trimd:
        dec     di
        jmp     .trim
.lblz:
        cmp     di, bx                  ; empty label -> reject
        je      .bad
        mov     byte [di], 0
        inc     di
        inc     si                      ; past '='
.sk:
        mov     al, [si]                ; skip blanks before the program token
        cmp     al, ' '
        je      .ska
        cmp     al, 9
        je      .ska
        jmp     .prog
.ska:
        inc     si
        jmp     .sk
.prog:
        mov     dx, di                  ; dx = program start
.pcp:
        mov     al, [si]
        or      al, al
        jz      .proge
        cmp     al, 0Dh
        je      .proge
        cmp     al, 0Ah
        je      .proge
        cmp     al, ' '
        je      .proge
        cmp     al, 9
        je      .proge
        cmp     di, utbuf+UTBUF_SZ-2
        jae     .bad
        mov     [di], al
        inc     di
        inc     si
        jmp     .pcp
.proge:
        cmp     di, dx                  ; empty program -> reject
        je      .bad
        mov     byte [di], 0
        inc     di
        mov     [ut_pp], di             ; commit the buffer cursor (success)
        mov     di, [utool_n]
        shl     di, 1
        mov     [utool_lbl+di], bx
        mov     [utool_cmd+di], dx
        mov     word [utool_key+di], 0  ; default: no hotkey
        ; --- optional 3rd column: a key name (e.g. Alt-F3) -> utool_key ---
.ksk:
        mov     al, [si]                ; skip blanks before the key token
        cmp     al, ' '
        je      .ksa
        cmp     al, 9
        je      .ksa
        jmp     .kchk
.ksa:
        inc     si
        jmp     .ksk
.kchk:
        or      al, al                  ; end of line -> no key
        jz      .krec
        cmp     al, 0Dh
        je      .krec
        cmp     al, 0Ah
        je      .krec
        cmp     al, '-'                 ; the doc's "-" placeholder = no hotkey
        je      .krec
        call    parse_key               ; si->token; CF=1 -> dl=class, dh=code
        jnc     .krec
        mov     di, [utool_n]
        shl     di, 1
        mov     al, dl
        mov     ah, dh
        mov     [utool_key+di], ax      ; lo=class, hi=code
.krec:
        inc     word [utool_n]
.done:
        ret
.bad:
        ret
%endif

; si -> a filename ASCIIZ. If its extension is in the [open] map, CF=1 and
; di -> the helper name; otherwise CF=0. si preserved.
open_lookup:
        mov     ax, [open_n]
        mov     [ml_cnt], ax
        mov     word [ml_base], openmap
        jmp     map_lookup
%ifdef FEAT_VIEW
; as open_lookup but against the [view] map.
view_lookup:
        mov     ax, [view_n]
        mov     [ml_cnt], ax
        mov     word [ml_base], viewmap
        jmp     map_lookup
%endif
; si -> filename. Looks up the extension in the map at [ml_base] (count
; [ml_cnt]); CF=1 + di -> helper on a hit, else CF=0. si preserved.
map_lookup:
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
        mov     cx, [ml_cnt]
        jcxz    .no
        mov     bx, [ml_base]
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
%ifdef FEAT_CLOCK
k_clock     db 'clock',0
%endif
%ifdef FEAT_EDIT
k_editor    db 'editor',0
%endif
k_open      db 'open',0
%ifdef FEAT_VIEW
k_view      db 'view',0
%endif
%ifdef FEAT_TOOLS_INI
k_tools     db 'tools',0
%endif
v_name      db 'name',0
v_ext       db 'ext',0
v_size      db 'size',0
v_date      db 'date',0
v_time      db 'time',0
v_attr      db 'attr',0
%ifdef FEAT_CLOCK
v_cmdrow    db 'cmdrow',0
v_topright  db 'topright',0
v_off       db 'off',0
%endif
