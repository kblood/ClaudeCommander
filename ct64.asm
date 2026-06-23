; ============================================================================
;  CCT64.COM  --  Claude Commander's C64 tape-archive (.T64) plugin
;
;  Usage:  CCT64 <img.t64>            human listing (size / name)
;          CCT64 L  <img.t64>         machine listing for cc: "<size> <name>"
;          CCT64 X  <img.t64> <n> <d> extract file #n (L order) to dir <d>
;          CCT64 XA <img.t64> <d>     extract every file to dir <d>
;
;  A T64 is a flat container: a 64-byte header, then `max-entries` 32-byte
;  directory records, then file data referenced by absolute offsets.
;    header +32 ver, +34 max-entries, +36 used-entries, +40 container name
;    record +0 type(0=free), +1 c64type, +2 load-addr, +4 end-addr,
;           +8 data-offset(dword), +16 name(16 PETSCII, space-padded)
;  Unlike a real tape, T64 data does NOT carry the 2-byte load address, so
;  extracted files get the header's load address prepended -> valid .PRG.
;  A common bug is a wrong end-addr; we clamp the length to end-of-file.
;
;  Layer-3 helper: cc's [open] map (t64=CCT64) makes it browsable like ZIP.
;  Assemble:  nasm -f bin ct64.asm -o cct64.com
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
        ; file size -> filesz (DX:AX) via seek-to-end
        mov     bx, ax
        mov     ax, 4202h
        xor     cx, cx
        xor     dx, dx
        int     21h
        mov     [filesz], ax
        mov     [filesz+2], dx
        ; read the 64-byte header
        mov     bx, [fh]
        mov     ax, 4200h
        xor     cx, cx
        xor     dx, dx
        int     21h
        mov     bx, [fh]
        mov     ah, 3Fh
        mov     cx, 64
        mov     dx, hdr
        int     21h
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
; read the 32-byte directory record #(ax) into [ebuf]
read_entry:
        push    ax
        mov     cx, 32
        mul     cx                  ; dx:ax = index*32
        add     ax, 64
        adc     dx, 0
        mov     cx, dx
        mov     dx, ax
        mov     bx, [fh]
        mov     ax, 4200h
        int     21h
        mov     bx, [fh]
        mov     ah, 3Fh
        mov     cx, 32
        mov     dx, ebuf
        int     21h
        pop     ax
        ret

; ----------------------------------------------------------------------------
; walk the directory, dispatching each used record by mode.
dirwalk:
        mov     word [filei], 0
        mov     ax, [hdr+34]        ; max entries
        or      ax, ax
        jnz     .havemax
        mov     ax, [hdr+36]        ; fall back to used count
        or      ax, ax
        jnz     .havemax
        mov     ax, 1
.havemax:
        cmp     ax, 1000            ; sanity cap
        jbe     .cap
        mov     ax, 1000
.cap:
        mov     [nscan], ax
        mov     word [idx], 0
.loop:
        mov     ax, [idx]
        cmp     ax, [nscan]
        jae     .done
        call    read_entry
        mov     al, [ebuf]          ; record type (0 = free slot)
        or      al, al
        jz      .next
        call    on_file
.next:
        inc     word [idx]
        jmp     .loop
.done:
        ret

; current record in [ebuf]: build the name, then act on the mode.
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

; length of the current record's file = end-addr - load-addr, clamped to the
; bytes actually present (filesz - data-offset). Result in [flen] (word).
calc_len:
        mov     ax, [ebuf+4]        ; end address
        sub     ax, [ebuf+2]        ; - load address
        mov     [flen], ax
        ; avail32 = filesz - dataoff
        mov     ax, [filesz]
        mov     dx, [filesz+2]
        sub     ax, [ebuf+8]
        sbb     dx, [ebuf+10]
        ; if high word != 0, >=64K available -> no clamp needed
        or      dx, dx
        jnz     .ret
        cmp     ax, [flen]          ; avail < len ?
        jae     .ret
        mov     [flen], ax          ; clamp
.ret:
        ret

; extract the current record: prepend the load address, copy [flen] bytes
; from the data offset.
extract_file:
        call    calc_len
        call    build_outpath
        mov     ah, 3Ch
        xor     cx, cx
        mov     dx, outpath
        int     21h
        jc      .ret
        mov     [ofh], ax
        ; write the 2-byte load address (turns raw data into a .PRG)
        mov     ax, [ebuf+2]
        mov     [ldaddr], ax
        mov     bx, [ofh]
        mov     ah, 40h
        mov     cx, 2
        mov     dx, ldaddr
        int     21h
        ; seek input to the data offset
        mov     bx, [fh]
        mov     ax, 4200h
        mov     cx, [ebuf+10]
        mov     dx, [ebuf+8]
        int     21h
        mov     ax, [flen]
        mov     [rem], ax
.cl:
        mov     ax, [rem]
        or      ax, ax
        jz      .close
        mov     cx, 4096
        cmp     ax, cx
        jae     .rd
        mov     cx, ax
.rd:
        mov     bx, [fh]
        mov     ah, 3Fh
        mov     dx, datbuf
        int     21h                 ; ax = bytes read
        or      ax, ax
        jz      .close
        mov     cx, ax
        sub     [rem], ax
        mov     bx, [ofh]
        mov     ah, 40h
        mov     dx, datbuf
        int     21h
        jmp     .cl
.close:
        mov     bx, [ofh]
        mov     ah, 3Eh
        int     21h
.ret:
        ret

; current record in [ebuf] -> namebuf = up to 8 sanitised chars + ".PRG" + NUL
build_name:
        mov     si, ebuf+16         ; 16-byte name field
        mov     di, namebuf
        mov     cx, 8
.l:
        jcxz    .dot
        mov     al, [si]
        cmp     al, ' '             ; space pad / terminator
        je      .dot
        or      al, al
        je      .dot
        cmp     al, 0A0h            ; some tools pad with 0xA0
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
        mov     byte [di], '.'
        mov     byte [di+1], 'P'
        mov     byte [di+2], 'R'
        mov     byte [di+3], 'G'
        mov     byte [di+4], 0
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

; current record -> stdout "<flen+2> <namebuf>\r\n"
emit_listing:
        call    calc_len
        mov     ax, [flen]
        add     ax, 2               ; PRG includes the 2-byte load address
        xor     dx, dx
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
s_usage     db 'Usage: CCT64 <img.t64>',0Dh,0Ah,0
s_noopen    db 'CCT64: cannot open image',0Dh,0Ah,0

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
idx         resw 1
nscan       resw 1
flen        resw 1
rem         resw 1
hiq         resw 1
ldaddr      resw 1
filesz      resd 1
numtmp      resb 16
namebuf     resb 16
linebuf     resb 64
outpath     resb 160
hdr         resb 64
ebuf        resb 32
datbuf      resb 4096
stackspace  resb 1024
stacktop:
