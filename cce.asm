; ============================================================================
;  CCEDIT.COM  --  Claude Commander's external text editor (Layer 3 helper)
;
;  A compact full-screen editor for DOS.  cc.com launches it on F4 with the
;  full path of the current file:  CCEDIT <path>.  Standalone too.
;
;  Keys:  arrows/Home/End/PgUp/PgDn move   printable insert   Enter splits line
;         Backspace/Del remove   F2 save   Esc or F10 quit.
;
;  Self-test:  CCEDIT /T <file>  replays key pairs (AL,AH) from cce.key and
;  dumps each frame to CCEDUMP.TXT.  Because edits + F2 persist to <file>, a
;  scripted "type, save, quit" run is verified by inspecting the saved file.
;
;  Assemble:  nasm -f bin cce.asm -o ccedit.com
; ============================================================================
        org     100h

SCRW    equ 80
SCRH    equ 25
TROWS   equ 24                  ; text rows 0..23 ; row 24 = status
VIDEO   equ 0B800h
TEXTMAX equ 49152               ; 48 KB edit buffer
A_TXT   equ 07h                 ; grey on black
A_STAT  equ 70h                 ; black on grey (status line + cursor cell)

start:
        cld
        mov     sp, stacktop
        call    parse_tail          ; -> fname (ASCIIZ), test_mode
        call    load_keys           ; test mode: slurp cce.key
        call    load_file           ; -> textbuf, [len]  (missing file -> len 0)
        mov     word [cur], 0
        mov     word [topline], 0
        mov     byte [dirty], 0
.loop:
        call    render
        cmp     byte [test_mode], 0
        je      .live
        call    dump_screen
.live:
        call    get_key             ; al=ascii ah=scan
        call    handle_key
        cmp     byte [quit], 0
        je      .loop
        cmp     byte [test_mode], 0
        je      .restore
        call    close_dump
.restore:
        mov     ax, 0003h           ; reset text mode
        int     10h
        mov     ax, 4C00h
        int     21h

; ----------------------------------------------------------------------------
; parse the PSP command tail (80h len, 81h text): set test_mode if a "/T" token
; is present; the first non-switch token becomes fname.
parse_tail:
        mov     byte [test_mode], 0
        mov     di, fname
        movzx   cx, byte [80h]
        mov     si, 81h
.tok:
        jcxz    .end
        ; skip spaces
        mov     al, [si]
        cmp     al, ' '
        jne     .word
        inc     si
        dec     cx
        jmp     .tok
.word:
        ; is this token "/T" or "/t"?
        cmp     al, '/'
        jne     .copyword
        mov     al, [si+1]
        and     al, 0DFh
        cmp     al, 'T'
        jne     .copyword
        mov     byte [test_mode], 1
        ; skip the switch token
.skipsw:
        jcxz    .end
        mov     al, [si]
        cmp     al, ' '
        je      .tok
        inc     si
        dec     cx
        jmp     .skipsw
.copyword:
        ; copy until space or end -> fname
        jcxz    .fdone
        mov     al, [si]
        cmp     al, ' '
        je      .fdone
        mov     [di], al
        inc     di
        inc     si
        dec     cx
        jmp     .copyword
.fdone:
        mov     byte [di], 0
        ret
.end:
        mov     byte [di], 0
        ret

; ----------------------------------------------------------------------------
; load cce.key into keybuf (test mode only).  keylen=bytes, keypos=0.
load_keys:
        mov     word [keypos], 0
        mov     word [keylen], 0
        cmp     byte [test_mode], 0
        je      .ret
        mov     ax, 3D00h
        mov     dx, keyname
        int     21h
        jc      .ret
        mov     bx, ax
        mov     ah, 3Fh
        mov     cx, 1024
        mov     dx, keybuf
        int     21h
        jc      .close
        mov     [keylen], ax
.close:
        mov     ah, 3Eh
        int     21h
.ret:
        ret

; ----------------------------------------------------------------------------
; load fname into textbuf -> [len].  Missing/unreadable -> len 0 (new file).
load_file:
        mov     word [len], 0
        mov     ax, 3D00h
        mov     dx, fname
        int     21h
        jc      .ret
        mov     bx, ax
        mov     ah, 3Fh
        mov     cx, TEXTMAX
        mov     dx, textbuf
        int     21h
        jc      .close
        mov     [len], ax
.close:
        mov     ah, 3Eh
        int     21h
.ret:
        ret

; ----------------------------------------------------------------------------
; save textbuf[0..len) back to fname; clear dirty.
do_save:
        mov     ah, 3Ch             ; create/truncate
        xor     cx, cx
        mov     dx, fname
        int     21h
        jc      .ret
        mov     bx, ax
        mov     ah, 40h
        mov     cx, [len]
        mov     dx, textbuf
        int     21h
        mov     ah, 3Eh
        int     21h
        mov     byte [dirty], 0
.ret:
        ret

; ----------------------------------------------------------------------------
; get_key -> al=ascii, ah=scan.  Test mode pulls AL,AH pairs from keybuf and
; synthesises Esc on exhaustion; live mode uses BIOS INT 16h.
get_key:
        cmp     byte [test_mode], 0
        je      .live
        mov     bx, [keypos]
        cmp     bx, [keylen]
        jae     .quit
        mov     al, [keybuf+bx]
        mov     ah, [keybuf+bx+1]
        add     word [keypos], 2
        ret
.quit:
        mov     al, 1Bh             ; Esc -> quit
        xor     ah, ah
        ret
.live:
        xor     ah, ah
        int     16h
        ret

; ----------------------------------------------------------------------------
; dispatch a key.
handle_key:
        or      al, al
        jnz     .ascii
        cmp     ah, 48h
        je      move_up
        cmp     ah, 50h
        je      move_down
        cmp     ah, 4Bh
        je      move_left
        cmp     ah, 4Dh
        je      move_right
        cmp     ah, 47h
        je      move_home
        cmp     ah, 4Fh
        je      move_end
        cmp     ah, 49h
        je      page_up
        cmp     ah, 51h
        je      page_down
        cmp     ah, 53h
        je      do_delete
        cmp     ah, 3Ch             ; F2
        je      do_save
        cmp     ah, 44h             ; F10
        je      do_quit
        ret
.ascii:
        cmp     al, 1Bh             ; Esc
        je      do_quit
        cmp     al, 08h
        je      do_bksp
        cmp     al, 0Dh
        je      do_enter
        cmp     al, 09h             ; Tab -> literal tab
        je      .tab
        cmp     al, 20h
        jb      .ret
        cmp     al, 7Eh
        ja      .ret
        call    ins_char
.ret:
        ret
.tab:
        mov     al, 09h
        call    ins_char
        ret

do_quit:
        mov     byte [quit], 1
        ret

; ----------------------------------------------------------------------------
; ins_char: insert AL at [cur], shift the tail right one byte.
ins_char:
        mov     bx, [len]
        cmp     bx, TEXTMAX-2
        jae     .full
        push    ax
        mov     cx, [len]
        sub     cx, [cur]           ; tail byte count
        jcxz    .place
        std
        mov     si, textbuf
        add     si, [len]
        dec     si                  ; src = last byte
        mov     di, si
        inc     di                  ; dst = one past
        rep     movsb
        cld
.place:
        pop     ax
        mov     bx, [cur]
        mov     [textbuf+bx], al
        inc     word [cur]
        inc     word [len]
        mov     byte [dirty], 1
.full:
        ret

do_enter:
        mov     al, 0Dh
        call    ins_char
        mov     al, 0Ah
        call    ins_char
        ret

; delete AX bytes starting at [cur]; shift tail left.
delete_n:
        mov     dx, ax              ; count
        mov     bx, [cur]
        mov     cx, [len]
        sub     cx, bx
        sub     cx, dx              ; tail bytes after the deleted region
        jbe     .shrink
        cld
        mov     di, textbuf
        add     di, bx
        mov     si, di
        add     si, dx
        rep     movsb
.shrink:
        sub     [len], dx
        mov     byte [dirty], 1
        ret

do_bksp:
        cmp     word [cur], 0
        je      .ret
        mov     bx, [cur]
        cmp     byte [textbuf+bx-1], 0Ah
        jne     .one
        cmp     word [cur], 2
        jb      .one
        cmp     byte [textbuf+bx-2], 0Dh
        jne     .one
        sub     word [cur], 2       ; CRLF pair
        mov     ax, 2
        jmp     .del
.one:
        dec     word [cur]
        mov     ax, 1
.del:
        call    delete_n
.ret:
        ret

do_delete:
        mov     ax, [cur]
        cmp     ax, [len]
        jae     .ret
        ; delete a CRLF as a unit if present
        mov     bx, ax
        cmp     byte [textbuf+bx], 0Dh
        jne     .one
        mov     cx, [len]
        dec     cx
        cmp     bx, cx
        jae     .one
        cmp     byte [textbuf+bx+1], 0Ah
        jne     .one
        mov     ax, 2
        jmp     .del
.one:
        mov     ax, 1
.del:
        call    delete_n
.ret:
        ret

; ----------------------------------------------------------------------------
; cursor movement
move_left:
        cmp     word [cur], 0
        je      .ret
        dec     word [cur]
.ret:   ret

move_right:
        mov     ax, [cur]
        cmp     ax, [len]
        jae     .ret
        inc     word [cur]
.ret:   ret

move_home:
        mov     ax, [cur]
        call    ls_of               ; bx = line start
        mov     [cur], bx
        ret

move_end:
        mov     bx, [cur]
.f:
        cmp     bx, [len]
        jae     .set
        cmp     byte [textbuf+bx], 0Ah
        je      .pre
        cmp     byte [textbuf+bx], 0Dh
        je      .set
        inc     bx
        jmp     .f
.pre:
        ; before LF; back over a CR if present
        cmp     bx, 0
        je      .set
        cmp     byte [textbuf+bx-1], 0Dh
        jne     .set
        ; (cur should sit before CR) -- bx already points at LF, leave at CR
.set:
        mov     [cur], bx
        ret

move_up:
        call    find_curpos         ; sets [curcol]
        mov     ax, [cur]
        call    ls_of               ; bx = current line start
        or      bx, bx
        jz      .ret                ; first line
        mov     ax, bx
        dec     ax                  ; into the prev line's terminator
        call    ls_of               ; bx = prev line start
        call    place_col           ; cur = bx + min(curcol, linelen)
.ret:   ret

move_down:
        call    find_curpos
        mov     bx, [cur]
.f:
        cmp     bx, [len]
        jae     .ret                ; last line
        mov     al, [textbuf+bx]
        inc     bx
        cmp     al, 0Ah
        jne     .f
        ; bx = next line start
        cmp     bx, [len]
        ja      .ret
        call    place_col
.ret:   ret

; cur = bx + min([curcol], content-length of line at bx)
place_col:
        mov     si, bx
        call    lcontent_len        ; cx = content len
        mov     ax, [curcol]
        cmp     ax, cx
        jbe     .ok
        mov     ax, cx
.ok:
        add     bx, ax
        mov     [cur], bx
        ret

page_up:
        mov     cx, TROWS-1
.l:     push    cx
        call    move_up
        pop     cx
        loop    .l
        ret

page_down:
        mov     cx, TROWS-1
.l:     push    cx
        call    move_down
        pop     cx
        loop    .l
        ret

; ----------------------------------------------------------------------------
; ls_of: AX=offset -> BX = start of that line (after the previous LF).
ls_of:
        mov     bx, ax
.l:
        or      bx, bx
        jz      .d
        cmp     byte [textbuf+bx-1], 0Ah
        je      .d
        dec     bx
        jmp     .l
.d:     ret

; lcontent_len: SI=line start -> CX = chars until CR/LF/EOF.
lcontent_len:
        xor     cx, cx
        mov     bx, si
.l:
        cmp     bx, [len]
        jae     .d
        mov     al, [textbuf+bx]
        cmp     al, 0Dh
        je      .d
        cmp     al, 0Ah
        je      .d
        inc     bx
        inc     cx
        jmp     .l
.d:     ret

; find_curpos: set [curline] (LF count before cur) and [curcol] (cur - line start).
find_curpos:
        xor     cx, cx              ; line
        xor     bx, bx              ; line start
        xor     si, si
.l:
        cmp     si, [cur]
        jae     .d
        mov     al, [textbuf+si]
        inc     si
        cmp     al, 0Ah
        jne     .l
        inc     cx
        mov     bx, si
        jmp     .l
.d:
        mov     [curline], cx
        mov     ax, [cur]
        sub     ax, bx
        mov     [curcol], ax
        ret

; offset_of_topline -> SI = byte offset where [topline] begins.
offset_of_topline:
        mov     cx, [topline]
        xor     si, si
.next:
        jcxz    .d
.scan:
        cmp     si, [len]
        jae     .d
        mov     al, [textbuf+si]
        inc     si
        cmp     al, 0Ah
        jne     .scan
        dec     cx
        jmp     .next
.d:     ret

; ----------------------------------------------------------------------------
; render the whole screen.
render:
        call    find_curpos             ; -> curline, curcol
        ; vertical scroll so the cursor line is visible
        mov     ax, [curline]
        cmp     ax, [topline]
        jae     .below
        mov     [topline], ax
        jmp     .scrolled
.below:
        mov     ax, [topline]
        add     ax, TROWS
        cmp     [curline], ax
        jb      .scrolled
        mov     ax, [curline]
        sub     ax, TROWS-1
        mov     [topline], ax
.scrolled:
        push    es
        mov     ax, VIDEO
        mov     es, ax
        call    offset_of_topline       ; si = first visible byte
        xor     bp, bp                  ; screen row
.row:
        cmp     bp, TROWS
        jae     .status
        mov     ax, bp
        mov     dx, SCRW*2
        mul     dx
        mov     di, ax                  ; row*160
        xor     cx, cx                  ; column
.col:
        cmp     si, [len]
        jae     .fill
        mov     al, [textbuf+si]
        cmp     al, 0Dh
        je      .skip
        cmp     al, 0Ah
        je      .nl
        cmp     cx, SCRW
        jae     .toolong
        mov     ah, A_TXT
        mov     [es:di], al
        mov     [es:di+1], ah
        add     di, 2
        inc     cx
        inc     si
        jmp     .col
.skip:
        inc     si
        jmp     .col
.nl:
        inc     si
        jmp     .fill
.toolong:
        ; past column 80: swallow the rest of the line
        cmp     si, [len]
        jae     .fill
        mov     al, [textbuf+si]
        inc     si
        cmp     al, 0Ah
        jne     .toolong
.fill:
        ; pad the remainder of the row with spaces
        cmp     cx, SCRW
        jae     .rowdone
        mov     word [es:di], (A_TXT<<8) | ' '
        add     di, 2
        inc     cx
        jmp     .fill
.rowdone:
        inc     bp
        jmp     .row
.status:
        call    draw_status
        ; highlight the cursor cell (row curline-topline, col curcol) if on-screen
        mov     ax, [curline]
        sub     ax, [topline]
        cmp     ax, TROWS
        jae     .nocur
        mov     dx, SCRW*2
        mul     dx
        mov     di, ax
        mov     bx, [curcol]
        cmp     bx, SCRW
        jae     .nocur
        shl     bx, 1
        add     di, bx
        mov     byte [es:di+1], A_STAT
.nocur:
        pop     es
        ret

; status line (row 24): hint + filename + dirty + Ln/Col.  es=VIDEO.
draw_status:
        mov     di, (SCRH-1)*SCRW*2
        mov     cx, SCRW
        mov     ax, (A_STAT<<8) | ' '
.clr:
        mov     [es:di], ax
        add     di, 2
        loop    .clr
        mov     di, (SCRH-1)*SCRW*2
        mov     si, s_hint
        call    stat_puts
        ; filename
        mov     si, fname
        call    stat_puts
        cmp     byte [dirty], 0
        je      .ln
        mov     al, '*'
        mov     ah, A_STAT
        mov     [es:di], al
        mov     [es:di+1], ah
        add     di, 2
.ln:
        ; "  Ln "
        mov     si, s_ln
        call    stat_puts
        mov     ax, [curline]
        inc     ax
        call    stat_num
        mov     si, s_col
        call    stat_puts
        mov     ax, [curcol]
        inc     ax
        call    stat_num
        ret

; write ASCIIZ ds:si at es:di, attr A_STAT, di advances.
stat_puts:
        mov     ah, A_STAT
.l:
        mov     al, [si]
        or      al, al
        jz      .d
        mov     [es:di], al
        mov     [es:di+1], ah
        add     di, 2
        inc     si
        jmp     .l
.d:     ret

; write AX as decimal at es:di (A_STAT), di advances.
stat_num:
        mov     bx, 10
        xor     cx, cx
.div:
        xor     dx, dx
        div     bx
        push    dx
        inc     cx
        or      ax, ax
        jnz     .div
.emit:
        pop     dx
        mov     al, dl
        add     al, '0'
        mov     ah, A_STAT
        mov     [es:di], al
        mov     [es:di+1], ah
        add     di, 2
        loop    .emit
        ret

; ----------------------------------------------------------------------------
; dump_screen: append 25x80 char rows + a separator to CCEDUMP.TXT.
dump_screen:
        mov     bx, [dumph]
        cmp     bx, 0FFFFh
        jne     .have
        ; open/create on first use
        mov     ah, 3Ch
        xor     cx, cx
        mov     dx, dumpname
        int     21h
        jc      .ret
        mov     [dumph], ax
        mov     bx, ax
.have:
        push    es
        xor     bp, bp
.row:
        cmp     bp, SCRH
        jae     .sep
        mov     ax, VIDEO
        mov     es, ax
        mov     ax, bp
        mov     dx, SCRW*2
        mul     dx
        mov     si, ax
        mov     di, linebuf
        mov     cx, SCRW
.col:
        mov     al, [es:si]
        mov     [di], al
        inc     di
        add     si, 2
        loop    .col
        mov     word [di], 0A0Dh
        mov     cx, SCRW+2
        mov     dx, linebuf
        mov     bx, [dumph]
        mov     ah, 40h
        int     21h
        inc     bp
        jmp     .row
.sep:
        mov     dx, dumpsep
        mov     cx, dumpsep_len
        mov     bx, [dumph]
        mov     ah, 40h
        int     21h
        pop     es
.ret:
        ret

close_dump:
        mov     bx, [dumph]
        cmp     bx, 0FFFFh
        je      .r
        mov     ah, 3Eh
        int     21h
.r:     ret

; ============================================================================
;  DATA
; ============================================================================
s_hint      db ' F2=Save  Esc=Quit  ',0
s_ln        db '  Ln ',0
s_col       db ' Col ',0
keyname     db 'cce.key',0
dumpname    db 'CCEDUMP.TXT',0
dumpsep     db '==== FRAME ====',0Dh,0Ah
dumpsep_len equ $-dumpsep

test_mode   db 0
quit        db 0
dirty       db 0
dumph       dw 0FFFFh
cur         dw 0
len         dw 0
topline     dw 0
curline     dw 0
curcol      dw 0
keypos      dw 0
keylen      dw 0

section .bss
align 2
fname       resb 128
linebuf     resb 84
keybuf      resb 1024
textbuf     resb TEXTMAX
stackspace  resb 1024
stacktop:
