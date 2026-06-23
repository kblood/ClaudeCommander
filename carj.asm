; ============================================================================
;  CCARJ.COM  --  Claude Commander's ARJ-archive plugin
;
;  Usage:  CCARJ <a.arj>            human listing (size / name)
;          CCARJ L  <a.arj>         machine listing for cc: "<size> <name>"
;          CCARJ X  <a.arj> <n> <d> extract file #n (L order) to dir <d>
;          CCARJ XA <a.arj> <d>     extract every file to dir <d>
;
;  ARJ layout: a chain of blocks, each
;     2  magic 0x60 0xEA
;     2  basic-header size N   (0 => end-of-archive marker)
;     N  basic header
;     4  header CRC
;     [2-byte ext-header size + bytes + 4 CRC]*  (0 terminates)   (rarely used)
;     <file data>            (compressed-size bytes; file headers only)
;  The first block is the archive (main) header and carries no file data.
;  Basic-header fields used: +5 method(0=stored), +6 file_type, +12 compressed
;  size (dword), +16 original size (dword), +30 filename (NUL-terminated).
;
;  This helper browses EVERY entry; extraction handles method-0 (STORED) byte
;  for byte. Compressed methods (1-4 are ARJ's own LZ77+Huffman) are listed but
;  not decoded -- "decompress best-effort" per the goal -- and are skipped on
;  extract. Layer-3 helper: cc's [open] map (arj=CCARJ) makes it browsable.
;
;  Assemble:  nasm -f bin carj.asm -o ccarj.com
; ============================================================================
        org     100h

start:
        cld
        mov     sp, stacktop
        mov     byte [lmode], 0
        mov     byte [xmode], 0
        mov     byte [xallmode], 0
        mov     byte [fname], 0
        call    parse_args
        cmp     byte [fname], 0
        je      .usage
        mov     ax, 3D00h
        mov     dx, fname
        int     21h
        jc      .noopen
        mov     [fh], ax
        call    parse_main          ; consume the archive header (no data)
        call    files_loop
        mov     bx, [fh]
        mov     ah, 3Eh
        int     21h
        mov     ax, 4C00h
        int     21h
.usage:
        mov     si, s_usage
        jmp     .die
.noopen:
        mov     si, s_noopen
.die:
        call    puts
        mov     ax, 4C01h
        int     21h

; ----------------------------------------------------------------------------
; read cx bytes into ds:dx ; ax = bytes actually read
read_n:
        push    bx
        mov     bx, [fh]
        mov     ah, 3Fh
        int     21h
        pop     bx
        ret

; advance the file pointer by dx:ax bytes (forward, from current)
skip32:
        mov     cx, dx
        mov     dx, ax
        mov     bx, [fh]
        mov     ax, 4201h
        int     21h
        ret

; consume any extended headers (each: 2-byte size + size bytes + 4 CRC; a
; size word of 0 terminates the list).
skip_ext:
.l:
        mov     cx, 2
        mov     dx, wbuf
        call    read_n
        cmp     ax, 2
        jne     .done
        mov     ax, [wbuf]
        or      ax, ax
        jz      .done
        xor     dx, dx
        call    skip32              ; skip ext-header body
        mov     ax, 4
        xor     dx, dx
        call    skip32              ; skip its CRC
        jmp     .l
.done:
        ret

; first block = archive header: validate magic, skip header + CRC + ext.
parse_main:
        mov     cx, 2
        mov     dx, wbuf
        call    read_n
        cmp     ax, 2
        jne     .ret
        cmp     byte [wbuf], 60h
        jne     .ret
        cmp     byte [wbuf+1], 0EAh
        jne     .ret
        mov     cx, 2
        mov     dx, wbuf
        call    read_n
        cmp     ax, 2
        jne     .ret
        mov     ax, [wbuf]          ; basic header size
        or      ax, ax
        jz      .ret
        xor     dx, dx
        call    skip32              ; skip the main header body
        mov     ax, 4
        xor     dx, dx
        call    skip32              ; skip its CRC
        call    skip_ext
.ret:
        ret

; walk the file blocks until the end marker (size word = 0) or EOF.
files_loop:
        mov     word [filei], 0
.next:
        mov     cx, 2
        mov     dx, wbuf
        call    read_n
        cmp     ax, 2
        jne     .done
        cmp     byte [wbuf], 60h
        jne     .done
        cmp     byte [wbuf+1], 0EAh
        jne     .done
        mov     cx, 2
        mov     dx, wbuf
        call    read_n
        cmp     ax, 2
        jne     .done
        mov     ax, [wbuf]
        or      ax, ax
        jz      .done               ; end-of-archive marker
        mov     [hsize], ax
        cmp     ax, HBUF_SZ
        ja      .done               ; corrupt / oversized header
        mov     cx, [hsize]
        mov     dx, hbuf
        call    read_n
        mov     ax, 4
        xor     dx, dx
        call    skip32              ; header CRC
        call    skip_ext
        call    on_file             ; lists/extracts; leaves us at next block
        jmp     .next
.done:
        ret

; positioned at the file data; hbuf holds the basic header.
on_file:
        cmp     byte [hbuf+6], 3    ; file_type 3 = directory -> ignore
        je      .skiponly
        call    set_basename
        cmp     byte [xmode], 0
        jne     .x
        cmp     byte [xallmode], 0
        jne     .xa
        call    emit_listing
        call    skip_data
        jmp     .inc
.x:
        mov     ax, [filei]
        cmp     ax, [xindex]
        jne     .skip
        call    do_extract
        jmp     .inc
.skip:
        call    skip_data
        jmp     .inc
.xa:
        call    do_extract
.inc:
        inc     word [filei]
        ret
.skiponly:
        call    skip_data
        ret

; extract the current entry if STORED; otherwise skip (best-effort).
do_extract:
        cmp     byte [hbuf+5], 0    ; method 0 = stored
        jne     .skip
        call    extract_stored
        ret
.skip:
        call    skip_data
        ret

; skip the compressed data (advance to the next block)
skip_data:
        mov     ax, [hbuf+12]
        mov     dx, [hbuf+14]
        call    skip32
        ret

; copy [hbuf+12] (compressed size) bytes verbatim into <destdir>\<namebuf>
extract_stored:
        call    build_outpath
        mov     ah, 3Ch
        xor     cx, cx
        mov     dx, outpath
        int     21h
        jc      .skipd
        mov     [ofh], ax
        mov     ax, [hbuf+12]
        mov     [rem], ax
        mov     ax, [hbuf+14]
        mov     [rem+2], ax
.cl:
        mov     ax, [rem]
        mov     dx, [rem+2]
        mov     cx, ax
        or      cx, dx
        jz      .close              ; remaining == 0
        mov     cx, 4096
        or      dx, dx
        jnz     .rd                 ; >= 64K left -> full chunk
        cmp     ax, cx
        jae     .rd
        mov     cx, ax              ; final partial chunk
.rd:
        mov     dx, datbuf
        call    read_n              ; ax = bytes read
        or      ax, ax
        jz      .close
        mov     cx, ax
        mov     bx, [ofh]
        mov     ah, 40h
        mov     dx, datbuf
        int     21h
        mov     bx, ax              ; bytes written = bytes read (ax)
        sub     [rem], bx
        sbb     word [rem+2], 0
        jmp     .cl
.close:
        mov     bx, [ofh]
        mov     ah, 3Eh
        int     21h
        ret
.skipd:
        call    skip_data
        ret

; hbuf filename (+30, NUL-terminated, may carry a path) -> namebuf = the base
; name, spaces -> '_', capped to 12 chars.
set_basename:
        mov     si, hbuf+30
        mov     bx, si              ; bx = start of base name
.scan:
        mov     al, [si]
        or      al, al
        jz      .copy
        cmp     al, '/'
        je      .sep
        cmp     al, '\'
        je      .sep
        inc     si
        jmp     .scan
.sep:
        inc     si
        mov     bx, si              ; base name restarts after the separator
        jmp     .scan
.copy:
        mov     si, bx
        mov     di, namebuf
        mov     cx, 12
.cc:
        mov     al, [si]
        or      al, al
        jz      .cdone
        jcxz    .cdone
        cmp     al, ' '
        jne     .keep
        mov     al, '_'
.keep:
        mov     [di], al
        inc     di
        inc     si
        dec     cx
        jmp     .cc
.cdone:
        mov     byte [di], 0
        cmp     di, namebuf         ; empty? give it a placeholder
        jne     .ret
        mov     byte [namebuf], 'F'
        mov     byte [namebuf+1], 'I'
        mov     byte [namebuf+2], 'L'
        mov     byte [namebuf+3], 'E'
        mov     byte [namebuf+4], 0
.ret:
        ret

; outpath = destdir + '\' + namebuf
build_outpath:
        mov     si, destdir
        mov     di, outpath
.d:
        mov     al, [si]
        or      al, al
        jz      .de
        mov     [di], al
        inc     si
        inc     di
        jmp     .d
.de:
        cmp     byte [di-1], '\'
        je      .nm
        cmp     byte [di-1], '/'
        je      .nm
        mov     byte [di], '\'
        inc     di
.nm:
        mov     si, namebuf
.n:
        mov     al, [si]
        mov     [di], al
        or      al, al
        jz      .done
        inc     si
        inc     di
        jmp     .n
.done:
        ret

; current entry -> stdout "<original-size> <namebuf>\r\n"
emit_listing:
        mov     ax, [hbuf+16]
        mov     dx, [hbuf+18]
        mov     di, linebuf
        call    putnum_di
        mov     byte [di], ' '
        inc     di
        mov     bx, namebuf
        call    cat_di
        mov     word [di], 0A0Dh
        add     di, 2
        mov     cx, di
        sub     cx, linebuf
        mov     ah, 40h
        mov     bx, 1
        mov     dx, linebuf
        int     21h
        ret

; ----------------------------------------------------------------------------
cat_di:
        mov     al, [bx]
        or      al, al
        jz      .d
        mov     [di], al
        inc     bx
        inc     di
        jmp     cat_di
.d:     ret

putnum_di:
        push    si
        mov     si, numtmp+15
        mov     byte [si], 0
        mov     bx, 10
.dv:
        mov     cx, ax
        mov     ax, dx
        xor     dx, dx
        div     bx
        mov     [hiq], ax
        mov     ax, cx
        div     bx
        mov     cx, dx
        mov     dx, [hiq]
        dec     si
        add     cl, '0'
        mov     [si], cl
        mov     cx, ax
        or      cx, dx
        jnz     .dv
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
parse_args:
        mov     si, 81h
.term:
        mov     al, [si]
        or      al, al
        jz      .t0
        cmp     al, 0Dh
        je      .t0
        inc     si
        jmp     .term
.t0:
        mov     byte [si], 0
        mov     si, 81h
        call    skip_sp
        mov     di, tok1
        call    read_tok
        cmp     byte [tok1], 0
        je      .none
        mov     al, [tok1]
        and     al, 0DFh
        mov     ah, [tok1+1]
        or      ah, ah
        jnz     .twochar
        cmp     al, 'L'
        je      .islist
        cmp     al, 'X'
        je      .isextract
        jmp     .firstfile
.twochar:
        cmp     byte [tok1+2], 0
        jne     .firstfile
        and     ah, 0DFh
        cmp     al, 'X'
        jne     .firstfile
        cmp     ah, 'A'
        jne     .firstfile
        mov     byte [xallmode], 1
        call    skip_sp
        mov     di, fname
        call    read_tok
        call    skip_sp
        mov     di, destdir
        call    read_tok
        ret
.islist:
        mov     byte [lmode], 1
        call    skip_sp
        mov     di, fname
        call    read_tok
        ret
.isextract:
        mov     byte [xmode], 1
        call    skip_sp
        mov     di, fname
        call    read_tok
        call    skip_sp
        call    read_dec
        mov     [xindex], ax
        call    skip_sp
        mov     di, destdir
        call    read_tok
        ret
.firstfile:
        mov     si, tok1
        mov     di, fname
.cp:
        mov     al, [si]
        mov     [di], al
        or      al, al
        jz      .d
        inc     si
        inc     di
        jmp     .cp
.d:
        ret
.none:
        mov     byte [fname], 0
        ret

read_dec:
        xor     ax, ax
        xor     ch, ch
.d:
        mov     cl, [si]
        cmp     cl, '0'
        jb      .e
        cmp     cl, '9'
        ja      .e
        sub     cl, '0'
        mov     bx, 10
        push    dx
        mul     bx
        pop     dx
        add     ax, cx
        inc     si
        jmp     .d
.e:
        ret

skip_sp:
        cmp     byte [si], ' '
        jne     .d
        inc     si
        jmp     skip_sp
.d:     ret

read_tok:
        mov     al, [si]
        or      al, al
        jz      .d
        cmp     al, ' '
        je      .d
        mov     [di], al
        inc     si
        inc     di
        jmp     read_tok
.d:     mov     byte [di], 0
        ret

; ============================================================================
s_usage     db 'Usage: CCARJ <a.arj>',0Dh,0Ah,0
s_noopen    db 'CCARJ: cannot open archive',0Dh,0Ah,0

HBUF_SZ     equ 512

section .bss
align 2
lmode       resb 1
xmode       resb 1
xallmode    resb 1
fname       resb 128
destdir     resb 128
tok1        resb 128
xindex      resw 1
fh          resw 1
ofh         resw 1
filei       resw 1
hsize       resw 1
hiq         resw 1
rem         resd 1
wbuf        resw 1
numtmp      resb 16
namebuf     resb 16
linebuf     resb 64
outpath     resb 160
hbuf        resb HBUF_SZ
datbuf      resb 4096
stackspace  resb 1024
stacktop:
