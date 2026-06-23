; ============================================================================
;  CCREN.COM  --  Claude Commander's wildcard multi-rename (Layer 3)
;
;  Usage:  CCREN <srcmask> <dstmask>
;          Renames every file matching <srcmask> in the current directory to a
;          name built from <dstmask> using classic DOS mask rules (per 8.3
;          field: '*' copies the rest of the source field, '?' copies one
;          source char, any other char is a literal). e.g.
;             CCREN *.TXT *.BAK        photo?.* -> img?.*
;          Matches are collected first, then renamed, so the enumeration is not
;          disturbed.
;
;  Assemble:  nasm -f bin cren.asm -o ccren.com
; ============================================================================
        org     100h
MAXN    equ 128

start:
        cld
        mov     sp, stacktop
        call    parse_two
        cmp     byte [arg1], 0
        je      .usage
        cmp     byte [arg2], 0
        je      .usage
        ; split the destination mask once
        mov     si, arg2
        mov     di, dname
        mov     bp, dext
        call    split
        jc      .hasdot
        mov     byte [dst_hasdot], 0
        jmp     .dsplit_done
.hasdot:
        mov     byte [dst_hasdot], 1
.dsplit_done:
        ; set DTA to our buffer
        mov     ah, 1Ah
        mov     dx, dta
        int     21h
        mov     word [ncount], 0
        mov     ah, 4Eh
        xor     cx, cx              ; normal files
        mov     dx, arg1
        int     21h
        jc      .nomatch
.collect:
        mov     ax, [ncount]
        cmp     ax, MAXN
        jae     .renall
        mov     bx, 13
        mul     bx                  ; ax = ncount*13
        mov     di, names
        add     di, ax
        mov     si, dta+30
.cpn:
        mov     al, [si]
        mov     [di], al
        or      al, al
        jz      .cpn_done
        inc     si
        inc     di
        jmp     .cpn
.cpn_done:
        inc     word [ncount]
        mov     ah, 4Fh
        int     21h
        jnc     .collect
.renall:
        cmp     word [ncount], 0
        je      .nomatch
        mov     word [idx], 0
        mov     word [okcount], 0
.rl:
        mov     ax, [idx]
        cmp     ax, [ncount]
        jae     .report
        mov     bx, 13
        mul     bx
        mov     si, names
        add     si, ax
        mov     [curname], si
        ; split source matched name
        mov     di, sname
        mov     bp, sext
        call    split
        ; build the new name from dstmask
        call    build_new
        ; rename curname -> newname
        mov     dx, [curname]
        mov     di, newname
        mov     ax, 5600h
        int     21h
        pushf
        ; print "old -> new" (note failures)
        mov     di, linebuf
        mov     si, [curname]
        call    cat
        mov     si, s_arrow
        call    cat
        mov     si, newname
        call    cat
        popf
        jnc     .ok
        mov     si, s_failed
        call    cat
        jmp     .pr
.ok:
        inc     word [okcount]
.pr:
        call    emit_line
        inc     word [idx]
        jmp     .rl
.report:
        mov     di, linebuf
        mov     si, s_renamed
        call    cat
        mov     ax, [okcount]
        xor     dx, dx
        call    put_dec32
        mov     si, s_files
        call    cat
        call    emit_line
        mov     ax, 4C00h
        int     21h
.nomatch:
        mov     dx, s_nomatch
        call    puts
        mov     ax, 4C00h
        int     21h
.usage:
        mov     dx, s_usage
        call    puts
        mov     ax, 4C01h
        int     21h

; ----------------------------------------------------------------------------
; split: si=source asciz; di=name buffer; bp=ext buffer.
; Fills both (NUL-terminated, name<=8, ext<=3). CF=1 if a '.' was present.
split:
        mov     cx, 8
.nm:
        mov     al, [si]
        or      al, al
        jz      .nodot
        cmp     al, '.'
        je      .dot
        jcxz    .nm_adv
        mov     [di], al
        inc     di
        dec     cx
.nm_adv:
        inc     si
        jmp     .nm
.dot:
        mov     byte [di], 0
        inc     si                  ; past '.'
        mov     di, bp
        mov     cx, 3
.ex:
        mov     al, [si]
        or      al, al
        jz      .ex_done
        jcxz    .ex_adv
        mov     [di], al
        inc     di
        dec     cx
.ex_adv:
        inc     si
        jmp     .ex
.ex_done:
        mov     byte [di], 0
        stc
        ret
.nodot:
        mov     byte [di], 0
        mov     byte [bp], 0
        clc
        ret

; build_new: name=map(sname,dname), then if dst had '.' add '.'+map(sext,dext)
build_new:
        mov     di, newname
        mov     si, sname
        mov     bx, dname
        call    map_field
        cmp     byte [dst_hasdot], 0
        je      .done
        mov     al, '.'
        mov     [di], al
        inc     di
        mov     si, sext
        mov     bx, dext
        call    map_field
.done:
        mov     byte [di], 0
        ret

; map_field: si=source field asciz, bx=mask field asciz, di=output (advanced)
map_field:
.ml:
        mov     al, [bx]
        or      al, al
        jz      .done
        cmp     al, '*'
        je      .star
        cmp     al, '?'
        je      .ques
        ; literal
        mov     [di], al
        inc     di
        cmp     byte [si], 0
        je      .lit_adv
        inc     si
.lit_adv:
        inc     bx
        jmp     .ml
.ques:
        cmp     byte [si], 0
        je      .q_adv
        mov     al, [si]
        mov     [di], al
        inc     di
        inc     si
.q_adv:
        inc     bx
        jmp     .ml
.star:
.sc:
        mov     al, [si]
        or      al, al
        jz      .sc_done
        mov     [di], al
        inc     di
        inc     si
        jmp     .sc
.sc_done:
        ; consume '*' and ignore the rest of this mask field
        inc     bx
.skip:
        mov     al, [bx]
        or      al, al
        jz      .done
        inc     bx
        jmp     .skip
.done:
        ret

; ----------------------------------------------------------------------------
cat:
        mov     al, [si]
        or      al, al
        jz      .d
        mov     [di], al
        inc     di
        inc     si
        jmp     cat
.d:     ret

emit_line:
        mov     ax, 0A0Dh
        stosw
        mov     cx, di
        sub     cx, linebuf
        mov     dx, linebuf
        mov     bx, 1
        mov     ah, 40h
        int     21h
        ret

put_dec32:
        push    bx
        mov     bx, 0
.dv:
        mov     cx, 10
        push    ax
        mov     ax, dx
        xor     dx, dx
        div     cx
        mov     [.qh], ax
        pop     ax
        div     cx
        mov     cx, dx
        mov     dx, [.qh]
        push    cx
        inc     bx
        mov     cx, ax
        or      cx, dx
        jnz     .dv
.emit:
        pop     ax
        add     al, '0'
        stosb
        dec     bx
        jnz     .emit
        pop     bx
        ret
.qh     dw 0

parse_two:
        movzx   cx, byte [80h]
        mov     si, 81h
        mov     di, arg1
        call    .one
        mov     di, arg2
        call    .one
        ret
.one:
.sk:    jcxz    .term
        cmp     byte [si], ' '
        jne     .rd
        inc     si
        dec     cx
        jmp     .sk
.rd:    jcxz    .term
        mov     al, [si]
        cmp     al, ' '
        je      .term
        cmp     al, 0Dh
        je      .term
        mov     [di], al
        inc     di
        inc     si
        dec     cx
        jmp     .rd
.term:
        mov     byte [di], 0
        ret

puts:
        mov     di, dx
.l:     cmp     byte [di], 0
        je      .w
        inc     di
        jmp     .l
.w:     mov     cx, di
        sub     cx, dx
        mov     bx, 1
        mov     ah, 40h
        int     21h
        ret

; ============================================================================
s_usage     db 'Usage: CCREN <srcmask> <dstmask>',13,10,0
s_nomatch   db 'CCREN: no files matched',13,10,0
s_arrow     db ' -> ',0
s_failed    db '  (FAILED)',0
s_renamed   db 'renamed ',0
s_files     db ' file(s)',0

section .bss
align 2
arg1        resb 128
arg2        resb 128
dname       resb 16
dext        resb 8
sname       resb 16
sext        resb 8
newname     resb 16
dst_hasdot  resb 1
ncount      resw 1
idx         resw 1
okcount     resw 1
curname     resw 1
linebuf     resb 80
dta         resb 128
names       resb MAXN*13
stackspace  resb 1024
stacktop:
