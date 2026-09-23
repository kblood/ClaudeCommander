; ============================================================================
;  CCSPLIT.COM  --  Claude Commander's file splitter (Layer 3)
;
;  Usage:  CCSPLIT <file> <size>[K]
;          Splits <file> into <base>.001, <base>.002, ... each <size> bytes
;          (the last part may be smaller). <base> is <file> with its extension
;          replaced, so BIG.ZIP -> BIG.001, BIG.002 ... A trailing K/k on the
;          size multiplies by 1024 (e.g. 360K), M/m by 1048576. Rejoin with
;          CCJOIN.
;
;  Safety: everything is checked before the first byte is written -- the part
;  count (max 999), and that no part name resolves (INT 21h/60h truename) to
;  the source file itself. Stale higher-numbered parts left by an earlier split
;  (<base>.N+1, N+2 ... up to the first missing one) are deleted so CCJOIN
;  cannot append them. A read/write error deletes the parts written so far and
;  exits 1.
;
;  Assemble:  nasm -f bin csplit.asm -o ccsplit.com
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
        call    parse_size          ; arg2 -> psize_lo/hi, CF=1 if malformed
        jc      .usage
        mov     ax, [psize_lo]
        or      ax, [psize_hi]
        jz      .usage              ; size 0
        ; base name = arg1 with extension stripped
        call    make_base
        ; canonical name of the source (to refuse a part that IS the source)
        mov     si, arg1
        mov     di, srctrue
        mov     ah, 60h
        int     21h
        jc      .err
        ; open source
        mov     ax, 3D00h
        mov     dx, arg1
        int     21h
        jc      .err
        mov     [fh], ax
        ; size -> nparts = ceil(size/psize), at least 1 (empty file -> 1 part)
        mov     bx, ax
        mov     ax, 4202h
        xor     cx, cx
        xor     dx, dx
        int     21h
        jc      .errrd
        mov     [left_lo], ax
        mov     [left_hi], dx
        mov     ax, 4200h           ; back to the start
        mov     bx, [fh]
        xor     cx, cx
        xor     dx, dx
        int     21h
        jc      .errrd
        mov     word [nparts], 0
.cnt:
        inc     word [nparts]
        cmp     word [nparts], MAXPART
        ja      .toomany
        mov     ax, [psize_lo]
        mov     dx, [psize_hi]
        sub     [left_lo], ax
        sbb     [left_hi], dx
        jc      .cntdone            ; size <= parts*psize
        mov     ax, [left_lo]
        or      ax, [left_hi]
        jnz     .cnt
.cntdone:
        ; refuse if any part name we are about to create is the source itself
        mov     word [partnum], 1
.chk:
        call    part_is_src
        jc      .same
        inc     word [partnum]
        mov     ax, [partnum]
        cmp     ax, [nparts]
        jbe     .chk
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
        call    copy_part           ; CF=1 on a read/write error
        jc      .ioerr
        mov     bx, [ofh]
        mov     ah, 3Eh
        int     21h
        jc      .ioerr1
        inc     word [partnum]
        mov     ax, [partnum]
        cmp     ax, [nparts]
        jbe     .part
.done:
        mov     bx, [fh]
        mov     ah, 3Eh
        int     21h
        ; delete stale parts N+1, N+2 ... from an earlier split (stop at the
        ; first one that cannot be deleted, and never at the source itself)
        push    word [partnum]
.stale:
        cmp     word [partnum], MAXPART
        ja      .stale_done
        call    part_is_src         ; also builds partname
        jc      .stale_done
        mov     ah, 41h
        mov     dx, partname
        int     21h
        jc      .stale_done
        inc     word [partnum]
        jmp     .stale
.stale_done:
        pop     word [partnum]
        ; report number of parts written
        mov     di, linebuf
        mov     si, s_made
        call    cat
        mov     ax, [nparts]
        xor     dx, dx
        call    put_dec32
        mov     si, s_parts
        call    cat
        call    emit_line
        mov     ax, 4C00h
        int     21h
.usage:
        mov     dx, s_usage
        jmp     .die
.err:
        mov     dx, s_err
        jmp     .die
.errrd:
        mov     dx, s_errrd
        jmp     .die_close
.toomany:
        mov     dx, s_toomany
        jmp     .die_close
.same:
        mov     dx, s_same
        jmp     .die_close
.errp:
        call    del_written         ; parts 1..partnum-1
        mov     dx, s_errp
        jmp     .die_close
.ioerr:
        mov     bx, [ofh]
        mov     ah, 3Eh
        int     21h
.ioerr1:
        inc     word [partnum]      ; the current part is partial -> delete it too
        call    del_written
        mov     dx, s_errio
.die_close:
        push    dx
        mov     bx, [fh]
        mov     ah, 3Eh
        int     21h
        pop     dx
.die:
        call    puts
        mov     ax, 4C01h
        int     21h

; del_written: delete parts 1 .. partnum-1 (clean up after a failed split).
del_written:
        mov     cx, [partnum]
        mov     word [partnum], 1
.dl:
        cmp     [partnum], cx
        jae     .dd
        push    cx
        call    build_partname
        mov     ah, 41h
        mov     dx, partname
        int     21h
        pop     cx
        inc     word [partnum]
        jmp     .dl
.dd:    ret

; part_is_src: build partname for [partnum]; CF=1 if its truename equals the
; source's truename (or cannot be resolved -- refuse rather than guess).
part_is_src:
        call    build_partname
        mov     si, partname
        mov     di, parttrue
        mov     ah, 60h
        int     21h
        jc      .yes
        mov     si, srctrue
        mov     di, parttrue
.cmp:
        mov     al, [si]
        mov     ah, [di]
        call    upcase2
        cmp     al, ah
        jne     .no
        or      al, al
        jz      .yes
        inc     si
        inc     di
        jmp     .cmp
.no:
        clc
        ret
.yes:
        stc
        ret

; upcase2: uppercase ASCII letters in both AL and AH.
upcase2:
        cmp     al, 'a'
        jb      .h
        cmp     al, 'z'
        ja      .h
        sub     al, 20h
.h:     cmp     ah, 'a'
        jb      .d
        cmp     ah, 'z'
        ja      .d
        sub     ah, 20h
.d:     ret

; ----------------------------------------------------------------------------
; copy_part: copy up to psize bytes from fh to ofh (stops early at source
; EOF). CF=1 on a read error or a short/failed write.
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
        jc      .fail               ; read error (AX = error code, not a count)
        or      ax, ax
        jz      .full               ; source EOF
        mov     [got], ax
        ; write got bytes
        mov     cx, ax
        mov     bx, [ofh]
        mov     ah, 40h
        mov     dx, buf
        int     21h
        jc      .fail
        cmp     ax, cx              ; short write = disk full
        jne     .fail
        ; partleft -= got
        mov     ax, [got]
        sub     [pl_lo], ax
        sbb     word [pl_hi], 0
        ; if got < chunk -> source EOF
        mov     ax, [got]
        cmp     ax, [chunk]
        jb      .full
        jmp     .cl
.full:
        clc
        ret
.fail:
        stc
        ret

; parse_size: arg2 (decimal, optional trailing K/k or M/m) -> psize_lo:hi.
; CF=1 if arg2 is not <digits>[K|M] or overflows 32 bits.
parse_size:
        mov     word [psize_lo], 0
        mov     word [psize_hi], 0
        mov     si, arg2
        cmp     byte [si], '0'      ; must start with a digit
        jb      .bad
        cmp     byte [si], '9'
        ja      .bad
.dig:
        mov     al, [si]
        cmp     al, '0'
        jb      .ksuf
        cmp     al, '9'
        ja      .ksuf
        sub     al, '0'
        movzx   bx, al              ; digit
        ; psize = psize*10 + digit  (32-bit)
        mov     cx, 10
        push    bx
        mov     ax, [psize_lo]
        mul     cx                  ; dx:ax = psize_lo*10
        mov     [psize_lo], ax
        mov     [tmp_carry], dx
        mov     ax, [psize_hi]
        mul     cx                  ; dx:ax = psize_hi*10
        pop     bx
        or      dx, dx
        jnz     .bad                ; overflow
        add     ax, [tmp_carry]
        jc      .bad
        mov     [psize_hi], ax
        ; + digit
        add     [psize_lo], bx
        jnc     .nc
        inc     word [psize_hi]
        jz      .bad
.nc:
        inc     si
        jmp     .dig
.ksuf:
        or      al, al
        jz      .ok                 ; plain byte count
        mov     cx, 10
        cmp     al, 'K'
        je      .kk
        cmp     al, 'k'
        je      .kk
        mov     cx, 20
        cmp     al, 'M'
        je      .kk
        cmp     al, 'm'
        je      .kk
.bad:
        stc
        ret
.kk:
        cmp     byte [si+1], 0      ; suffix must end the argument
        jne     .bad
.shl1:
        shl     word [psize_lo], 1
        rcl     word [psize_hi], 1
        jc      .bad                ; overflow
        loop    .shl1
.ok:
        clc
        ret

; make_base: copy arg1 to basebuf, strip extension (last '.' in the final
; name component -- a '.' in a directory name is not an extension)
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
        cmp     al, '\'
        je      .sep
        cmp     al, '/'
        je      .sep
        cmp     al, ':'
        jne     .store
.sep:
        xor     bx, bx              ; new path component: forget earlier dots
.store:
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
s_usage     db 'Usage: CCSPLIT <file> <size>[K|M]',13,10,0
s_err       db 'CCSPLIT: cannot open file',13,10,0
s_errp      db 'CCSPLIT: cannot create part (nothing kept)',13,10,0
s_errrd     db 'CCSPLIT: cannot read file',13,10,0
s_errio     db 'CCSPLIT: read/write error (disk full?) - parts deleted',13,10,0
s_toomany   db 'CCSPLIT: more than 999 parts - use a bigger size',13,10,0
s_same      db 'CCSPLIT: a part name would overwrite the source file',13,10,0
s_made      db 'split into ',0
s_parts     db ' part(s)',0

section .bss
align 2
arg1        resb 128
arg2        resb 128
basebuf     resb 128
partname    resb 132
srctrue     resb 128
parttrue    resb 128
fh          resw 1
ofh         resw 1
partnum     resw 1
nparts      resw 1
left_lo     resw 1
left_hi     resw 1
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
