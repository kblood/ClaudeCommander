; ============================================================================
;  CCJOIN.COM  --  Claude Commander's file joiner (Layer 3)
;
;  Usage:  CCJOIN <output> <base>
;          Concatenates <base>.001, <base>.002, ... (in order, stopping at the
;          first missing part) into <output>. Inverse of CCSPLIT, e.g.
;          CCSPLIT BIG.ZIP 100K  then  CCJOIN BIG.ZIP BIG.
;
;  Safety: the parts are enumerated before <output> is created -- no
;  <base>.001 means nothing is touched, and <output> is refused if its
;  truename (INT 21h/60h) equals any part's (CCJOIN BIG.001 BIG would
;  otherwise truncate part 1 before reading it). A read/write error deletes
;  the partial output and exits 1.
;
;  Assemble:  nasm -f bin cjoin.asm -o ccjoin.com
; ============================================================================
        org     100h
BUFSZ   equ 16384
MAXPART equ 999

start:
        cld
        mov     sp, stacktop
        call    parse_two
        cmp     byte [arg1], 0
        je      .usage
        cmp     byte [arg2], 0
        je      .usage
        ; canonical output name
        mov     si, arg1
        mov     di, outtrue
        mov     ah, 60h
        int     21h
        jc      .errout
        ; enumerate the parts (stop at the first missing one); none of them
        ; may be the output file itself
        mov     word [partnum], 1
.scan:
        call    build_partname
        mov     ax, 4300h           ; exists? (get attributes)
        mov     dx, partname
        int     21h
        jc      .scanned
        mov     si, partname
        mov     di, parttrue
        mov     ah, 60h
        int     21h
        jc      .same               ; unresolvable -> refuse rather than guess
        call    same_true
        jc      .same
        inc     word [partnum]
        cmp     word [partnum], MAXPART
        jbe     .scan
.scanned:
        mov     ax, [partnum]
        dec     ax
        mov     [nparts], ax
        jz      .noparts            ; no <base>.001 -> leave <output> alone
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
        jc      .ioerr              ; vanished since the scan
        mov     [fh], ax
        call    copy_all            ; CF=1 on read/write error
        pushf
        mov     bx, [fh]
        mov     ah, 3Eh
        int     21h
        popf
        jc      .ioerr
        inc     word [partnum]
        mov     ax, [partnum]
        cmp     ax, [nparts]
        jbe     .part
.finish:
        mov     bx, [ofh]
        mov     ah, 3Eh
        int     21h
        jc      .ioerr_closed
        mov     di, linebuf
        mov     si, s_joined
        call    cat
        mov     ax, [nparts]
        xor     dx, dx
        call    put_dec32
        mov     si, s_parts
        call    cat
        call    emit_line
        mov     ax, 4C00h
        int     21h
.ioerr:
        mov     bx, [ofh]
        mov     ah, 3Eh
        int     21h
.ioerr_closed:
        mov     ah, 41h             ; don't leave a truncated output behind
        mov     dx, arg1
        int     21h
        mov     dx, s_errio
        jmp     .die
.noparts:
        mov     dx, s_noparts
        jmp     .die
.same:
        mov     dx, s_same
        jmp     .die
.usage:
        mov     dx, s_usage
        jmp     .die
.errout:
        mov     dx, s_errout
.die:
        call    puts
        mov     ax, 4C01h
        int     21h

; same_true: CF=1 if outtrue == parttrue (ASCII case-insensitive).
same_true:
        mov     si, outtrue
        mov     di, parttrue
.cmp:
        mov     al, [si]
        mov     ah, [di]
        cmp     al, 'a'
        jb      .h
        cmp     al, 'z'
        ja      .h
        sub     al, 20h
.h:     cmp     ah, 'a'
        jb      .c
        cmp     ah, 'z'
        ja      .c
        sub     ah, 20h
.c:     cmp     al, ah
        jne     .no
        or      al, al
        jz      .yes
        inc     si
        inc     di
        jmp     .cmp
.no:    clc
        ret
.yes:   stc
        ret

; ----------------------------------------------------------------------------
; copy_all: copy every byte from fh to ofh. CF=1 on a read error or a
; short/failed write.
copy_all:
.cl:
        mov     bx, [fh]
        mov     ah, 3Fh
        mov     cx, BUFSZ
        mov     dx, buf
        int     21h
        jc      .fail               ; AX = error code, not a count
        or      ax, ax
        jz      .d
        mov     cx, ax
        mov     bx, [ofh]
        mov     ah, 40h
        mov     dx, buf
        int     21h
        jc      .fail
        cmp     ax, cx              ; short write = disk full
        jne     .fail
        cmp     cx, BUFSZ
        jb      .d
        jmp     .cl
.d:     clc
        ret
.fail:  stc
        ret

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
s_same      db 'CCJOIN: output would overwrite one of the parts',13,10,0
s_errio     db 'CCJOIN: read/write error (disk full?) - output deleted',13,10,0
s_joined    db 'joined ',0
s_parts     db ' part(s)',0

section .bss
align 2
arg1        resb 128
arg2        resb 128
partname    resb 132
outtrue     resb 128
parttrue    resb 128
fh          resw 1
ofh         resw 1
partnum     resw 1
nparts      resw 1
linebuf     resb 80
buf         resb BUFSZ
stackspace  resb 1024
stacktop:
