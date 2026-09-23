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
;  Basic-header fields used: +0 first_hdr_size, +5 method(0=stored), +6
;  file_type, +12 compressed size (dword), +16 original size (dword), and the
;  filename (NUL-terminated) at +first_hdr_size (30, or more with extra data).
;
;  Extracted files get the member's BASE name mapped to 8.3 and are created
;  with INT 21h/5Bh (never overwrite); a clash becomes NAME~1..NAME~9.
;  Exit code: 0 ok; 1 on a bad/corrupt archive (walk stops), a member not
;  extracted (compressed / X index not found), or any I/O error (the partial
;  output file is deleted).
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
        mov     al, [xmode]         ; exit code: X starts "failed" until the
        mov     [rc], al            ; requested member is really extracted
        cmp     byte [fname], 0
        je      .usage
        mov     ax, 3D00h
        mov     dx, fname
        int     21h
        jc      .noopen
        mov     [fh], ax
        call    parse_main          ; consume the archive header (no data)
        jc      .nomain
        call    files_loop
.close:
        mov     bx, [fh]
        mov     ah, 3Eh
        int     21h
        mov     al, [rc]            ; 0 ok / 1 corrupt, skipped or not found
        mov     ah, 4Ch
        int     21h
.nomain:
        mov     byte [rc], 1        ; not an ARJ archive
        jmp     .close
.usage:
        mov     si, s_usage
        jmp     fatal
.noopen:
        mov     si, s_noopen
fatal:
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
; CF=1 if the file does not start with an ARJ main header.
parse_main:
        mov     cx, 2
        mov     dx, wbuf
        call    read_n
        cmp     ax, 2
        jne     .bad
        cmp     word [wbuf], 0EA60h ; magic 0x60 0xEA
        jne     .bad
        mov     cx, 2
        mov     dx, wbuf
        call    read_n
        cmp     ax, 2
        jne     .bad
        mov     ax, [wbuf]          ; basic header size
        or      ax, ax
        jz      .bad
        xor     dx, dx
        call    skip32              ; skip the main header body
        mov     ax, 4
        xor     dx, dx
        call    skip32              ; skip its CRC
        call    skip_ext
        clc
        ret
.bad:
        stc
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
        ja      .bad                ; corrupt / oversized header
        mov     cx, ax
        mov     dx, hbuf
        call    read_n
        jc      .bad
        cmp     ax, [hsize]
        jne     .bad                ; header cut short -> fields are garbage
        mov     bx, ax
        mov     byte [hbuf+bx], 0   ; the name field always ends in a NUL
        mov     al, [hbuf]          ; first_hdr_size = where the name starts
        cmp     al, 30
        jb      .bad                ; too small to hold the fixed fields
        xor     ah, ah
        cmp     ax, bx
        jae     .bad                ; name would start past the header
        test    byte [hbuf+15], 80h ; compressed size >= 2 GB: a relative seek
        jnz     .bad                ; by it goes BACKWARDS -> endless walk
        mov     ax, 4
        xor     dx, dx
        call    skip32              ; header CRC
        call    skip_ext
        call    on_file             ; lists/extracts; leaves us at next block
        jmp     .next
.bad:
        mov     byte [rc], 1        ; corrupt chain: stop, report via exit code
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
        jc      .inc                ; compressed: rc stays 1
        mov     byte [rc], 0
        jmp     .inc
.skip:
        call    skip_data
        jmp     .inc
.xa:
        call    do_extract
        jnc     .inc
        mov     byte [rc], 1        ; a member could not be extracted
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
        call    extract_stored      ; exits the program on any I/O failure
        clc
        ret
.skip:
        call    skip_data
        stc
        ret

; skip the compressed data (advance to the next block)
skip_data:
        mov     ax, [hbuf+12]
        mov     dx, [hbuf+14]
        call    skip32
        ret

; copy [hbuf+12] (compressed size) bytes verbatim into a NEW
; <destdir>\<dosname>. Any read/write failure deletes the partial file and
; exits with code 1.
extract_stored:
        call    create_out
        mov     si, s_ecreate
        jc      fatal
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
        mov     si, s_eread
        jc      .kill
        or      ax, ax
        jz      .kill               ; archive ends inside the member
        mov     cx, ax
        sub     [rem], ax           ; count bytes READ, never bytes written
        sbb     word [rem+2], 0
        mov     bx, [ofh]
        mov     ah, 40h
        mov     dx, datbuf
        int     21h
        mov     si, s_ewrite
        jc      .kill
        cmp     ax, cx
        jne     .kill               ; short write = disk full
        jmp     .cl
.close:
        mov     bx, [ofh]
        mov     ah, 3Eh
        int     21h
        ret
.kill:
        mov     bx, [ofh]           ; close + delete the partial file, exit 1
        mov     ah, 3Eh
        int     21h
        mov     ah, 41h
        mov     dx, outpath
        int     21h
        jmp     fatal

; hbuf filename (at first_hdr_size, NUL-terminated, may carry a path) ->
; namebuf = the base name, spaces/controls -> '_', capped to 12 chars (the L
; listing name); and dosname = the same base name mapped to a valid 8.3 name
; (the file X/XA actually create -- never a path, so nothing can land outside
; <destdir>).
set_basename:
        mov     si, hbuf
        mov     al, [si]            ; first_hdr_size (checked 30..hsize-1)
        xor     ah, ah
        add     si, ax
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
        push    bx
        mov     cx, si              ; si = the terminating NUL
        sub     cx, bx
        mov     si, bx
        call    make83
        pop     si                  ; si = base name start
        mov     di, namebuf
        mov     cx, 12
.cc:
        mov     al, [si]
        or      al, al
        jz      .cdone
        jcxz    .cdone
        cmp     al, ' '
        ja      .keep               ; space / control (CR, LF...) -> '_'
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
        mov     [onam], di          ; where the file name starts
        mov     si, dosname
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

; si -> member base name, cx bytes (stops at a NUL) -> dosname = a valid 8.3
; name: base = the part before the LAST '.', first 8 chars; ext = first 3
; after it; bad chars -> '_'. [dblen] = base length (for NAME~n on a clash).
make83:
        mov     bx, si
        add     bx, cx              ; bx = end
        mov     di, si
        xor     dx, dx              ; dx = last '.' (0 = none)
.f:
        cmp     di, bx
        jae     .fe
        mov     al, [di]
        or      al, al
        jz      .fnul
        cmp     al, '.'
        jne     .fn
        mov     dx, di
.fn:
        inc     di
        jmp     .f
.fnul:
        mov     bx, di              ; name ends at the NUL
.fe:
        or      dx, dx
        jnz     .hd
        mov     dx, bx              ; no dot: the base runs to the end
.hd:
        mov     di, dosname
        mov     cx, 8
.b:
        cmp     si, dx
        jae     .be
        jcxz    .be
        lodsb
        call    dos_char
        stosb
        dec     cx
        jmp     .b
.be:
        cmp     di, dosname
        jne     .bok
        mov     al, '_'             ; empty base (".txt", "..") -> "_"
        stosb
.bok:
        mov     ax, di
        sub     ax, dosname
        mov     [dblen], ax
        mov     si, dx
        inc     si                  ; past the '.'
        cmp     si, bx
        jae     .z                  ; no / empty extension
        mov     al, '.'
        stosb
        mov     cx, 3
.e:
        cmp     si, bx
        jae     .z
        jcxz    .z
        lodsb
        call    dos_char
        stosb
        dec     cx
        jmp     .e
.z:
        mov     byte [di], 0
        ret

; al -> '_' if it is not legal in a DOS file name (controls, space, '.' and
; "*+,/:;<=>?[\]| -- so no drive, path or ".." can survive), else unchanged.
dos_char:
        cmp     al, ' '
        jbe     .bad
        push    di
        push    cx
        mov     di, s_badch
        mov     cx, S_BADCH_N
        repne   scasb
        pop     cx
        pop     di
        jne     .ok
.bad:
        mov     al, '_'
.ok:
        ret

; create <destdir>\<dosname> as a NEW file (INT 21h/5Bh never truncates an
; existing one); on a clash (or a device name like CON/PRN) try NAME~1..~9.
; CF=0 -> [ofh] = handle, outpath = the name used; CF=1 -> nothing created.
create_out:
        call    build_outpath
        mov     byte [try], '0'
.try:
        mov     ah, 5Bh
        xor     cx, cx
        mov     dx, outpath
        int     21h
        jc      .next
        mov     [ofh], ax
        mov     bx, ax
        mov     ax, 4400h           ; IOCTL: is this handle a character device?
        int     21h
        test    dl, 80h             ; (also clears CF)
        jz      .ret
        mov     ah, 3Eh             ; a device, not a file: close, rename
        int     21h
.next:
        inc     byte [try]
        cmp     byte [try], '9'
        ja      .fail
        mov     di, [onam]          ; name = base[0..min(len,6)) + '~' + digit
        mov     ax, [dblen]
        cmp     ax, 6
        jbe     .l6
        mov     ax, 6
.l6:
        add     di, ax
        mov     al, '~'
        stosb
        mov     al, [try]
        stosb
        mov     si, dosname         ; + the ".EXT" (and NUL) unchanged
        add     si, [dblen]
.ce:
        lodsb
        stosb
        or      al, al
        jnz     .ce
        jmp     .try
.fail:
        stc
.ret:
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
s_ecreate   db 'CCARJ: cannot create output file',0Dh,0Ah,0
s_eread     db 'CCARJ: read error / truncated archive',0Dh,0Ah,0
s_ewrite    db 'CCARJ: write error (disk full?)',0Dh,0Ah,0
s_badch     db '."*+,/:;<=>?[\]|', 7Fh
S_BADCH_N   equ $ - s_badch

HBUF_SZ     equ 512

section .bss
align 2
lmode       resb 1
xmode       resb 1
xallmode    resb 1
rc          resb 1
try         resb 1
fname       resb 128
destdir     resb 128
tok1        resb 128
xindex      resw 1
fh          resw 1
ofh         resw 1
filei       resw 1
hsize       resw 1
hiq         resw 1
onam        resw 1
dblen       resw 1
rem         resd 1
wbuf        resw 1
numtmp      resb 16
namebuf     resb 16
dosname     resb 16
linebuf     resb 64
outpath     resb 160
hbuf        resb HBUF_SZ+1          ; +1: room for the forced name NUL
datbuf      resb 4096
stackspace  resb 1024
stacktop:
