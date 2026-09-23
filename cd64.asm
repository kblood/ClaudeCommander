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
;  Every track/sector link is range-checked and each chain carries a visited
;  bitmap, so corrupt/cyclic images terminate.  X and XA never overwrite: a
;  name clash becomes BASE~1.PRG..BASE~9.PRG.  Exit code 1 on any failure.
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
        mov     byte [failed], 0
        mov     byte [xdone], 0
        call    parse_args
        cmp     byte [fname], 0
        je      .usage
        mov     ax, 3D00h
        mov     dx, fname
        int     21h
        jc      .noopen
        mov     [fh], ax
        ; image size picks the track count: >= 196608 bytes => 40 tracks
        mov     bx, ax
        mov     ax, 4202h
        xor     cx, cx
        xor     dx, dx
        int     21h
        mov     byte [maxtrk], 35
        cmp     dx, 3               ; 30000h = 196608
        jb      .t35
        mov     byte [maxtrk], 40
.t35:
        call    dirwalk
        mov     bx, [fh]
        mov     ah, 3Eh
        int     21h
        cmp     byte [xmode], 0     ; X for a member that is not there
        je      .fin
        cmp     byte [xdone], 0
        jne     .fin
        mov     byte [failed], 1
.fin:
        mov     al, [failed]        ; 0 = ok, 1 = something failed
        mov     ah, 4Ch
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
; track(al)/sector(ah) -> AX = absolute sector index (0..767).
; CF=1 when the track is outside 1..maxtrk or the sector is past that track's
; last one (a corrupt link must never address a stale or foreign sector).
ts_index:
        push    bx
        push    cx
        push    dx
        movzx   cx, ah              ; sector
        movzx   dx, al              ; track
        or      dx, dx
        jz      .bad
        cmp     dl, [maxtrk]
        ja      .bad
        call    spt                 ; bx = sectors on this track
        cmp     cx, bx
        jae     .bad
        mov     ax, cx
.lp:
        dec     dx                  ; add every earlier track's sectors
        jz      .ok
        call    spt
        add     ax, bx
        jmp     .lp
.ok:
        clc
        jmp     .r
.bad:
        stc
.r:
        pop     dx
        pop     cx
        pop     bx
        ret

; dx = track -> bx = sectors on it (21 / 19 / 18 / 17 for tracks 31..40)
spt:
        mov     bx, 21
        cmp     dx, 17
        jbe     .r
        mov     bx, 19
        cmp     dx, 24
        jbe     .r
        mov     bx, 18
        cmp     dx, 30
        jbe     .r
        mov     bx, 17
.r:
        ret

; read the sector named by rs_t/rs_s into [rs_buf], marking it in the chain's
; visited bitmap [rs_map].  CF=1 on a bad track/sector, a sector this chain
; already visited (cycle), a DOS error or a short read (truncated image).
read_sector:
        mov     al, [rs_t]
        mov     ah, [rs_s]
        call    ts_index
        jc      .ret
        mov     bx, ax
        shr     bx, 3
        add     bx, [rs_map]
        mov     cl, al
        and     cl, 7
        mov     ch, 1
        shl     ch, cl
        test    [bx], ch
        jnz     .bad                ; cycle
        or      [bx], ch
        mov     cx, ax
        shr     cx, 8
        mov     dx, ax
        shl     dx, 8               ; CX:DX = index * 256
        mov     bx, [fh]
        mov     ax, 4200h
        int     21h
        jc      .ret
        mov     bx, [fh]
        mov     ah, 3Fh
        mov     cx, 256
        mov     dx, [rs_buf]
        int     21h
        jc      .ret
        cmp     ax, 256             ; equal => CF=0
        je      .ret
.bad:
        stc
.ret:
        ret

; di = 96-byte bitmap (768 sectors) -> zeroed
clr_map:
        mov     [rs_map], di
        mov     cx, 96
        xor     al, al
        rep     stosb
        ret

; ----------------------------------------------------------------------------
; walk the directory chain (track 18, sector 1 ...), dispatching each file
; entry by mode (list / extract-one / extract-all).
; A bad/cyclic link or a short read ends the walk (and sets failed); the
; visited bitmap bounds it at 768 sectors.
dirwalk:
        mov     word [filei], 0
        mov     byte [rs_t], 18
        mov     byte [rs_s], 1
        mov     di, dirmap
        call    clr_map
.sloop:
        mov     word [rs_buf], secbuf
        mov     word [rs_map], dirmap
        call    read_sector
        jnc     .rd
        mov     byte [failed], 1
        ret
.rd:
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
        mov     byte [xdone], 1
        call    extract_file
        jmp     .inc
.xa:
        call    extract_file
.inc:
        inc     word [filei]
        ret

; si = entry; namebuf already built. Follow the sector chain into the file.
; X and XA both create new-only and rename on a clash (never overwrite).
; A bad/cyclic chain deletes the partial file and sets failed (XA goes on
; with the next file); a failed create or write is fatal: delete, exit 1.
extract_file:
        mov     al, [si+3]
        mov     [ex_t], al
        mov     al, [si+4]
        mov     [ex_s], al
        call    create_unique
        mov     si, s_nocreate
        jc      fatal
        mov     [ofh], ax
        mov     di, filemap
        call    clr_map
.cl:
        mov     al, [ex_t]
        mov     [rs_t], al
        mov     al, [ex_s]
        mov     [rs_s], al
        mov     word [rs_buf], datbuf
        mov     word [rs_map], filemap
        call    read_sector
        jc      .badchain
        mov     al, [datbuf]        ; next track (0 => last sector)
        or      al, al
        jz      .last
        mov     [ex_t], al
        mov     al, [datbuf+1]
        mov     [ex_s], al
        mov     cx, 254
        call    wr_data
        jmp     .cl
.last:
        movzx   cx, byte [datbuf+1] ; index of last valid byte
        sub     cx, 1               ; => data byte count
        jbe     .close
        call    wr_data
.close:
        mov     bx, [ofh]
        mov     ah, 3Eh
        int     21h
        ret
.badchain:
        call    kill_out
        mov     si, s_badchain
        call    puts
        mov     byte [failed], 1
        ret

; write cx bytes from datbuf+2 to the output; a DOS error or short write
; (disk full) is fatal.
wr_data:
        mov     dx, datbuf+2
        mov     bx, [ofh]
        mov     ah, 40h
        int     21h
        jc      .bad
        cmp     ax, cx
        je      .ok
.bad:
        call    kill_out
        mov     si, s_wrerr
        jmp     fatal
.ok:
        ret

; close + delete the partial output file
kill_out:
        mov     bx, [ofh]
        mov     ah, 3Eh
        int     21h
        mov     ah, 41h
        mov     dx, outpath
        int     21h
        ret

; si = message -> print it, exit 1
fatal:
        call    puts
        mov     ax, 4C01h
        int     21h

; X/XA: create outpath new-only (5Bh). If that fails (name taken -- two C64
; names that map to one 8.3 name, or a file already there) or the name is a
; character device (CON.PRG...), retry as BASE~1.PRG .. BASE~9.PRG (base cut
; to 6 chars). CF=1 if all ten fail.
create_unique:
        mov     byte [tries], '0'
.try:
        call    build_outpath
        mov     ah, 5Bh
        xor     cx, cx
        mov     dx, outpath
        int     21h
        jc      .next
        mov     bx, ax
        push    ax
        mov     ax, 4400h           ; IOCTL: is this handle a character device?
        int     21h
        pop     ax
        test    dl, 80h             ; (also clears CF)
        jz      .ret
        mov     ah, 3Eh             ; a device, not a file: close, rename
        int     21h
.next:
        inc     byte [tries]
        cmp     byte [tries], '9'
        ja      .fail
        mov     bl, [baselen]
        cmp     bl, 6
        jbe     .b
        mov     bl, 6
.b:
        xor     bh, bh
        mov     byte [namebuf+bx], '~'
        mov     al, [tries]
        mov     [namebuf+bx+1], al
        mov     word [namebuf+bx+2], '.P'
        mov     word [namebuf+bx+4], 'RG'
        mov     byte [namebuf+bx+6], 0
        jmp     .try
.fail:
        stc
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
        cmp     di, namebuf         ; never emit an empty base name
        jne     .hn
        mov     byte [di], 'F'
        inc     di
.hn:
        mov     ax, di
        sub     ax, namebuf
        mov     [baselen], al       ; 1..8, for create_unique
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
s_nocreate  db 'CCD64: cannot create output file',0Dh,0Ah,0
s_wrerr     db 'CCD64: write error (disk full?)',0Dh,0Ah,0
s_badchain  db 'CCD64: bad sector chain, file skipped',0Dh,0Ah,0

section .bss
align 2
lmode       resb 1
xmode       resb 1
xallmode    resb 1
failed      resb 1
xdone       resb 1
maxtrk      resb 1
tries       resb 1
baselen     resb 1
fname       resb 128
destdir     resb 128
tok1        resb 128
xindex      resw 1
fh          resw 1
ofh         resw 1
filei       resw 1
rs_buf      resw 1
rs_map      resw 1
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
dirmap      resb 96                 ; visited bitmaps, 1 bit per sector (768)
filemap     resb 96
stackspace  resb 1024
stacktop:
