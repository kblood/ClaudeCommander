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
        mov     ax, 4C00h
        int     21h
.usage:
        mov     si, s_usage
        jmp     .die
.noopen:
        mov     si, s_noopen
        jmp     .die
.badfmt:
        mov     si, s_badfmt
        jmp     .die
.rar5:
        mov     si, s_rar5
.die:
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
        mov     cx, 7
        mov     dx, bbuf
        call    read_n
        cmp     ax, 7
        jne     .done               ; EOF / no more blocks
        mov     ax, [bbuf+3]
        mov     [flags], ax
        mov     ax, [bbuf+5]
        mov     [hsize], ax
        cmp     ax, 7
        jb      .done               ; corrupt
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

do_extract:
        cmp     byte [bbuf+25], 30h ; METHOD 0x30 = stored
        jne     .skip
        test    word [flags], 0004h ; password-protected
        jnz     .skip
        call    extract_stored
        ret
.skip:
        call    skip_data
        ret

skip_data:
        mov     ax, [adds]
        mov     dx, [adds+2]
        call    skip32
        ret

; copy ADD_SIZE (PACK_SIZE) bytes verbatim into <destdir>\<namebuf>
extract_stored:
        call    build_outpath
        mov     ah, 3Ch
        xor     cx, cx
        mov     dx, outpath
        int     21h
        jc      .skipd
        mov     [ofh], ax
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
        or      ax, ax
        jz      .close
        mov     cx, ax
        mov     bx, [ofh]
        mov     ah, 40h
        mov     dx, datbuf
        int     21h
        mov     bx, ax
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

; FILE_HEAD name (NAME_SIZE @+26, bytes at +32 / +40 if LARGE) -> namebuf:
; base name only, spaces -> '_', capped to 12.
set_name:
        mov     si, bbuf+32         ; name offset, no LARGE fields
        test    word [flags], 0100h ; LARGE -> 8 bytes of high sizes precede
        jz      .haveoff
        mov     si, bbuf+40
.haveoff:
        mov     cx, [bbuf+26]       ; NAME_SIZE
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
        mov     si, bx
        mov     bx, di              ; bx = name end
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

BBUF_SZ     equ 1024

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
flags       resw 1
hiq         resw 1
adds        resd 1
rem         resd 1
numtmp      resb 16
namebuf     resb 16
linebuf     resb 64
outpath     resb 160
bbuf        resb BBUF_SZ
datbuf      resb 4096
stackspace  resb 1024
stacktop:
