; ============================================================================
;  CCHEX.COM  --  Claude Commander's external hex dumper (Layer 3 helper)
;
;  Usage:  CCHEX <file>
;          CCHEX CC.COM            -> classic offset / 16 hex bytes / ASCII
;          CCHEX DATA.BIN | MORE   -> page large dumps
;
;  Reads the file in 16 KB chunks and writes a canonical hex dump to stdout:
;      00000000  4D 5A 90 00 03 00 00 00 ...  MZ..............
;  Non-printable bytes show as '.'.  Prints to stdout so callers can redirect
;  or pipe through MORE.
;
;  Assemble:  nasm -f bin chex.asm -o cchex.com
; ============================================================================
        org     100h

BUFSZ   equ 16384               ; read chunk (multiple of 16)

start:
        cld
        mov     sp, stacktop
        call    parse_tail          ; -> fname
        cmp     byte [fname], 0
        je      .usage
        mov     ax, 3D00h           ; open read-only
        mov     dx, fname
        int     21h
        jc      .err
        mov     [fh], ax
        mov     word [off_lo], 0
        mov     word [off_hi], 0
.chunk:
        mov     bx, [fh]
        mov     ah, 3Fh
        mov     cx, BUFSZ
        mov     dx, buf
        int     21h
        jc      .close
        mov     cx, ax              ; bytes read
        jcxz    .close              ; EOF
        mov     [chunklen], cx
        call    dump_chunk
        ; off += chunklen
        mov     ax, [off_lo]
        add     ax, [chunklen]
        mov     [off_lo], ax
        jnc     .noc
        inc     word [off_hi]
.noc:
        cmp     word [chunklen], BUFSZ
        jb      .close              ; short read -> EOF reached
        jmp     .chunk
.close:
        mov     bx, [fh]
        mov     ah, 3Eh
        int     21h
        mov     ax, 4C00h
        int     21h
.err:
        mov     dx, s_err
        call    puts
        mov     ax, 4C01h
        int     21h
.usage:
        mov     dx, s_usage
        call    puts
        mov     ax, 4C01h
        int     21h

; ----------------------------------------------------------------------------
; dump_chunk: emit buf[0..chunklen) as hex rows; row offset = off + row index.
dump_chunk:
        xor     si, si              ; byte index within buf
.row:
        cmp     si, [chunklen]
        jae     .ret
        mov     di, linebuf
        ; --- 8-hex-digit offset = off_hi:off_lo + si ---
        mov     ax, [off_lo]
        add     ax, si
        mov     dx, [off_hi]
        jnc     .nocarry
        inc     dx
.nocarry:
        push    ax
        mov     ax, dx
        call    put_hex4            ; high word
        pop     ax
        call    put_hex4            ; low word
        mov     al, ' '
        stosb
        mov     al, ' '
        stosb
        ; --- 16 hex bytes (pad missing with spaces) ---
        xor     cx, cx              ; column 0..15
.hx:
        cmp     cx, 16
        jae     .ascii
        mov     bx, si
        add     bx, cx
        cmp     bx, [chunklen]
        jae     .pad
        mov     al, [buf+bx]
        call    put_hex2
        mov     al, ' '
        stosb
        inc     cx
        jmp     .hx
.pad:
        mov     al, ' '
        stosb
        stosb
        stosb
        inc     cx
        jmp     .hx
.ascii:
        mov     al, ' '
        stosb
        ; --- ASCII column ---
        xor     cx, cx
.as:
        cmp     cx, 16
        jae     .eol
        mov     bx, si
        add     bx, cx
        cmp     bx, [chunklen]
        jae     .eol
        mov     al, [buf+bx]
        cmp     al, 20h
        jb      .dot
        cmp     al, 7Eh
        ja      .dot
        jmp     .putc
.dot:
        mov     al, '.'
.putc:
        stosb
        inc     cx
        jmp     .as
.eol:
        mov     ax, 0A0Dh           ; CRLF
        stosw
        ; write the row
        mov     cx, di
        sub     cx, linebuf
        mov     dx, linebuf
        mov     bx, 1
        mov     ah, 40h
        int     21h
        add     si, 16
        jmp     .row
.ret:
        ret

; ----------------------------------------------------------------------------
; put_hex4: AX -> 4 hex digits at [di]; di advanced.
put_hex4:
        push    ax
        mov     al, ah
        call    put_hex2
        pop     ax
        call    put_hex2
        ret

; put_hex2: AL -> 2 hex digits at [di]; di advanced.  Preserves nothing.
put_hex2:
        push    ax
        mov     ah, al
        shr     al, 1
        shr     al, 1
        shr     al, 1
        shr     al, 1
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
        add     al, 7               ; 'A'..'F'
.st:
        stosb
        ret

; ----------------------------------------------------------------------------
; parse PSP tail: first token -> fname
parse_tail:
        movzx   cx, byte [80h]
        mov     si, 81h
        mov     di, fname
.skip:
        jcxz    .cp
        cmp     byte [si], ' '
        jne     .cp
        inc     si
        dec     cx
        jmp     .skip
.cp:
        jcxz    .end
        mov     al, [si]
        cmp     al, ' '
        je      .end
        cmp     al, 0Dh
        je      .end
        mov     [di], al
        inc     di
        inc     si
        dec     cx
        jmp     .cp
.end:
        mov     byte [di], 0
        ret

; puts: DS:DX = ASCIIZ -> stdout
puts:
        mov     si, dx
        mov     di, dx
.len:   cmp     byte [di], 0
        je      .w
        inc     di
        jmp     .len
.w:     mov     cx, di
        sub     cx, dx
        mov     bx, 1
        mov     ah, 40h
        int     21h
        ret

; ============================================================================
s_usage     db 'Usage: CCHEX <file>',13,10,0
s_err       db 'CCHEX: cannot open file',13,10,0

section .bss
align 2
fname       resb 128
fh          resw 1
off_lo      resw 1
off_hi      resw 1
chunklen    resw 1
linebuf     resb 96
buf         resb BUFSZ
stackspace  resb 1024
stacktop:
