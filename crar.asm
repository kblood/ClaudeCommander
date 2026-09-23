; ============================================================================
;  CCRAR.COM  --  Claude Commander's RAR-archive plugin (RAR 4.x / old format)
;
;  Usage:  CCRAR <a.rar>            human listing (size / name)
;          CCRAR L  <a.rar>         machine listing for cc: "<size> <name>"
;          CCRAR X  <a.rar> <n> <d> extract file #n (L order) to dir <d>
;          CCRAR XA <a.rar> <d>     extract every file to dir <d>
;
;  RAR 4.x is a chain of blocks. Each block starts with a 7-byte base header:
;     +0 HEAD_CRC(2)  +2 HEAD_TYPE(1)  +3 HEAD_FLAGS(2)  +5 HEAD_SIZE(2)
;  If HEAD_FLAGS & 0x8000 (LONG_BLOCK) a 4-byte ADD_SIZE follows at +7 = the
;  data length after the header. The archive opens with the 7-byte marker
;  block (type 0x72, "Rar!\x1a\x07\x00"); MAIN_HEAD is 0x73; FILE_HEAD is 0x74;
;  the end block is 0x7b. FILE_HEAD fields: +7 PACK_SIZE, +11 UNP_SIZE,
;  +25 METHOD (0x30 = stored), +26 NAME_SIZE, name at +32 (+40 if LARGE).
;
;  RAR's compression is proprietary, so this is browse-first: every file is
;  listed, but only METHOD 0x30 (STORED) entries are extracted byte-for-byte;
;  compressed entries are skipped on extract. RAR5 archives are detected and
;  declined. Layer-3 helper: cc's [open] map (rar=CCRAR) makes it browsable.
;
;  Extracted files get the member's BASE name mapped to 8.3 and are created
;  with INT 21h/5Bh (never overwrite); a clash becomes NAME~1..NAME~9.
;  Exit code: 0 ok; 1 on a corrupt block chain (walk stops), a member not
;  extracted (compressed / encrypted / X index not found), or any I/O error
;  (the partial output file is deleted).
;
;  Assemble:  nasm -f bin crar.asm -o ccrar.com
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
        ; validate the 7-byte marker, detect RAR5, then rewind to 0
        mov     cx, 7
        mov     dx, bbuf
        call    read_n
        cmp     ax, 7
        jne     .badfmt
        cmp     byte [bbuf], 52h    ; 'R'
        jne     .badfmt
        cmp     byte [bbuf+1], 61h  ; 'a'
        jne     .badfmt
        cmp     byte [bbuf+2], 72h  ; 'r'
        jne     .badfmt
        cmp     byte [bbuf+3], 21h  ; '!'
        jne     .badfmt
        cmp     byte [bbuf+6], 0    ; 0x00 = RAR4, 0x01 = RAR5
        jne     .rar5
        ; seek back to 0 and walk every block
        mov     bx, [fh]
        mov     ax, 4200h
        xor     cx, cx
        xor     dx, dx
        int     21h
        call    block_loop
        mov     bx, [fh]
        mov     ah, 3Eh
        int     21h
        mov     al, [rc]            ; 0 ok / 1 corrupt, skipped or not found
        mov     ah, 4Ch
        int     21h
.usage:
        mov     si, s_usage
        jmp     fatal
.noopen:
        mov     si, s_noopen
        jmp     fatal
.badfmt:
        mov     si, s_badfmt
        jmp     fatal
.rar5:
        mov     si, s_rar5
fatal:
        call    puts
        mov     ax, 4C01h
        int     21h

; ----------------------------------------------------------------------------
read_n:
        push    bx
        mov     bx, [fh]
        mov     ah, 3Fh
        int     21h
        pop     bx
        ret

; advance the file pointer by dx:ax bytes forward
skip32:
        mov     cx, dx
        mov     dx, ax
        mov     bx, [fh]
        mov     ax, 4201h
        int     21h
        ret

; ----------------------------------------------------------------------------
block_loop:
        mov     word [filei], 0
.next:
        mov     word [hend], bbuf+7
        mov     cx, 7
        mov     dx, bbuf
        call    read_n
        jc      .bad
        or      ax, ax
        jz      .done               ; EOF / no more blocks
        cmp     ax, 7
        jne     .bad                ; truncated block header
        mov     ax, [bbuf+3]
        mov     [flags], ax
        mov     ax, [bbuf+5]
        mov     [hsize], ax
        cmp     ax, 7
        jb      .bad                ; corrupt
        ; read the rest of the header (hsize-7 bytes) into bbuf+7
        mov     ax, [hsize]
        sub     ax, 7
        jz      .noext
        mov     cx, ax
        cmp     cx, BBUF_SZ-7       ; clamp the in-RAM copy; seek any overflow
        jbe     .rdhdr
        mov     cx, BBUF_SZ-7
.rdhdr:
        push    cx
        mov     dx, bbuf+7
        call    read_n
        pop     cx
        jc      .bad
        cmp     ax, cx
        jne     .bad                ; header cut short -> fields are garbage
        add     ax, bbuf+7
        mov     [hend], ax          ; end of the header bytes really in bbuf
        ; if the header was larger than our buffer, skip the remainder
        mov     ax, [hsize]
        sub     ax, 7
        sub     ax, cx
        jz      .noext
        xor     dx, dx
        call    skip32
.noext:
        ; ADD_SIZE (data after the header) if LONG_BLOCK
        xor     ax, ax
        mov     [adds], ax
        mov     [adds+2], ax
        test    word [flags], 8000h
        jz      .haveadds
        mov     ax, [bbuf+7]
        mov     [adds], ax
        mov     ax, [bbuf+9]
        mov     [adds+2], ax
        test    ah, 80h             ; >= 2 GB: a relative seek by it would go
        jnz     .bad                ; BACKWARDS and walk the chain forever
.haveadds:
        mov     al, [bbuf+2]        ; HEAD_TYPE
        cmp     al, 7Bh             ; end block
        je      .done
        cmp     al, 74h             ; file block
        je      .file
        ; any other block: skip its data and continue
        call    skip_data
        jmp     .next
.file:
        call    on_file
        jmp     .next
.bad:
        mov     byte [rc], 1        ; corrupt chain: stop, report via exit code
.done:
        ret

; a FILE_HEAD is in bbuf. Dispatch by mode; always leave the pointer at the
; next block (i.e. consume ADD_SIZE bytes of file data).
on_file:
        mov     ax, [flags]
        and     ax, 0E0h
        cmp     ax, 0E0h            ; dict==7 -> directory entry
        je      .skiponly
        call    set_name
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
        jc      .inc                ; compressed / encrypted: rc stays 1
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

do_extract:
        cmp     byte [bbuf+25], 30h ; METHOD 0x30 = stored
        jne     .skip
        test    word [flags], 0004h ; password-protected
        jnz     .skip
        call    extract_stored      ; exits the program on any I/O failure
        clc
        ret
.skip:
        call    skip_data
        stc
        ret

skip_data:
        mov     ax, [adds]
        mov     dx, [adds+2]
        call    skip32
        ret

; copy ADD_SIZE (PACK_SIZE) bytes verbatim into a NEW <destdir>\<dosname>.
; Any read/write failure deletes the partial file and exits with code 1.
extract_stored:
        call    create_out
        mov     si, s_ecreate
        jc      fatal
        mov     ax, [adds]
        mov     [rem], ax
        mov     ax, [adds+2]
        mov     [rem+2], ax
.cl:
        mov     ax, [rem]
        mov     dx, [rem+2]
        mov     cx, ax
        or      cx, dx
        jz      .close
        mov     cx, 4096
        or      dx, dx
        jnz     .rd
        cmp     ax, cx
        jae     .rd
        mov     cx, ax
.rd:
        mov     dx, datbuf
        call    read_n
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

; FILE_HEAD name (NAME_SIZE @+26, bytes at +32 / +40 if LARGE) -> namebuf:
; base name only, spaces/controls -> '_', capped to 12 (the L listing name);
; and dosname = the same base name mapped to a valid 8.3 name (the file X/XA
; actually create -- never a path, so nothing can land outside <destdir>).
set_name:
        mov     si, bbuf+32         ; name offset, no LARGE fields
        test    word [flags], 0100h ; LARGE -> 8 bytes of high sizes precede
        jz      .haveoff
        mov     si, bbuf+40
.haveoff:
        mov     cx, [bbuf+26]       ; NAME_SIZE, clamped to the header bytes read
        mov     ax, [hend]
        sub     ax, si
        jae     .avok
        xor     ax, ax
.avok:
        cmp     cx, ax
        jbe     .lenok
        mov     cx, ax
.lenok:
        ; bx scans for the last path separator within [si, si+cx)
        mov     bx, si
        mov     di, si
        add     di, cx              ; di = end of name
.scan:
        cmp     si, di
        jae     .copy
        mov     al, [si]
        cmp     al, '/'
        je      .sep
        cmp     al, '\'
        je      .sep
        inc     si
        jmp     .scan
.sep:
        inc     si
        mov     bx, si
        jmp     .scan
.copy:
        push    di
        push    bx
        mov     si, bx
        mov     cx, di
        sub     cx, bx
        call    make83
        pop     si                  ; si = base name start
        pop     bx                  ; bx = name end
        mov     di, namebuf
        mov     cx, 12
.cc:
        cmp     si, bx
        jae     .cdone
        jcxz    .cdone
        mov     al, [si]
        or      al, al
        jz      .cdone
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
        cmp     di, namebuf
        jne     .ret
        mov     byte [namebuf], 'F'
        mov     byte [namebuf+1], 'I'
        mov     byte [namebuf+2], 'L'
        mov     byte [namebuf+3], 'E'
        mov     byte [namebuf+4], 0
.ret:
        ret

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

; "<UNP_SIZE> <namebuf>\r\n" to stdout
emit_listing:
        mov     ax, [bbuf+11]
        mov     dx, [bbuf+13]
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
s_usage     db 'Usage: CCRAR <a.rar>',0Dh,0Ah,0
s_noopen    db 'CCRAR: cannot open archive',0Dh,0Ah,0
s_badfmt    db 'CCRAR: not a RAR archive',0Dh,0Ah,0
s_rar5      db 'CCRAR: RAR5 not supported',0Dh,0Ah,0
s_ecreate   db 'CCRAR: cannot create output file',0Dh,0Ah,0
s_eread     db 'CCRAR: read error / truncated archive',0Dh,0Ah,0
s_ewrite    db 'CCRAR: write error (disk full?)',0Dh,0Ah,0
s_badch     db '."*+,/:;<=>?[\]|', 7Fh
S_BADCH_N   equ $ - s_badch

BBUF_SZ     equ 1024

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
flags       resw 1
hiq         resw 1
hend        resw 1
onam        resw 1
dblen       resw 1
adds        resd 1
rem         resd 1
numtmp      resb 16
namebuf     resb 16
dosname     resb 16
linebuf     resb 64
outpath     resb 160
bbuf        resb BBUF_SZ
datbuf      resb 4096
stackspace  resb 1024
stacktop:
