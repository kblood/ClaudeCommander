; ============================================================================
;  CCJOIN.COM  --  Claude Commander's file joiner (Layer 3)
;
;  Usage:  CCJOIN <output> <base>
;          Concatenates <base>.001, <base>.002, ... (in order, stopping at the
;          first missing part) into <output>. Inverse of CCSPLIT, e.g.
;          CCSPLIT BIG.ZIP 100K  then  CCJOIN BIG.ZIP BIG.
;
;  Assemble:  nasm -f bin cjoin.asm -o ccjoin.com
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
        ; create output
        mov     ah, 3Ch
        xor     cx, cx
        mov     dx, arg1
        int     21h
        jc      .errout
        mov     [ofh], ax
        mov     word [partnum], 1
.part:
        call    build_partname
        mov     ax, 3D00h
        mov     dx, partname
        int     21h
        jc      .nomore             ; missing part -> stop
        mov     [fh], ax
        call    copy_all
        mov     bx, [fh]
        mov     ah, 3Eh
        int     21h
        inc     word [partnum]
        cmp     word [partnum], 1000
        jae     .finish
        jmp     .part
.nomore:
        ; if no part 001 existed at all, that's an error
        cmp     word [partnum], 1
        jne     .finish
        mov     bx, [ofh]
        mov     ah, 3Eh
        int     21h
        mov     dx, s_noparts
        call    puts
        mov     ax, 4C01h
        int     21h
.finish:
        mov     bx, [ofh]
        mov     ah, 3Eh
        int     21h
        mov     di, linebuf
        mov     si, s_joined
        call    cat
        mov     ax, [partnum]
        dec     ax                  ; partnum is one past the last joined
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
.errout:
        mov     dx, s_errout
        call    puts
        mov     ax, 4C01h
        int     21h

; ----------------------------------------------------------------------------
; copy_all: copy every byte from fh to ofh
copy_all:
.cl:
        mov     bx, [fh]
        mov     ah, 3Fh
        mov     cx, BUFSZ
        mov     dx, buf
        int     21h
        or      ax, ax
        jz      .d
        mov     cx, ax
        mov     bx, [ofh]
        mov     ah, 40h
        mov     dx, buf
        int     21h
        cmp     cx, BUFSZ
        jb      .d
        jmp     .cl
.d:     ret

; build_partname: arg2 + "." + 3-digit partnum -> partname
build_partname:
        mov     si, arg2
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
        mov     ax, [partnum]
        xor     dx, dx
        mov     cx, 100
        div     cx
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
s_usage     db 'Usage: CCJOIN <output> <base>',13,10,0
s_errout    db 'CCJOIN: cannot create output',13,10,0
s_noparts   db 'CCJOIN: no <base>.001 found',13,10,0
s_joined    db 'joined ',0
s_parts     db ' part(s)',0

section .bss
align 2
arg1        resb 128
arg2        resb 128
partname    resb 132
fh          resw 1
ofh         resw 1
partnum     resw 1
linebuf     resb 80
buf         resb BUFSZ
stackspace  resb 1024
stacktop:
