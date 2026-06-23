; ============================================================================
;  CCD64.COM  --  Claude Commander's C64 1541 disk-image (.D64) plugin
;
;  Usage:  CCD64 <img.d64>            human listing (size / name)
;          CCD64 L  <img.d64>         machine listing for cc: "<size> <name>"
;          CCD64 X  <img.d64> <n> <d> extract file #n (L order) to dir <d>
;          CCD64 XA <img.d64> <d>     extract every file to dir <d>
;
;  A D64 is 683 sectors of 256 bytes (35 tracks).  The directory lives on
;  track 18: sector 1 onward is a chain of 8-entry sectors.  Each file's data
;  is a sector chain; non-final sectors hold 254 data bytes (offset 2..255),
;  the final sector's byte 1 is the index of its last valid byte.  Extracted
;  files keep their 2-byte load address, i.e. they are .PRG images.
;
;  This is a Layer-3 helper: cc's [open] map (d64=CCD64) makes it browsable
;  exactly like the ZIP plugin -- Enter to browse, F5 to extract, Alt-F9 all.
;
;  Assemble:  nasm -f bin cd64.asm -o ccd64.com
; ============================================================================
        org     100h

start:
        cld
        mov     sp, stacktop
        mov     byte [lmode], 0     ; .bss is not cleared for a .COM and we
        mov     byte [xmode], 0     ; reload at the same address each run, so
        mov     byte [xallmode], 0  ; stale flags must be zeroed (see CCZIP)
        mov     byte [fname], 0
        call    parse_args
        cmp     byte [fname], 0
        je      .usage
        mov     ax, 3D00h
        mov     dx, fname
        int     21h
        jc      .noopen
        mov     [fh], ax
        call    dirwalk
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
; track(al,1..35)/sector(ah) -> DX:AX byte offset into the image
ts_offset:
        push    bx
        push    cx
        movzx   bx, al              ; track
        movzx   cx, ah              ; sector
        xor     ax, ax              ; sectors before this track
        mov     dx, 1               ; track counter
.lp:
        cmp     dx, bx
        jae     .done
        push    bx
        mov     bx, 21              ; tracks 1..17 : 21 sectors
        cmp     dx, 17
        jbe     .ad
        mov     bx, 19              ; tracks 18..24: 19
        cmp     dx, 24
        jbe     .ad
        mov     bx, 18              ; tracks 25..30: 18
        cmp     dx, 30
        jbe     .ad
        mov     bx, 17              ; tracks 31..35: 17
.ad:
        add     ax, bx
        pop     bx
        inc     dx
        jmp     .lp
.done:
        add     ax, cx              ; absolute sector index
        mov     dx, ax
        shr     dx, 8
        shl     ax, 8               ; DX:AX = index * 256
        pop     cx
        pop     bx
        ret

; read the sector named by rs_t/rs_s into [rs_buf]
read_sector:
        mov     al, [rs_t]
        mov     ah, [rs_s]
        call    ts_offset
        mov     cx, dx
        mov     dx, ax
        mov     bx, [fh]
        mov     ax, 4200h
        int     21h
        mov     bx, [fh]
        mov     ah, 3Fh
        mov     cx, 256
        mov     dx, [rs_buf]
        int     21h
        ret

; ----------------------------------------------------------------------------
; walk the directory chain (track 18, sector 1 ...), dispatching each file
; entry by mode (list / extract-one / extract-all).
dirwalk:
        mov     word [filei], 0
        mov     byte [rs_t], 18
        mov     byte [rs_s], 1
        mov     word [guard], 0
.sloop:
        mov     word [rs_buf], secbuf
        call    read_sector
        mov     al, [secbuf]        ; next dir track
        mov     [nxt_t], al
        mov     al, [secbuf+1]      ; next dir sector
        mov     [nxt_s], al
        xor     bx, bx              ; entry 0..7
.eloop:
        mov     si, bx
        shl     si, 5               ; *32
        add     si, secbuf
        mov     al, [si+2]          ; file type
        and     al, 0Fh
        jz      .next               ; DEL / empty slot
        cmp     al, 5
        ja      .next
        mov     al, [si+3]          ; first data track
        or      al, al
        jz      .next
        push    bx
        call    on_file
        pop     bx
.next:
        inc     bx
        cmp     bx, 8
        jb      .eloop
        mov     al, [nxt_t]
        or      al, al
        jz      .done
        mov     [rs_t], al
        mov     al, [nxt_s]
        mov     [rs_s], al
        inc     word [guard]
        cmp     word [guard], 40
        jae     .done
        jmp     .sloop
.done:
        ret

; si = directory entry. Build its name, then act on the current mode.
on_file:
        call    build_name
        cmp     byte [xmode], 0
        jne     .x
        cmp     byte [xallmode], 0
        jne     .xa
        call    emit_listing
        jmp     .inc
.x:
        mov     ax, [filei]
        cmp     ax, [xindex]
        jne     .inc
        call    extract_file
        jmp     .inc
.xa:
        call    extract_file
.inc:
        inc     word [filei]
        ret

; si = entry; namebuf already built. Follow the sector chain into the file.
extract_file:
        mov     al, [si+3]
        mov     [ex_t], al
        mov     al, [si+4]
        mov     [ex_s], al
        call    build_outpath
        mov     ah, 3Ch
        xor     cx, cx
        mov     dx, outpath
        int     21h
        jc      .ret
        mov     [ofh], ax
        mov     word [chain], 0
.cl:
        mov     al, [ex_t]
        mov     [rs_t], al
        mov     al, [ex_s]
        mov     [rs_s], al
        mov     word [rs_buf], datbuf
        call    read_sector
        mov     al, [datbuf]        ; next track (0 => last sector)
        or      al, al
        jz      .last
        mov     [ex_t], al
        mov     al, [datbuf+1]
        mov     [ex_s], al
        mov     cx, 254
        mov     dx, datbuf
        add     dx, 2
        mov     bx, [ofh]
        mov     ah, 40h
        int     21h
        inc     word [chain]
        cmp     word [chain], 700
        jae     .close
        jmp     .cl
.last:
        movzx   cx, byte [datbuf+1] ; index of last valid byte
        sub     cx, 1               ; => data byte count
        jbe     .close
        mov     dx, datbuf
        add     dx, 2
        mov     bx, [ofh]
        mov     ah, 40h
        int     21h
.close:
        mov     bx, [ofh]
        mov     ah, 3Eh
        int     21h
.ret:
        ret

; si = entry -> namebuf = up to 8 sanitised chars + ".PRG" + NUL
build_name:
        push    si
        lea     si, [si+5]          ; 16-byte filename field
        mov     di, namebuf
        mov     cx, 8
.l:
        jcxz    .dot
        mov     al, [si]
        cmp     al, 0A0h            ; pad
        je      .dot
        or      al, al
        je      .dot
        cmp     al, 'A'
        jb      .nz
        cmp     al, 'Z'
        jbe     .ok
.nz:
        cmp     al, '0'
        jb      .us
        cmp     al, '9'
        jbe     .ok
.us:
        mov     al, '_'             ; keep names space-free for cc's parser
.ok:
        mov     [di], al
        inc     di
        inc     si
        dec     cx
        jmp     .l
.dot:
        mov     byte [di], '.'
        mov     byte [di+1], 'P'
        mov     byte [di+2], 'R'
        mov     byte [di+3], 'G'
        mov     byte [di+4], 0
        pop     si
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

; si = entry -> stdout "<blocks*254> <namebuf>\r\n"
emit_listing:
        mov     ax, [si+30]         ; file size in blocks (lo @+30, hi @+31)
        mov     bx, 254
        mul     bx                  ; DX:AX = approx byte size
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
; append ASCIIZ ds:bx at [di]; di advanced.
cat_di:
        mov     al, [bx]
        or      al, al
        jz      .d
        mov     [di], al
        inc     bx
        inc     di
        jmp     cat_di
.d:     ret

; append decimal of DX:AX at [di]; di advanced.
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
; Parse the tail.  Mode token L / X / XA selects machine listing / extract.
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
s_usage     db 'Usage: CCD64 <img.d64>',0Dh,0Ah,0
s_noopen    db 'CCD64: cannot open image',0Dh,0Ah,0

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
guard       resw 1
chain       resw 1
rs_buf      resw 1
hiq         resw 1
rs_t        resb 1
rs_s        resb 1
nxt_t       resb 1
nxt_s       resb 1
ex_t        resb 1
ex_s        resb 1
numtmp      resb 16
namebuf     resb 16
linebuf     resb 64
outpath     resb 160
secbuf      resb 256
datbuf      resb 256
stackspace  resb 1024
stacktop:
