; chexed.asm -- CCHEXED.COM : a small overwrite-only hex editor.
;
; Layer-3 helper for Claude Commander (cc).  Reached as the configured F4
; editor (cc.ini "editor = CCHEXED") or by pressing E in cc's F3 hex view,
; both of which run "CCHEXED <file>".  It loads the file (up to CAP bytes),
; shows a hex+ASCII grid with a byte cursor, lets you overwrite bytes by typing
; hex digits, F2 writes the buffer back IN PLACE (the file size never changes --
; no insert/delete), and Esc quits.
;
; /T test mode: if the command tail contains "/T", keystrokes are read from a
; script file CCX.KEY (al,ah byte pairs, like cc's harness) instead of the
; keyboard, and script exhaustion acts as Esc -- so an automated test can edit
; bytes, F2-save and then verify the resulting file on disk.

        cpu     8086
        org     100h

VIDEO    equ    0B800h
SCR_W    equ    80
HDR_ROW  equ    0
TOP_ROW  equ    1
VIS_ROWS equ    23                 ; hex rows 1..23 (16 bytes each)
BAR_ROW  equ    24
ROWB     equ    160
CAP      equ    0C000h             ; 48 KB editable window

A_NORM   equ    07h                ; grey on black
A_HDR    equ    30h                ; black on cyan header
A_CUR    equ    70h                ; inverse: the byte under the cursor
A_BAR    equ    30h                ; black on cyan help bar

start:
        ; DOS does not clear a .COM's memory beyond the image -> init state.
        xor     ax, ax
        mov     [cur], ax
        mov     [topb], ax
        mov     [keypos], ax
        mov     [keylen], ax
        mov     [nib], al
        mov     [modified], al
        mov     [test_mode], al

        ; ----- parse command tail at PSP:80h : filename [ /T ] -----
        mov     si, 81h
        mov     cl, [80h]
        xor     ch, ch
.sksp:                              ; skip leading blanks
        jcxz    .noname
        mov     al, [si]
        cmp     al, ' '
        jne     .name0
        inc     si
        dec     cx
        jmp     .sksp
.name0:
        mov     di, fname
.cpname:
        jcxz    .nameend
        mov     al, [si]
        cmp     al, ' '
        je      .nameend
        cmp     al, 0Dh
        je      .nameend
        mov     [di], al
        inc     di
        inc     si
        dec     cx
        jmp     .cpname
.nameend:
        mov     byte [di], 0
        cmp     di, fname
        je      .noname
        ; scan the rest of the tail for "/T"
.skt:
        jcxz    .opn
        mov     al, [si]
        cmp     al, '/'
        jne     .skt_adv
        mov     al, [si+1]
        and     al, 0DFh
        cmp     al, 'T'
        jne     .skt_adv
        mov     byte [test_mode], 1
        jmp     .opn
.skt_adv:
        inc     si
        dec     cx
        jmp     .skt
.noname:
        mov     dx, msg_usage
        jmp     die

.opn:
        mov     ax, 3D02h           ; open read/write
        mov     dx, fname
        int     21h
        jc      .operr
        mov     [fh], ax
        mov     bx, ax
        mov     ah, 3Fh             ; read up to CAP bytes
        mov     cx, CAP
        mov     dx, buf
        int     21h
        jc      .rderr
        mov     [loaded], ax
        cmp     byte [test_mode], 0
        je      .ui
        call    load_keys
.ui:
        call    hide_cursor
.loop:
        call    render
        call    get_key
        or      al, al
        jnz     .asc
        cmp     ah, 4Bh             ; Left
        je      .left
        cmp     ah, 4Dh             ; Right
        je      .right
        cmp     ah, 48h             ; Up
        je      .up
        cmp     ah, 50h             ; Down
        je      .down
        cmp     ah, 49h             ; PgUp
        je      .pgup
        cmp     ah, 51h             ; PgDn
        je      .pgdn
        cmp     ah, 47h             ; Home
        je      .home
        cmp     ah, 4Fh             ; End
        je      .end
        cmp     ah, 3Ch             ; F2 -> save
        je      .save
        jmp     .loop
.asc:
        cmp     al, 1Bh             ; Esc -> quit
        je      .quit
        call    try_hexedit
        jmp     .loop
.left:
        call    cur_dec
        jmp     .loop
.right:
        call    cur_inc
        jmp     .loop
.up:
        mov     ax, [cur]
        cmp     ax, 16
        jb      .loop
        sub     ax, 16
        mov     [cur], ax
        mov     byte [nib], 0
        jmp     .loop
.down:
        cmp     word [loaded], 0
        je      .loop
        mov     ax, [cur]
        add     ax, 16
        cmp     ax, [loaded]
        jae     .loop
        mov     [cur], ax
        mov     byte [nib], 0
        jmp     .loop
.pgup:
        mov     ax, [cur]
        sub     ax, 16*VIS_ROWS
        jnc     .pgset
        xor     ax, ax
.pgset:
        mov     [cur], ax
        mov     byte [nib], 0
        jmp     .loop
.pgdn:
        cmp     word [loaded], 0
        je      .loop
        mov     ax, [cur]
        add     ax, 16*VIS_ROWS
        cmp     ax, [loaded]
        jb      .pgdset
        mov     ax, [loaded]
        dec     ax
.pgdset:
        mov     [cur], ax
        mov     byte [nib], 0
        jmp     .loop
.home:
        xor     ax, ax
        mov     [cur], ax
        mov     byte [nib], 0
        jmp     .loop
.end:
        cmp     word [loaded], 0
        je      .loop
        mov     ax, [loaded]
        dec     ax
        mov     [cur], ax
        mov     byte [nib], 0
        jmp     .loop
.save:
        mov     bx, [fh]
        mov     ax, 4200h           ; seek to start
        xor     cx, cx
        xor     dx, dx
        int     21h
        mov     bx, [fh]
        mov     ah, 40h             ; write the buffer back in place
        mov     cx, [loaded]
        mov     dx, buf
        int     21h
        mov     byte [modified], 0
        jmp     .loop
.quit:
        mov     bx, [fh]
        mov     ah, 3Eh
        int     21h
        call    show_cursor
        mov     ax, 4C00h
        int     21h
.operr:
        mov     dx, msg_open
        jmp     die
.rderr:
        mov     bx, [fh]
        mov     ah, 3Eh
        int     21h
        mov     dx, msg_read
        jmp     die

die:
        mov     ah, 9
        int     21h
        mov     ax, 4C01h
        int     21h

; ---- cursor moves (clamped; reset the nibble phase) ------------------------
cur_inc:
        mov     ax, [cur]
        inc     ax
        cmp     ax, [loaded]
        jae     .no
        mov     [cur], ax
.no:
        mov     byte [nib], 0
        ret
cur_dec:
        mov     ax, [cur]
        or      ax, ax
        jz      .no
        dec     ax
        mov     [cur], ax
.no:
        mov     byte [nib], 0
        ret

; ---- overwrite the current byte from a hex digit in al ---------------------
try_hexedit:
        cmp     al, '0'
        jb      .no
        cmp     al, '9'
        ja      .alpha
        sub     al, '0'
        jmp     .val
.alpha:
        or      al, 20h             ; fold to lowercase
        cmp     al, 'a'
        jb      .no
        cmp     al, 'f'
        ja      .no
        sub     al, 'a'-10
.val:
        cmp     word [loaded], 0
        je      .no
        mov     dl, al              ; dl = nibble value 0..15
        mov     bx, [cur]
        cmp     byte [nib], 0
        jne     .lo
        shl     dl, 1               ; high nibble
        shl     dl, 1
        shl     dl, 1
        shl     dl, 1
        mov     al, [buf+bx]
        and     al, 0Fh
        or      al, dl
        mov     [buf+bx], al
        mov     byte [nib], 1
        mov     byte [modified], 1
        ret
.lo:
        mov     al, [buf+bx]
        and     al, 0F0h
        or      al, dl
        mov     [buf+bx], al
        mov     byte [modified], 1
        call    cur_inc             ; advance to next byte (resets nib)
.no:
        ret

; ---- rendering -------------------------------------------------------------
render:
        push    es
        call    fix_view
        mov     ax, VIDEO
        mov     es, ax
        xor     di, di              ; clear to normal attr
        mov     ax, (A_NORM<<8)|' '
        mov     cx, SCR_W*25
        rep     stosw
        call    draw_header
        xor     bp, bp              ; visible row 0..VIS_ROWS-1
.row:
        cmp     bp, VIS_ROWS
        jae     .bar
        mov     ax, bp              ; rowoff = topb + bp*16
        mov     cl, 4
        shl     ax, cl
        add     ax, [topb]
        mov     [rowoff], ax
        cmp     ax, [loaded]
        jae     .nextrow            ; entirely past EOF -> leave blank
        mov     ax, bp              ; di = (TOP_ROW+bp)*ROWB
        add     ax, TOP_ROW
        mov     cx, ROWB
        mul     cx
        mov     di, ax
        call    draw_hex_row
.nextrow:
        inc     bp
        jmp     .row
.bar:
        call    draw_bar
        pop     es
        ret

; one 16-byte row.  di = video offset, [rowoff] = first byte offset.
draw_hex_row:
        push    bp
        mov     bp, [rowoff]
        mov     byte [pattr], A_NORM
        xor     ax, ax              ; 8-digit offset (high word 0)
        call    put4
        mov     ax, bp
        call    put4
        mov     al, ' '
        call    putc
        call    putc
        xor     cx, cx              ; hex column 0..15
.hb:
        cmp     cx, 16
        jae     .ascii
        mov     bx, bp
        add     bx, cx
        cmp     bx, [loaded]
        jae     .hblank
        mov     byte [pattr], A_NORM
        cmp     bx, [cur]
        jne     .ha
        mov     byte [pattr], A_CUR
.ha:
        mov     al, [buf+bx]
        call    put_hexbyte
        mov     byte [pattr], A_NORM
        mov     al, ' '
        call    putc
        jmp     .hnext
.hblank:
        mov     byte [pattr], A_NORM
        mov     al, ' '
        call    putc
        call    putc
        call    putc
.hnext:
        inc     cx
        jmp     .hb
.ascii:
        mov     byte [pattr], A_NORM
        mov     al, ' '
        call    putc
        xor     cx, cx
.ac:
        cmp     cx, 16
        jae     .done
        mov     bx, bp
        add     bx, cx
        cmp     bx, [loaded]
        jae     .done
        mov     al, [buf+bx]
        cmp     al, 20h
        jb      .dot
        cmp     al, 7Eh
        jbe     .pr
.dot:
        mov     al, '.'
.pr:
        mov     byte [pattr], A_NORM
        cmp     bx, [cur]
        jne     .aa
        mov     byte [pattr], A_CUR
.aa:
        call    putc
        inc     cx
        jmp     .ac
.done:
        pop     bp
        ret

draw_header:
        xor     di, di
        mov     ax, (A_HDR<<8)|' '
        mov     cx, SCR_W
        rep     stosw
        mov     byte [pattr], A_HDR
        mov     di, 2
        mov     si, s_title
        call    puts
        mov     si, fname
        call    puts
        cmp     byte [modified], 0
        je      .nm
        mov     si, s_mod
        call    puts
.nm:
        ret

draw_bar:
        mov     di, BAR_ROW*ROWB
        mov     ax, (A_BAR<<8)|' '
        mov     cx, SCR_W
        rep     stosw
        mov     byte [pattr], A_BAR
        mov     di, BAR_ROW*ROWB
        mov     si, s_bar
        call    puts
        ret

; ensure the cursor row is within the visible window (topb is row-aligned).
fix_view:
        mov     ax, [cur]
        mov     cl, 4
        shr     ax, cl              ; cur_row
        mov     bx, ax
        mov     ax, [topb]
        shr     ax, cl              ; top_row
        cmp     bx, ax
        jae     .chkbot
        mov     ax, bx              ; scrolled above -> top = cur_row*16
        mov     cl, 4
        shl     ax, cl
        mov     [topb], ax
        ret
.chkbot:
        mov     dx, ax
        add     dx, VIS_ROWS
        cmp     bx, dx
        jb      .ok                 ; still visible
        mov     ax, bx              ; scrolled below -> top=(cur_row-VIS+1)*16
        sub     ax, VIS_ROWS-1
        mov     cl, 4
        shl     ax, cl
        mov     [topb], ax
.ok:
        ret

; ---- low-level writers (attribute taken from [pattr]) ----------------------
putc:                               ; al = char -> es:di, di += 2
        mov     ah, [pattr]
        mov     [es:di], al
        mov     [es:di+1], ah
        add     di, 2
        ret
puts:                               ; si = ASCIIZ
        mov     al, [si]
        or      al, al
        jz      .e
        call    putc
        inc     si
        jmp     puts
.e:
        ret
put_nib:                            ; al = 0..15 -> hex char
        cmp     al, 10
        jb      .d
        add     al, 'A'-10
        jmp     putc
.d:
        add     al, '0'
        jmp     putc
put_hexbyte:                        ; al = byte -> 2 hex chars
        push    ax
        mov     dl, al
        shr     al, 1
        shr     al, 1
        shr     al, 1
        shr     al, 1
        call    put_nib
        mov     al, dl
        and     al, 0Fh
        call    put_nib
        pop     ax
        ret
put4:                               ; ax = word -> 4 hex chars
        push    ax
        mov     dl, al
        mov     al, ah
        call    put_hexbyte
        mov     al, dl
        call    put_hexbyte
        pop     ax
        ret

; ---- keyboard / test harness ----------------------------------------------
get_key:                            ; -> al=ascii, ah=scan
        cmp     byte [test_mode], 0
        je      .live
        mov     bx, [keypos]
        cmp     bx, [keylen]
        jae     .endq
        mov     al, [keybuf+bx]
        mov     ah, [keybuf+bx+1]
        add     word [keypos], 2
        ret
.endq:
        mov     al, 1Bh             ; script exhausted -> Esc (quit)
        xor     ah, ah
        ret
.live:
        xor     ah, ah
        int     16h
        ret

load_keys:
        mov     ax, 3D00h
        mov     dx, keyname
        int     21h
        jc      .none
        mov     bx, ax
        mov     ah, 3Fh
        mov     cx, 512
        mov     dx, keybuf
        int     21h
        mov     [keylen], ax
        mov     ah, 3Eh
        int     21h
        ret
.none:
        mov     word [keylen], 0
        ret

hide_cursor:
        mov     ah, 1
        mov     cx, 2607h
        int     10h
        ret
show_cursor:
        mov     ah, 1
        mov     cx, 0607h
        int     10h
        ret

; ---- initialized data ------------------------------------------------------
s_title   db 'CCHEXED  ', 0
s_mod     db '   *MODIFIED (F2 to save)*', 0
s_bar     db ' Arrows/PgUp/PgDn/Home/End move   0-9 A-F overwrite   F2 save   Esc quit ', 0
keyname   db 'CCX.KEY', 0
msg_usage db 'Usage: CCHEXED <file> [/T]', 13, 10, '$'
msg_open  db 'CCHEXED: cannot open file', 13, 10, '$'
msg_read  db 'CCHEXED: read error', 13, 10, '$'

; ---- uninitialized data (beyond the file image) ----------------------------
section .bss
fname     resb 80
fh        resw 1
loaded    resw 1
cur       resw 1
topb      resw 1
rowoff    resw 1
nib       resb 1
modified  resb 1
test_mode resb 1
pattr     resb 1
keylen    resw 1
keypos    resw 1
buf       resb CAP
keybuf    resb 512
