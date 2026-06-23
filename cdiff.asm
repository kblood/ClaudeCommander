; ============================================================================
;  CCDIFF.COM  --  Claude Commander's byte-compare tool (Layer 3)
;
;  Usage:  CCDIFF <file1> <file2>
;          -> "identical" if the files match byte-for-byte, otherwise
;             "differ at offset N: AA vs BB" (first differing byte, decimal
;             offset + hex values) or "differ: length N1 vs N2" if one is a
;             prefix of the other.
;
;  Assemble:  nasm -f bin cdiff.asm -o ccdiff.com
; ============================================================================
        org     100h
BUFSZ   equ 8192

start:
        cld
        mov     sp, stacktop
        call    parse_two
        cmp     byte [arg1], 0
        je      .usage
        cmp     byte [arg2], 0
        je      .usage
        mov     ax, 3D00h
        mov     dx, arg1
        int     21h
        jc      .err1
        mov     [fh1], ax
        mov     ax, 3D00h
        mov     dx, arg2
        int     21h
        jc      .err2
        mov     [fh2], ax
        mov     word [off_lo], 0
        mov     word [off_hi], 0
.loop:
        ; read a block from each
        mov     bx, [fh1]
        mov     ah, 3Fh
        mov     cx, BUFSZ
        mov     dx, buf1
        int     21h
        mov     [n1], ax
        mov     bx, [fh2]
        mov     ah, 3Fh
        mov     cx, BUFSZ
        mov     dx, buf2
        int     21h
        mov     [n2], ax
        ; common = min(n1,n2)
        mov     ax, [n1]
        mov     bx, [n2]
        cmp     ax, bx
        jbe     .havemin
        mov     ax, bx
.havemin:
        mov     [cmnlen], ax
        ; compare common bytes
        xor     si, si
.cmp:
        cmp     si, [cmnlen]
        jae     .blkdone
        mov     al, [buf1+si]
        mov     ah, [buf2+si]
        cmp     al, ah
        jne     .diff
        inc     si
        jmp     .cmp
.blkdone:
        ; advance offset by common
        mov     ax, [cmnlen]
        add     [off_lo], ax
        jnc     .nc
        inc     word [off_hi]
.nc:
        ; lengths differ this block?
        mov     ax, [n1]
        cmp     ax, [n2]
        jne     .lendiff
        ; equal counts: if zero, EOF on both -> identical
        cmp     word [n1], 0
        je      .identical
        jmp     .loop
.diff:
        ; first differing byte at off + si
        mov     [db1], al
        mov     [db2], ah
        mov     ax, [off_lo]
        add     ax, si
        mov     [off_lo], ax
        jnc     .nc2
        inc     word [off_hi]
.nc2:
        mov     di, linebuf
        mov     si, s_diff
        call    cat
        mov     ax, [off_lo]
        mov     dx, [off_hi]
        call    put_dec32
        mov     si, s_colon
        call    cat
        mov     al, [db1]
        call    put_hex2
        mov     si, s_vs
        call    cat
        mov     al, [db2]
        call    put_hex2
        call    emit_line
        jmp     .done
.lendiff:
        ; one file is a prefix of the other
        mov     di, linebuf
        mov     si, s_len
        call    cat
        mov     ax, [n1]
        xor     dx, dx
        ; report the smaller offset where they diverge: print n1,n2 counts
        ; (this block's read sizes) is less useful; instead print total sizes
        ; by reporting the offset where the shorter ended.
        mov     ax, [off_lo]
        mov     dx, [off_hi]
        call    put_dec32
        mov     si, s_lenend
        call    cat
        call    emit_line
        jmp     .done
.identical:
        mov     di, linebuf
        mov     si, s_same
        call    cat
        call    emit_line
.done:
        mov     bx, [fh1]
        mov     ah, 3Eh
        int     21h
        mov     bx, [fh2]
        mov     ah, 3Eh
        int     21h
        mov     ax, 4C00h
        int     21h
.usage:
        mov     dx, s_usage
        call    puts
        mov     ax, 4C01h
        int     21h
.err1:
        mov     dx, s_err1
        call    puts
        mov     ax, 4C01h
        int     21h
.err2:
        mov     bx, [fh1]
        mov     ah, 3Eh
        int     21h
        mov     dx, s_err2
        call    puts
        mov     ax, 4C01h
        int     21h

; ----------------------------------------------------------------------------
; cat: copy ASCIZ [si] to [di] (no NUL), di advanced
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

; put_dec32: DX:AX unsigned -> decimal at [di]
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

put_hex2:
        push    ax
        mov     ah, al
        shr     al, 4
        call    .nib
        mov     al, ah
        and     al, 0Fh
        call    .nib
        pop     ax
        ret
.nib:
        and     al, 0Fh
        add     al, '0'
        cmp     al, '9'
        jbe     .st
        add     al, 7
.st:    stosb
        ret

; parse_two: split the command tail into arg1, arg2 (space-separated)
parse_two:
        movzx   cx, byte [80h]
        mov     si, 81h
        mov     di, arg1
        call    .one
        mov     di, arg2
        call    .one
        ret
.one:
        ; skip spaces
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
s_usage     db 'Usage: CCDIFF <file1> <file2>',13,10,0
s_err1      db 'CCDIFF: cannot open file1',13,10,0
s_err2      db 'CCDIFF: cannot open file2',13,10,0
s_diff      db 'differ at offset ',0
s_colon     db ': ',0
s_vs        db ' vs ',0
s_len       db 'differ: prefix matches up to offset ',0
s_lenend    db ' (lengths differ)',0
s_same      db 'identical',0

section .bss
align 2
arg1        resb 128
arg2        resb 128
fh1         resw 1
fh2         resw 1
n1          resw 1
n2          resw 1
cmnlen      resw 1
off_lo      resw 1
off_hi      resw 1
db1         resb 1
db2         resb 1
linebuf     resb 160
buf1        resb BUFSZ
buf2        resb BUFSZ
stackspace  resb 1024
stacktop:
