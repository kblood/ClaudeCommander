; ============================================================================
;  CCSUM.COM  --  Claude Commander's external CRC-32 / size tool (Layer 3)
;
;  Usage:  CCSUM <file>
;          CCSUM CC.COM      -> "CBF43926  9882  CC.COM"  (crc32  size  name)
;
;  Computes the standard CRC-32 (zlib polynomial 0xEDB88320, reflected) on the
;  fly -- no lookup table, so the binary stays tiny -- and prints the 8-digit
;  hex CRC, the decimal byte count, and the file name to stdout.  Useful for
;  verifying that two copies of a file are identical.
;
;  Assemble:  nasm -f bin csum.asm -o ccsum.com
; ============================================================================
        org     100h

BUFSZ   equ 16384

start:
        cld
        mov     sp, stacktop
        call    parse_tail
        cmp     byte [fname], 0
        je      .usage
        mov     ax, 3D00h
        mov     dx, fname
        int     21h
        jc      .err
        mov     [fh], ax
        ; crc = 0xFFFFFFFF (dx:ax), size = 0 (sz_hi:sz_lo)
        mov     dx, 0FFFFh
        mov     ax, 0FFFFh
        mov     [crc_hi], dx
        mov     [crc_lo], ax
        mov     word [sz_lo], 0
        mov     word [sz_hi], 0
.chunk:
        mov     bx, [fh]
        mov     ah, 3Fh
        mov     cx, BUFSZ
        mov     dx, buf
        int     21h
        jc      .close
        mov     cx, ax
        jcxz    .close
        mov     [chunklen], cx
        ; size += chunklen
        add     [sz_lo], cx
        jnc     .nsc
        inc     word [sz_hi]
.nsc:
        call    crc_chunk
        cmp     word [chunklen], BUFSZ
        jb      .close
        jmp     .chunk
.close:
        mov     bx, [fh]
        mov     ah, 3Eh
        int     21h
        ; finalize: crc ^= 0xFFFFFFFF
        mov     ax, [crc_lo]
        xor     ax, 0FFFFh
        mov     [crc_lo], ax
        mov     ax, [crc_hi]
        xor     ax, 0FFFFh
        mov     [crc_hi], ax
        call    print_result
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
; crc_chunk: fold buf[0..chunklen) into crc_hi:crc_lo.
crc_chunk:
        xor     si, si
        mov     dx, [crc_hi]
        mov     ax, [crc_lo]        ; crc in dx:ax
.byte:
        cmp     si, [chunklen]
        jae     .done
        mov     bl, [buf+si]
        xor     al, bl              ; crc ^= byte (low 8 bits)
        mov     cx, 8
.bit:
        mov     bx, ax
        and     bx, 1               ; bx = bit shifted out
        shr     dx, 1
        rcr     ax, 1               ; crc >>= 1 across dx:ax
        or      bx, bx
        jz      .nopoly
        xor     dx, 0EDB8h          ; ^ polynomial high
        xor     ax, 08320h          ; ^ polynomial low
.nopoly:
        loop    .bit
        inc     si
        jmp     .byte
.done:
        mov     [crc_hi], dx
        mov     [crc_lo], ax
        ret

; ----------------------------------------------------------------------------
; print_result: "<crc8>  <size>  <name>" CRLF
print_result:
        mov     di, linebuf
        mov     ax, [crc_hi]
        call    put_hex4
        mov     ax, [crc_lo]
        call    put_hex4
        mov     al, ' '
        stosb
        stosb
        ; decimal size (32-bit sz_hi:sz_lo)
        mov     ax, [sz_lo]
        mov     dx, [sz_hi]
        call    put_dec32
        mov     al, ' '
        stosb
        stosb
        mov     si, fname
.nm:    mov     al, [si]
        or      al, al
        jz      .eol
        stosb
        inc     si
        jmp     .nm
.eol:
        mov     ax, 0A0Dh
        stosw
        mov     cx, di
        sub     cx, linebuf
        mov     dx, linebuf
        mov     bx, 1
        mov     ah, 40h
        int     21h
        ret

; put_dec32: DX:AX = unsigned 32-bit -> decimal at [di]; di advanced.
; Repeated divide by 10 (32-bit / 16-bit), digits pushed then emitted.
put_dec32:
        mov     bx, 0               ; digit count
.dv:
        ; divide dx:ax by 10 -> quotient dx:ax, remainder in cx
        mov     cx, 10
        push    ax
        mov     ax, dx
        xor     dx, dx
        div     cx                  ; ax = hi/10, dx = hi%10
        mov     [.qh], ax
        pop     ax                  ; ax = low word, dx = remainder-so-far
        div     cx                  ; ax = low quotient, dx = remainder (0..9)
        mov     cx, dx              ; cx = digit
        mov     dx, [.qh]           ; restore high quotient
        push    cx                  ; save digit
        inc     bx
        mov     cx, ax
        or      cx, dx
        jnz     .dv                 ; while value != 0
.emit:
        pop     ax
        add     al, '0'
        stosb
        dec     bx
        jnz     .emit
        ret
.qh     dw 0

; put_hex4: AX -> 4 hex digits at [di].
put_hex4:
        push    ax
        mov     al, ah
        call    put_hex2
        pop     ax
        call    put_hex2
        ret
; put_hex2: AL -> 2 hex digits at [di].
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
        add     al, 7
.st:
        stosb
        ret

; ----------------------------------------------------------------------------
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

puts:
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
s_usage     db 'Usage: CCSUM <file>',13,10,0
s_err       db 'CCSUM: cannot open file',13,10,0

section .bss
align 2
fname       resb 128
fh          resw 1
crc_lo      resw 1
crc_hi      resw 1
sz_lo       resw 1
sz_hi       resw 1
chunklen    resw 1
linebuf     resb 160
buf         resb BUFSZ
stackspace  resb 1024
stacktop:
