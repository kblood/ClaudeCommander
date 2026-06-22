; ============================================================================
;  CCZIP.COM  --  Claude Commander's external ZIP lister (Layer 3 helper)
;
;  Usage:  CCZIP <file.zip>
;  Lists the contents of a ZIP archive (name, uncompressed size, method) by
;  parsing the End-Of-Central-Directory record and the central directory.
;  Prints to stdout so cc can show or redirect it:  CCZIP foo.zip > list.txt
;
;  (Listing only -- DEFLATE decompression is intentionally out of scope for a
;  tiny helper.  Extraction can be added later or delegated to a real unzip.)
;
;  Assemble:  nasm -f bin czip.asm -o cczip.com
; ============================================================================
        org     100h

TAILMAX equ 4096                ; bytes from EOF scanned for the EOCD record
CDMAX   equ 32768               ; central-directory bytes buffered

start:
        cld
        mov     sp, stacktop
        call    parse_tail          ; -> fname
        cmp     byte [fname], 0
        je      .usage
        mov     ax, 3D00h
        mov     dx, fname
        int     21h
        jc      .noopen
        mov     [fh], ax

        ; --- file size via LSEEK to end ---
        mov     bx, [fh]
        mov     ax, 4202h
        xor     cx, cx
        xor     dx, dx
        int     21h                 ; dx:ax = size
        mov     [fsize_lo], ax
        mov     [fsize_hi], dx

        ; --- compute tail start = size - min(size, TAILMAX) ---
        mov     ax, [fsize_lo]
        mov     dx, [fsize_hi]
        or      dx, dx
        jnz     .bigtail            ; size >= 64K -> tail is full TAILMAX
        cmp     ax, TAILMAX
        jae     .bigtail
        ; small file: read the whole thing from 0
        mov     [taillen], ax
        xor     cx, cx
        xor     dx, dx
        jmp     .seektail
.bigtail:
        mov     word [taillen], TAILMAX
        mov     ax, [fsize_lo]
        mov     dx, [fsize_hi]
        sub     ax, TAILMAX
        sbb     dx, 0
        mov     cx, dx
        mov     dx, ax
.seektail:
        mov     bx, [fh]
        mov     ax, 4200h
        int     21h
        mov     bx, [fh]
        mov     ah, 3Fh
        mov     cx, [taillen]
        mov     dx, tailbuf
        int     21h
        mov     [tailgot], ax

        ; --- scan backward for the EOCD signature 50 4B 05 06 ---
        mov     cx, [tailgot]
        sub     cx, 4
        jbe     .notzip
        mov     si, tailbuf
        add     si, cx              ; last position where a 4-byte sig fits
.scan:
        cmp     byte [si], 050h
        jne     .sdn
        cmp     byte [si+1], 04Bh
        jne     .sdn
        cmp     byte [si+2], 005h
        jne     .sdn
        cmp     byte [si+3], 006h
        je      .foundeocd
.sdn:
        dec     si
        cmp     si, tailbuf
        jae     .scan
        jmp     .notzip
.foundeocd:
        ; si -> EOCD.  count=word[+10], cdofs=dword[+16]
        mov     ax, [si+10]
        mov     [zcount], ax
        mov     ax, [si+16]
        mov     dx, [si+18]
        mov     [cdofs_lo], ax
        mov     [cdofs_hi], dx

        ; --- read the central directory into cdbuf ---
        mov     bx, [fh]
        mov     ax, 4200h
        mov     cx, [cdofs_hi]
        mov     dx, [cdofs_lo]
        int     21h
        mov     bx, [fh]
        mov     ah, 3Fh
        mov     cx, CDMAX
        mov     dx, cdbuf
        int     21h
        mov     [cdgot], ax

        mov     ah, 3Eh             ; close the zip
        mov     bx, [fh]
        int     21h

        ; --- walk central-directory headers ---
        mov     si, cdbuf
        mov     bp, [zcount]        ; entries remaining
.walk:
        or      bp, bp
        jz      .done
        ; bounds: need at least 46 bytes of header
        mov     ax, si
        sub     ax, cdbuf
        add     ax, 46
        cmp     ax, [cdgot]
        ja      .done
        ; signature 50 4B 01 02 ?
        cmp     byte [si], 050h
        jne     .done
        cmp     byte [si+1], 04Bh
        jne     .done
        cmp     byte [si+2], 001h
        jne     .done
        cmp     byte [si+3], 002h
        jne     .done
        call    print_entry         ; advances si to next header
        dec     bp
        jmp     .walk
.done:
        mov     ax, 4C00h
        int     21h

.usage:
        mov     si, s_usage
        jmp     .die
.noopen:
        mov     si, s_noopen
        jmp     .die
.notzip:
        mov     bx, [fh]            ; close if open
        mov     ah, 3Eh
        int     21h
        mov     si, s_notzip
.die:
        call    puts
        mov     ax, 4C01h
        int     21h

; ----------------------------------------------------------------------------
; print one central-directory entry; si -> header, advanced to the next.
;   method=word[+10] usize=dword[+24] namelen=word[+28]
;   extralen=word[+30] commentlen=word[+32] name@+46
print_entry:
        mov     di, linebuf
        ; name (namelen bytes from si+46)
        mov     cx, [si+28]
        push    si
        lea     bx, [si+46]
.nm:
        jcxz    .nmend
        mov     al, [bx]
        mov     [di], al
        inc     bx
        inc     di
        dec     cx
        jmp     .nm
.nmend:
        pop     si
        ; pad to column 40 with spaces (clamped)
        mov     ax, di
        sub     ax, linebuf
        cmp     ax, 40
        jae     .sz
        mov     cx, 40
        sub     cx, ax
.pad:
        mov     byte [di], ' '
        inc     di
        loop    .pad
.sz:
        mov     byte [di], ' '
        inc     di
        ; uncompressed size (dword at +24)
        mov     ax, [si+24]
        mov     dx, [si+26]
        call    putnum_di
        mov     bx, s_bytes
        call    cat_di
        ; method
        mov     ax, [si+10]
        or      ax, ax
        jnz     .defl
        mov     bx, s_stored
        jmp     .pm
.defl:
        cmp     ax, 8
        jne     .other
        mov     bx, s_defl
        jmp     .pm
.other:
        mov     bx, s_other
.pm:
        call    cat_di
        mov     word [di], 0A0Dh
        add     di, 2
        ; write linebuf
        mov     cx, di
        sub     cx, linebuf
        mov     ah, 40h
        mov     bx, 1
        mov     dx, linebuf
        int     21h
        ; advance si to next header: 46 + namelen + extralen + commentlen
        mov     ax, 46
        add     ax, [si+28]
        add     ax, [si+30]
        add     ax, [si+32]
        add     si, ax
        ret

; append ASCIIZ ds:bx at [di] (no NUL); di advanced.
cat_di:
        mov     al, [bx]
        or      al, al
        jz      .d
        mov     [di], al
        inc     bx
        inc     di
        jmp     cat_di
.d:     ret

; append decimal of dx:ax at [di]; di advanced.
putnum_di:
        push    si
        mov     si, numtmp+15
        mov     byte [si], 0
        mov     bx, 10
.dv:
        ; divide dx:ax by 10 -> quotient dx:ax, remainder in cx
        mov     cx, ax              ; save low
        mov     ax, dx
        xor     dx, dx
        div     bx                  ; ax=hi/10, dx=hi%10
        mov     [hiq], ax
        mov     ax, cx
        div     bx                  ; ax=lo/10 (with carry from dx), dx=rem
        mov     cx, dx              ; remainder digit
        mov     dx, [hiq]           ; new high quotient
        dec     si
        add     cl, '0'
        mov     [si], cl
        ; quotient now dx:ax; loop while nonzero
        mov     cx, ax
        or      cx, dx
        jnz     .dv
        ; copy digits from si to di
.cp:
        mov     al, [si]
        or      al, al
        jz      .e
        mov     [di], al
        inc     si
        inc     di
        jmp     .cp
.e:
        pop     si
        ret

; write ASCIIZ ds:si to stdout.
puts:
        mov     di, si
.l:
        cmp     byte [di], 0
        je      .w
        inc     di
        jmp     .l
.w:
        mov     cx, di
        sub     cx, si
        mov     ah, 40h
        mov     bx, 1
        mov     dx, si
        int     21h
        ret

; ----------------------------------------------------------------------------
parse_tail:
        movzx   cx, byte [80h]
        mov     si, 81h
        mov     di, fname
.sp:
        jcxz    .e
        cmp     byte [si], ' '
        jne     .cp
        inc     si
        dec     cx
        jmp     .sp
.cp:
        jcxz    .e
        mov     al, [si]
        cmp     al, ' '
        je      .e
        cmp     al, 0Dh
        je      .e
        mov     [di], al
        inc     si
        inc     di
        dec     cx
        jmp     .cp
.e:
        mov     byte [di], 0
        ret

; ============================================================================
s_usage     db 'Usage: CCZIP <file.zip>',0Dh,0Ah,0
s_noopen    db 'CCZIP: cannot open file',0Dh,0Ah,0
s_notzip    db 'CCZIP: not a ZIP (no central directory found)',0Dh,0Ah,0
s_bytes     db ' bytes ',0
s_stored    db '(stored)',0
s_defl      db '(deflated)',0
s_other     db '(method?)',0

section .bss
align 2
fname       resb 128
fh          resw 1
fsize_lo    resw 1
fsize_hi    resw 1
taillen     resw 1
tailgot     resw 1
cdgot       resw 1
zcount      resw 1
cdofs_lo    resw 1
cdofs_hi    resw 1
hiq         resw 1
numtmp      resb 16
linebuf     resb 160
tailbuf     resb TAILMAX
cdbuf       resb CDMAX
stackspace  resb 1024
stacktop:
