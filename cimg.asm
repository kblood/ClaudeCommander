; ============================================================================
;  CCIMG.COM  --  Claude Commander's image viewer (BMP / PCX / GIF, 256-col)
;
;  Usage:  CCIMG <file>        show the image in VGA mode 13h; any key returns
;          CCIMG /D <file>     decode only -> CCIMG.RAW (test/diagnostic dump:
;                              imgw(2) imgh(2) then imgw*imgh index bytes then
;                              768 palette bytes), no mode switch
;
;  Decodes 8-bit (256-colour) images: Windows BMP (BI_RGB uncompressed), ZSoft
;  PCX (RLE, VGA palette tail) and GIF87a/89a (LZW, global or local palette,
;  interlaced or not). Images are clipped to 320x200. The decoded indices land
;  in a separate 64 KB segment (cs+0x1000), so code + tables stay in our own
;  segment. cc maps it through cc.ini [view] (gif/pcx/bmp = CCIMG).
;
;  Assemble:  nasm -f bin cimg.asm -o ccimg.com
; ============================================================================
        org     100h
start:
        cld
        mov     sp, stacktop
        mov     byte [dumpmode], 0
        mov     byte [fname], 0
        call    parse_args
        cmp     byte [fname], 0
        je      .usage
        ; image output segment = cs + 0x1000 (64 KB above our own segment)
        mov     ax, cs
        add     ax, 1000h
        mov     [img_seg], ax
        mov     ax, 3D00h
        mov     dx, fname
        int     21h
        jc      .noopen
        mov     [fh], ax
        ; total file length (PCX needs it for the palette tail)
        mov     bx, ax
        mov     ax, 4202h
        xor     cx, cx
        xor     dx, dx
        int     21h
        mov     [flen], ax
        mov     [flen+2], dx
        call    seek0               ; rewind + prime the read buffer
        mov     ax, [img_seg]
        mov     es, ax              ; es = decode target for the whole run
        ; sniff the format from the first bytes
        call    getb
        mov     [m0], al
        call    getb
        mov     [m1], al
        cmp     byte [m0], 'B'      ; 'BM' -> BMP
        jne     .npcx
        cmp     byte [m1], 'M'
        jne     .npcx
        call    seek0
        call    decode_bmp
        jmp     .decoded
.npcx:
        cmp     byte [m0], 0Ah      ; PCX manufacturer byte
        jne     .ngif
        call    seek0
        call    decode_pcx
        jmp     .decoded
.ngif:
        cmp     byte [m0], 'G'      ; 'GIF'
        jne     .badfmt
        cmp     byte [m1], 'I'
        jne     .badfmt
        call    seek0
        call    decode_gif
        jmp     .decoded
.decoded:
        mov     bx, [fh]
        mov     ah, 3Eh
        int     21h
        cmp     byte [dumpmode], 0
        jne     .dump
        call    show_image
        mov     ax, 4C00h
        int     21h
.dump:
        call    write_raw
        mov     ax, 4C00h
        int     21h
.usage:
        mov     si, s_usage
        jmp     .die
.noopen:
        mov     si, s_noopen
        jmp     .die
.badfmt:
        mov     bx, [fh]
        mov     ah, 3Eh
        int     21h
        mov     si, s_badfmt
.die:
        call    puts
        mov     ax, 4C01h
        int     21h

; ============================================================================
;  Buffered input  (sequential getb + seek that refills the buffer)
; ============================================================================
seek0:
        mov     bx, [fh]
        mov     ax, 4200h
        xor     cx, cx
        xor     dx, dx
        int     21h
        mov     word [iolen], 0
        mov     word [iopos], 0
        ret

; seek to dx:ax absolute, then force a refill
seek_set:
        mov     cx, dx
        mov     dx, ax
        mov     bx, [fh]
        mov     ax, 4200h
        int     21h
        mov     word [iolen], 0
        mov     word [iopos], 0
        ret

iorefill:
        mov     ah, 3Fh
        mov     bx, [fh]
        mov     cx, IOBUF_SZ
        mov     dx, iobuf
        int     21h
        mov     [iolen], ax
        mov     word [iopos], 0
        ret

; getb -> al = next byte, CF=1 on EOF. Preserves bx,cx,dx (iorefill/int21h
; clobber cx & dx; callers use `loop`/bx across getb, so we must restore them).
getb:
        push    bx
        push    cx
        push    dx
.again:
        mov     bx, [iopos]
        cmp     bx, [iolen]
        jb      .have
        call    iorefill
        cmp     word [iolen], 0
        je      .eof
        jmp     .again
.have:
        mov     al, [iobuf+bx]
        inc     word [iopos]
        clc
        jmp     .done
.eof:
        xor     al, al
        stc
.done:
        pop     dx
        pop     cx
        pop     bx
        ret

; getw -> ax = little-endian word
getw:
        call    getb
        mov     ah, al
        call    getb
        xchg    al, ah
        ret

; ============================================================================
;  BMP (8-bit, BI_RGB)
; ============================================================================
decode_bmp:
        ; read the 54-byte BITMAPFILEHEADER + BITMAPINFOHEADER into hdrbuf
        mov     di, hdrbuf
        mov     cx, 54
.rh:
        call    getb
        mov     [di], al
        inc     di
        loop    .rh
        mov     ax, [hdrbuf+18]     ; width (low word)
        mov     [iw], ax
        mov     ax, [hdrbuf+22]     ; height (low word, assume positive)
        mov     [ih], ax
        ; clip to 320x200
        call    clip_dims
        ; palette: clrused (or 256) entries of B,G,R,0 starting at offset 54
        mov     ax, [hdrbuf+46]     ; biClrUsed (low word)
        or      ax, ax
        jnz     .haveclr
        mov     ax, 256
.haveclr:
        cmp     ax, 256
        jbe     .clrok
        mov     ax, 256
.clrok:
        mov     cx, ax
        mov     di, pal
.pl:
        jcxz    .ploaded
        call    getb                ; B
        mov     bl, al
        call    getb                ; G
        mov     bh, al
        call    getb                ; R
        mov     [di], al            ; store R,G,B
        mov     [di+1], bh
        mov     [di+2], bl
        add     di, 3
        call    getb                ; pad byte
        dec     cx
        jmp     .pl
.ploaded:
        ; seek to the pixel data
        mov     ax, [hdrbuf+10]
        mov     dx, [hdrbuf+12]
        call    seek_set
        ; row padding to a 4-byte boundary
        mov     ax, [iw]
        and     ax, 3
        mov     bx, 4
        sub     bx, ax
        and     bx, 3
        mov     [rowpad], bx
        ; bottom-up: source scanline s -> destination row (ih-1-s)
        xor     si, si              ; si = source scanline index
.row:
        mov     ax, [ih]
        cmp     si, ax
        jae     .done
        mov     bx, ax
        dec     bx
        sub     bx, si              ; bx = destination row (top origin)
        ; read iw source bytes; store first dstw if bx < dsth
        xor     cx, cx              ; column
.col:
        mov     ax, [iw]
        cmp     cx, ax
        jae     .pad
        call    getb
        cmp     bx, [dsth]
        jae     .colnext
        cmp     cx, [dstw]
        jae     .colnext
        ; di = bx*dstw + cx
        push    ax
        mov     ax, bx
        mul     word [dstw]
        add     ax, cx
        mov     di, ax
        pop     ax
        mov     [es:di], al
.colnext:
        inc     cx
        jmp     .col
.pad:
        mov     cx, [rowpad]
        jcxz    .rownext
.pd:
        call    getb
        loop    .pd
.rownext:
        inc     si
        jmp     .row
.done:
        ret

; ============================================================================
;  PCX (8-bit, 256-colour, RLE)
; ============================================================================
decode_pcx:
        mov     di, hdrbuf          ; read the 128-byte header
        mov     cx, 128
.rh:
        call    getb
        mov     [di], al
        inc     di
        loop    .rh
        mov     ax, [hdrbuf+8]      ; xmax
        sub     ax, [hdrbuf+4]      ; - xmin
        inc     ax
        mov     [iw], ax
        mov     ax, [hdrbuf+10]     ; ymax
        sub     ax, [hdrbuf+6]      ; - ymin
        inc     ax
        mov     [ih], ax
        mov     ax, [hdrbuf+66]     ; bytes per line
        mov     [pcxbpl], ax
        call    clip_dims
        ; palette: 768 bytes at end of file (after the 0x0C marker)
        mov     ax, [flen]
        mov     dx, [flen+2]
        sub     ax, 768
        sbb     dx, 0
        call    seek_set
        mov     cx, 768
        mov     di, pal
.pp:
        call    getb
        mov     [di], al
        inc     di
        loop    .pp
        ; back to the pixel data (right after the 128-byte header)
        xor     ax, ax
        mov     [rle_rem], ax       ; no pending run
        mov     ax, 128
        xor     dx, dx
        call    seek_set
        xor     si, si              ; row
.row:
        mov     ax, [ih]
        cmp     si, ax
        jae     .done
        xor     cx, cx              ; column within the scanline (0..pcxbpl-1)
.col:
        mov     ax, [pcxbpl]
        cmp     cx, ax
        jae     .rownext
        call    pcx_byte            ; al = next decoded scanline byte
        cmp     si, [dsth]
        jae     .colnext
        cmp     cx, [dstw]
        jae     .colnext
        push    ax
        mov     ax, si
        mul     word [dstw]
        add     ax, cx
        mov     di, ax
        pop     ax
        mov     [es:di], al
.colnext:
        inc     cx
        jmp     .col
.rownext:
        inc     si
        jmp     .row
.done:
        ret

; pcx_byte -> al = next RLE-decoded byte of the current scanline
pcx_byte:
        cmp     word [rle_rem], 0
        je      .fresh
        dec     word [rle_rem]
        mov     al, [rle_val]
        ret
.fresh:
        call    getb
        mov     ah, al
        and     ah, 0C0h
        cmp     ah, 0C0h
        jne     .single
        and     al, 3Fh             ; run length (0..63)
        xor     ah, ah
        or      al, al
        jnz     .havecnt
        call    getb                ; zero-length run: drop its value byte
        jmp     .fresh
.havecnt:
        mov     [rle_rem], ax
        dec     word [rle_rem]      ; this call returns the first of the run
        call    getb
        mov     [rle_val], al
        ret
.single:
        ret

; ============================================================================
;  GIF87a / GIF89a (LZW)
; ============================================================================
decode_gif:
        mov     cx, 6               ; skip the signature "GIFxxa"
.sig:
        call    getb
        loop    .sig
        call    getw                ; logical screen width
        call    getw                ; logical screen height
        call    getb                ; packed
        mov     [gpacked], al
        call    getb                ; background index
        call    getb                ; aspect ratio
        ; global colour table?
        test    byte [gpacked], 80h
        jz      .blocks
        mov     al, [gpacked]
        and     al, 7
        call    gct_read
.blocks:
        call    getb                ; block introducer
        cmp     al, 3Bh             ; trailer
        je      .done
        cmp     al, 21h             ; extension
        je      .ext
        cmp     al, 2Ch             ; image descriptor
        je      .img
        jmp     .done               ; unknown -> stop
.ext:
        call    getb                ; extension label (ignored)
.exts:
        call    getb                ; sub-block length
        or      al, al
        jz      .blocks             ; 0 -> end of extension
        movzx   cx, al
.exd:
        call    getb
        loop    .exd
        jmp     .exts
.img:
        call    getw                ; image left
        call    getw                ; image top
        call    getw                ; image width
        mov     [iw], ax
        call    getw                ; image height
        mov     [ih], ax
        call    getb                ; image packed
        mov     [ipacked], al
        call    clip_dims
        ; local colour table overrides the global one
        test    byte [ipacked], 80h
        jz      .nolct
        mov     al, [ipacked]
        and     al, 7
        call    gct_read
.nolct:
        call    lzw_decode
.done:
        ret

; read a colour table of 2^(al+1) entries (RGB, 0..255) into pal
gct_read:
        mov     cl, al
        mov     ax, 2
        shl     ax, cl              ; ax = 2^(n+1)
        mov     cx, ax
        mov     di, pal
.l:
        push    cx
        call    getb
        mov     [di], al
        call    getb
        mov     [di+1], al
        call    getb
        mov     [di+2], al
        add     di, 3
        pop     cx
        loop    .l
        ret

; ----------------------------------------------------------------------------
; GIF data sub-block reader: gif_getb -> al = next LZW data byte (CF=1 at end)
gif_getb:
        cmp     word [blkrem], 0
        jne     .have
        call    getb                ; next sub-block length
        or      al, al
        jz      .end
        movzx   ax, al
        mov     [blkrem], ax
.have:
        dec     word [blkrem]
        call    getb
        clc
        ret
.end:
        stc
        ret

; pull one LZW code (codesize bits, LSB-first) -> ax (also [thecode]); CF=1 end
get_code:
.fill:
        mov     cx, [codesize]
        cmp     [nbits], cx
        jae     .enough
        call    gif_getb
        jc      .eof
        movzx   ebx, al
        mov     cx, [nbits]
        shl     ebx, cl
        or      [acc], ebx
        add     word [nbits], 8
        jmp     .fill
.enough:
        mov     cx, [codesize]
        mov     eax, [acc]
        mov     ebx, 1
        shl     ebx, cl
        dec     ebx                 ; mask = (1<<codesize)-1
        and     eax, ebx
        mov     [thecode], ax
        mov     ebx, [acc]
        shr     ebx, cl
        mov     [acc], ebx
        sub     [nbits], cx
        mov     ax, [thecode]
        clc
        ret
.eof:
        stc
        ret

lzw_decode:
        call    gif_reset_blocks
        call    getb                ; LZW minimum code size
        movzx   ax, al
        mov     [mincode], ax
        mov     cx, ax
        mov     ax, 1
        shl     ax, cl
        mov     [clearcode], ax     ; 1<<mincode
        inc     ax
        mov     [eoicode], ax       ; clear+1
        mov     word [curcol], 0
        mov     word [currow], 0
        mov     byte [gpass], 0
        mov     dword [acc], 0
        mov     word [nbits], 0
        call    lzw_reset_table
        mov     word [prevcode], 0FFFFh
.next:
        call    get_code
        jc      .done
        mov     ax, [thecode]
        cmp     ax, [clearcode]
        jne     .noclear
        call    lzw_reset_table
        mov     word [prevcode], 0FFFFh
        jmp     .next
.noclear:
        cmp     ax, [eoicode]
        je      .done
        cmp     word [prevcode], 0FFFFh
        jne     .normal
        ; first code after a clear: a literal pixel (code < clearcode)
        mov     [firstbyte], al
        mov     [prevcode], ax
        call    emit_pixel
        jmp     .next
.normal:
        mov     [incode], ax
        mov     word [lzwsp], 0
        mov     bx, ax
        cmp     bx, [nextcode]
        jb      .intable
        mov     al, [firstbyte]     ; KwKwK case: push prior firstbyte, use prev
        call    stk_push
        mov     bx, [prevcode]
.intable:
.unwind:
        cmp     bx, [clearcode]
        jb      .unwound
        mov     si, bx
        mov     al, [suffix+si]
        call    stk_push
        shl     si, 1
        mov     bx, [prefix+si]
        jmp     .unwind
.unwound:
        mov     [firstbyte], bl     ; bx < clearcode -> raw index = first char
        mov     al, bl
        call    stk_push
.outl:
        cmp     word [lzwsp], 0
        je      .added
        call    stk_pop
        call    emit_pixel
        jmp     .outl
.added:
        mov     bx, [nextcode]
        cmp     bx, 4096
        jae     .nogrow
        mov     si, bx
        shl     si, 1
        mov     ax, [prevcode]
        mov     [prefix+si], ax
        mov     si, bx
        mov     al, [firstbyte]
        mov     [suffix+si], al
        inc     word [nextcode]
        mov     ax, [nextcode]
        mov     cx, [codesize]
        mov     bx, 1
        shl     bx, cl
        cmp     ax, bx
        jb      .nogrow
        cmp     word [codesize], 12
        jae     .nogrow
        inc     word [codesize]
.nogrow:
        mov     ax, [incode]
        mov     [prevcode], ax
        jmp     .next
.done:
        ret

stk_push:                           ; al = byte
        mov     bx, [lzwsp]
        mov     [lzwstack+bx], al
        inc     word [lzwsp]
        ret
stk_pop:                            ; -> al
        dec     word [lzwsp]
        mov     bx, [lzwsp]
        mov     al, [lzwstack+bx]
        ret

; reset GIF sub-block accounting
gif_reset_blocks:
        mov     word [blkrem], 0
        ret

; (re)initialise the LZW table for a fresh run / after a clear code
lzw_reset_table:
        mov     ax, [mincode]
        inc     ax
        mov     [codesize], ax      ; mincode+1
        mov     ax, [eoicode]
        inc     ax
        mov     [nextcode], ax      ; eoi+1
        ret

; ============================================================================
;  dims: clip iw,ih to <=320,<=200 -> dstw,dsth ; imgw,imgh = dstw,dsth
; ============================================================================
clip_dims:
        mov     ax, [iw]
        cmp     ax, 320
        jbe     .w
        mov     ax, 320
.w:
        mov     [dstw], ax
        mov     [imgw], ax
        mov     ax, [ih]
        cmp     ax, 200
        jbe     .h
        mov     ax, 200
.h:
        mov     [dsth], ax
        mov     [imgh], ax
        ret

; ============================================================================
;  emit one pixel (al) at the current GIF cursor, advancing with interlace
; ============================================================================
emit_pixel:
        mov     cx, [currow]
        cmp     cx, [dsth]
        jae     .skip
        mov     bx, [curcol]
        cmp     bx, [dstw]
        jae     .skip
        push    ax
        mov     ax, [currow]
        mul     word [imgw]
        add     ax, [curcol]
        mov     di, ax
        pop     ax
        mov     [es:di], al
.skip:
        inc     word [curcol]
        mov     ax, [curcol]
        cmp     ax, [iw]
        jb      .ret
        mov     word [curcol], 0
        call    next_row
.ret:
        ret

; advance currow honouring the interlace flag (ipacked bit 6)
next_row:
        test    byte [ipacked], 40h
        jnz     .inter
        inc     word [currow]
        ret
.inter:
        ; passes: 0:start0 step8, 1:start4 step8, 2:start2 step4, 3:start1 step2
        mov     al, [gpass]
        cmp     al, 0
        je      .p0
        cmp     al, 1
        je      .p1
        cmp     al, 2
        je      .p2
        ; pass 3
        add     word [currow], 2
        jmp     .chk
.p0:
        add     word [currow], 8
        jmp     .chk
.p1:
        add     word [currow], 8
        jmp     .chk
.p2:
        add     word [currow], 4
        jmp     .chk
.chk:
        mov     ax, [currow]
        cmp     ax, [ih]
        jb      .ret
        ; move to the next pass' starting row
        inc     byte [gpass]
        mov     al, [gpass]
        cmp     al, 1
        je      .s1
        cmp     al, 2
        je      .s2
        cmp     al, 3
        je      .s3
        ret                         ; passes exhausted
.s1:
        mov     word [currow], 4
        ret
.s2:
        mov     word [currow], 2
        ret
.s3:
        mov     word [currow], 1
.ret:
        ret

; ============================================================================
;  Output: CCIMG.RAW = imgw(2) imgh(2) pixels(imgw*imgh) palette(768)
; ============================================================================
write_raw:
        mov     ah, 3Ch
        xor     cx, cx
        mov     dx, s_rawname
        int     21h
        jc      .ret
        mov     [ofh], ax
        ; header: imgw, imgh
        mov     ax, [imgw]
        mov     [w16], ax
        mov     ax, [imgh]
        mov     [h16], ax
        mov     bx, [ofh]
        mov     ah, 40h
        mov     cx, 4
        mov     dx, w16
        int     21h
        ; pixels from img_seg
        mov     ax, [imgw]
        mul     word [imgh]
        mov     cx, ax              ; imgw*imgh (< 64000)
        push    ds
        mov     ax, [img_seg]
        mov     ds, ax
        xor     dx, dx
        mov     bx, [cs:ofh]
        mov     ah, 40h
        int     21h
        pop     ds
        ; palette
        mov     bx, [ofh]
        mov     ah, 40h
        mov     cx, 768
        mov     dx, pal
        int     21h
        mov     bx, [ofh]
        mov     ah, 3Eh
        int     21h
.ret:
        ret

; ============================================================================
;  Display: VGA mode 13h, load DAC, blit, wait for a key, restore text mode
; ============================================================================
show_image:
        mov     ax, 0013h
        int     10h
        ; load the DAC (palette 0..255 -> 6-bit, value>>2)
        mov     dx, 3C8h
        xor     al, al
        out     dx, al
        mov     dx, 3C9h
        mov     si, pal
        mov     cx, 768
.dac:
        lodsb
        shr     al, 2
        out     dx, al
        loop    .dac
        ; blit img_seg -> A000, row by row (clipped width)
        mov     bp, [imgw]
        mov     dx, [imgh]
        push    ds
        mov     ax, 0A000h
        mov     es, ax
        mov     ax, [img_seg]
        mov     ds, ax
        xor     si, si              ; source offset
        xor     di, di              ; dest offset
        xor     bx, bx              ; row
.row:
        cmp     bx, dx
        jae     .blit_done
        mov     cx, bp
        push    si
        push    di
        rep     movsb
        pop     di
        pop     si
        add     si, bp              ; next source row
        add     di, 320             ; next screen row
        inc     bx
        jmp     .row
.blit_done:
        pop     ds
        xor     ax, ax              ; wait for a key
        int     16h
        mov     ax, 0003h
        int     10h
        ret

; ============================================================================
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
        ; optional /D
        cmp     byte [si], '/'
        jne     .name
        inc     si
        mov     al, [si]
        and     al, 0DFh
        cmp     al, 'D'
        jne     .name
        mov     byte [dumpmode], 1
        inc     si
        call    skip_sp
.name:
        mov     di, fname
.cp:
        mov     al, [si]
        or      al, al
        jz      .d
        cmp     al, ' '
        je      .d
        mov     [di], al
        inc     si
        inc     di
        jmp     .cp
.d:
        mov     byte [di], 0
        ret

skip_sp:
        cmp     byte [si], ' '
        jne     .d
        inc     si
        jmp     skip_sp
.d:     ret

; ============================================================================
s_usage     db 'Usage: CCIMG <image>',0Dh,0Ah,0
s_noopen    db 'CCIMG: cannot open file',0Dh,0Ah,0
s_badfmt    db 'CCIMG: unsupported image format',0Dh,0Ah,0
s_rawname   db 'CCIMG.RAW',0

IOBUF_SZ    equ 4096

section .bss
align 2
dumpmode    resb 1
fname       resb 128
fh          resw 1
ofh         resw 1
img_seg     resw 1
flen        resd 1
m0          resb 1
m1          resb 1
iw          resw 1
ih          resw 1
dstw        resw 1
dsth        resw 1
imgw        resw 1
imgh        resw 1
w16         resw 1
h16         resw 1
rowpad      resw 1
pcxbpl      resw 1
rle_rem     resw 1
rle_val     resb 1
; ini buffered reader
iopos       resw 1
iolen       resw 1
; GIF / LZW state
gpacked     resb 1
ipacked     resb 1
blkrem      resw 1
mincode     resw 1
clearcode   resw 1
eoicode     resw 1
codesize    resw 1
nextcode    resw 1
prevcode    resw 1
curcol      resw 1
currow      resw 1
gpass       resb 1
acc         resd 1
nbits       resw 1
thecode     resw 1
incode      resw 1
firstbyte   resb 1
lzwsp       resw 1
align 2
prefix      resb 4096*2          ; LZW string table: prefix code (word)
suffix      resb 4096            ; LZW string table: suffix byte
lzwstack    resb 4096            ; output unwinding stack
hdrbuf      resb 128
pal         resb 768
iobuf       resb IOBUF_SZ
stackspace  resb 1024
stacktop:
