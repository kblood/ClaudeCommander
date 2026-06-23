; ============================================================================
;  CCSPLIT.COM  --  Claude Commander's file splitter (Layer 3)
;
;  Usage:  CCSPLIT <file> <size>[K]
;          Splits <file> into <base>.001, <base>.002, ... each <size> bytes
;          (the last part may be smaller). <base> is <file> with its extension
;          replaced, so BIG.ZIP -> BIG.001, BIG.002 ... A trailing K/k on the
;          size multiplies by 1024 (e.g. 360K). Rejoin with CCJOIN.
;
;  Assemble:  nasm -f bin csplit.asm -o ccsplit.com
; ============================================================================
        org     100h
BUFSZ   equ 16384

start:
        cld
        mov     sp, stacktop
        call    parse_two
        cmp     byte [arg1], 0
        je      .usage
        cmp     byte [arg2], 0
        je      .usage
        call    parse_size          ; arg2 -> psize_lo/hi
        mov     ax, [psize_lo]
        or      ax, [psize_hi]
        jz      .usage              ; size 0
        ; base name = arg1 with extension stripped
        call    make_base
        ; open source
        mov     ax, 3D00h
        mov     dx, arg1
        int     21h
        jc      .err
        mov     [fh], ax
        mov     word [partnum], 1
.part:
        call    build_partname
        ; create part file
        mov     ah, 3Ch
        xor     cx, cx
        mov     dx, partname
        int     21h
        jc      .errp
        mov     [ofh], ax
        call    copy_part           ; CF=1 if source EOF reached
        pushf
        mov     bx, [ofh]
        mov     ah, 3Eh
        int     21h
        popf
        jc      .done
        inc     word [partnum]
        cmp     word [partnum], 1000
        jae     .done               ; cap at 999 parts
        jmp     .part
.done:
        mov     bx, [fh]
        mov     ah, 3Eh
        int     21h
        ; report number of parts written
        mov     di, linebuf
        mov     si, s_made
        call    cat
        mov     ax, [partnum]
        xor     dx, dx
        call    put_dec32
        mov     si, s_parts
        call    cat
        call    emit_line
        mov     ax, 4C00h
        int     21h
.usage:
        mov     dx, s_usage
        call    puts
        mov     ax, 4C01h
        int     21h
.err:
        mov     dx, s_err
        call    puts
        mov     ax, 4C01h
        int     21h
.errp:
        mov     bx, [fh]
        mov     ah, 3Eh
        int     21h
        mov     dx, s_errp
        call    puts
        mov     ax, 4C01h
        int     21h

; ----------------------------------------------------------------------------
; copy_part: copy up to psize bytes from fh to ofh. CF=1 if source hit EOF.
copy_part:
        mov     ax, [psize_lo]
        mov     [pl_lo], ax
        mov     ax, [psize_hi]
        mov     [pl_hi], ax
.cl:
        ; partleft == 0 ?
        mov     ax, [pl_lo]
        or      ax, [pl_hi]
        jz      .full
        ; chunk = min(BUFSZ, partleft)
        mov     cx, BUFSZ
        cmp     word [pl_hi], 0
        jne     .haspread
        cmp     word [pl_lo], BUFSZ
        jae     .haspread
        mov     cx, [pl_lo]
.haspread:
        mov     [chunk], cx
        mov     bx, [fh]
        mov     ah, 3Fh
        mov     dx, buf
        int     21h                 ; cx = chunk
        or      ax, ax
        jz      .eof
        mov     [got], ax
        ; write got bytes
        mov     cx, ax
        mov     bx, [ofh]
        mov     ah, 40h
        mov     dx, buf
        int     21h
        ; partleft -= got
        mov     ax, [got]
        sub     [pl_lo], ax
        sbb     word [pl_hi], 0
        ; if got < chunk -> source EOF
        mov     ax, [got]
        cmp     ax, [chunk]
        jb      .eof
        jmp     .cl
.full:
        clc
        ret
.eof:
        stc
        ret

; parse_size: arg2 (decimal, optional trailing K/k) -> psize_lo:psize_hi
parse_size:
        mov     word [psize_lo], 0
        mov     word [psize_hi], 0
        mov     si, arg2
.dig:
        mov     al, [si]
        cmp     al, '0'
        jb      .ksuf
        cmp     al, '9'
        ja      .ksuf
        sub     al, '0'
        movzx   bx, al              ; digit
        ; psize = psize*10 + digit  (32-bit)
        ; multiply dx:ax (=psize) by 10
        mov     ax, [psize_lo]
        mov     dx, [psize_hi]
        ; *10 = (*8)+(*2): do via repeated add is messy; use mul by 10 32-bit
        mov     cx, 10
        push    bx
        ; low*10
        mul     cx                  ; dx:ax = psize_lo*10
        mov     [psize_lo], ax
        mov     [tmp_carry], dx
        mov     ax, [psize_hi]
        mul     cx                  ; ax = psize_hi*10 (low word kept)
        add     ax, [tmp_carry]
        mov     [psize_hi], ax
        pop     bx
        ; + digit
        add     [psize_lo], bx
        jnc     .nc
        inc     word [psize_hi]
.nc:
        inc     si
        jmp     .dig
.ksuf:
        cmp     al, 'K'
        je      .kk
        cmp     al, 'k'
        je      .kk
        ret
.kk:
        ; *1024 = shift left 10
        mov     cx, 10
.shl1:
        shl     word [psize_lo], 1
        rcl     word [psize_hi], 1
        loop    .shl1
        ret

; make_base: copy arg1 to basebuf, strip extension (last '.' in name component)
make_base:
        mov     si, arg1
        mov     di, basebuf
        xor     bx, bx              ; bx = position of last '.', 0=none
        xor     cx, cx              ; index
.cp:
        mov     al, [si]
        or      al, al
        jz      .end
        cmp     al, '.'
        jne     .nodot
        mov     bx, di              ; remember location (di) of dot
.nodot:
        mov     [di], al
        inc     di
        inc     si
        jmp     .cp
.end:
        mov     byte [di], 0
        or      bx, bx
        jz      .nostrip
        mov     di, bx              ; truncate at the dot
        mov     byte [di], 0
.nostrip:
        ret

; build_partname: basebuf + "." + 3-digit partnum -> partname
build_partname:
        mov     si, basebuf
        mov     di, partname
.cp:
        mov     al, [si]
        or      al, al
        jz      .dot
        mov     [di], al
        inc     di
        inc     si
        jmp     .cp
.dot:
        mov     al, '.'
        stosb
        ; 3 digits of partnum
        mov     ax, [partnum]
        xor     dx, dx
        mov     cx, 100
        div     cx                  ; ax=hundreds, dx=rem
        add     al, '0'
        stosb
        mov     ax, dx
        xor     dx, dx
        mov     cx, 10
        div     cx
        add     al, '0'
        stosb
        mov     al, dl
        add     al, '0'
        stosb
        mov     byte [di], 0
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
s_usage     db 'Usage: CCSPLIT <file> <size>[K]',13,10,0
s_err       db 'CCSPLIT: cannot open file',13,10,0
s_errp      db 'CCSPLIT: cannot create part',13,10,0
s_made      db 'split into ',0
s_parts     db ' part(s)',0

section .bss
align 2
arg1        resb 128
arg2        resb 64
basebuf     resb 128
partname    resb 132
fh          resw 1
ofh         resw 1
partnum     resw 1
psize_lo    resw 1
psize_hi    resw 1
pl_lo       resw 1
pl_hi       resw 1
chunk       resw 1
got         resw 1
tmp_carry   resw 1
linebuf     resb 80
buf         resb BUFSZ
stackspace  resb 1024
stacktop:
