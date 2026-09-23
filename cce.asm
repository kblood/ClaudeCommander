; ============================================================================
;  CCEDIT.COM  --  Claude Commander's external text editor (Layer 3 helper)
;
;  A compact full-screen editor for DOS.  cc.com launches it on F4 with the
;  full path of the current file:  CCEDIT <path>.  Standalone too.
;
;  Keys:  arrows/Home/End/PgUp/PgDn move   printable insert   Enter splits line
;         Backspace/Del remove   F2 save   Esc or F10 quit.
;
;  Safety: a file larger than the 48 KB buffer is refused ("file too large",
;  exit 1) instead of being loaded truncated.  F2 writes <name>.$$$ in the same
;  directory, checks every write/close, and only then deletes the original and
;  renames the temp over it (original attributes restored); any failure keeps
;  the '*' dirty mark and shows the error on the status line.  Esc/F10 with
;  unsaved changes asks "Save changes? (Y/N/Esc)": Y saves (quits only if the
;  save worked), N discards, Esc returns to the editor.
;
;  Self-test:  CCEDIT /T <file>  replays key pairs (AL,AH) from cce.key and
;  dumps each frame to CCEDUMP.TXT.  Because edits + F2 persist to <file>, a
;  scripted "type, save, quit" run is verified by inspecting the saved file.
;  An exhausted script acts as Esc, and answers N if the save prompt is up, so
;  a script that ends with unsaved edits still terminates (edits discarded).
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
        mov     word [msgp], 0      ; a key dismisses the last status message
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
; load fname into textbuf -> [len].  Missing file -> len 0 (new file).
; A file that does not fit in TEXTMAX, or a read error, is fatal (exit 1):
; editing a truncated copy and saving it would destroy the rest of the file.
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
        jc      .rderr
        mov     [len], ax
        cmp     ax, TEXTMAX
        jb      .close              ; short read = whole file
        mov     ah, 3Fh             ; buffer full: is there more?
        mov     cx, 1
        mov     dx, probe
        int     21h
        jc      .rderr
        or      ax, ax
        jnz     .toobig
.close:
        mov     ah, 3Eh
        int     21h
.ret:
        ret
.toobig:
        mov     dx, s_toobig
        jmp     .fatal
.rderr:
        mov     dx, s_rderr
.fatal:
        push    dx
        mov     ah, 3Eh
        int     21h
        pop     dx
        mov     ah, 09h
        int     21h
        mov     ax, 4C01h
        int     21h

; ----------------------------------------------------------------------------
; do_save: safe save of textbuf[0..len) to fname.  Writes tmpname (fname with
; its extension replaced by .$$$), checks every write + the close, then
; deletes fname and renames tmpname -> fname.  The original is only touched
; once the new copy is complete on disk.  CF=0 ok (dirty cleared); CF=1 failed
; (dirty kept, [msgp] says why).
do_save:
        cmp     byte [fname], 0
        je      .fail               ; no file name (CCEDIT started bare)
        call    make_tmpname
        mov     byte [haveattr], 0
        mov     ax, 4300h           ; remember the original's attributes
        mov     dx, fname
        int     21h
        jc      .create
        mov     [origattr], cx
        mov     byte [haveattr], 1
.create:
        mov     ah, 3Ch
        xor     cx, cx
        mov     dx, tmpname
        int     21h
        jc      .fail
        mov     bx, ax
        mov     cx, [len]
        jcxz    .close              ; empty text: nothing to write
        mov     ah, 40h
        mov     dx, textbuf
        int     21h
        jc      .wfail
        cmp     ax, cx              ; short write = disk full
        jne     .wfail
.close:
        mov     ah, 3Eh
        int     21h
        jc      .tfail
        ; the new copy is complete: replace the original
        mov     ah, 41h
        mov     dx, fname
        int     21h
        jnc     .ren
        cmp     ax, 2               ; file not found = new file, fine
        jne     .tfail              ; e.g. read-only: keep the original
.ren:
        mov     ah, 56h
        mov     dx, tmpname
        mov     di, fname
        int     21h
        jc      .rfail
        cmp     byte [haveattr], 0
        je      .ok
        mov     ax, 4301h
        mov     cx, [origattr]
        mov     dx, fname
        int     21h                 ; best effort
.ok:
        mov     byte [dirty], 0
        clc
        ret
.wfail:
        mov     ah, 3Eh             ; bx = temp handle
        int     21h
.tfail:
        mov     ah, 41h             ; drop the partial temp copy
        mov     dx, tmpname
        int     21h
.fail:
        mov     word [msgp], s_savefail
        stc
        ret
.rfail:
        mov     word [msgp], s_renfail  ; text is safe in <name>.$$$
        stc
        ret

; make_tmpname: tmpname = fname with the extension of its last path component
; replaced by (or, if none, extended with) ".$$$".  Editing a *.$$$ file uses
; ".$$_" so the temp can never be the file itself.
make_tmpname:
        mov     si, fname
        mov     di, tmpname
        xor     bx, bx              ; bx = where the extension's '.' went
.cp:
        mov     al, [si]
        or      al, al
        jz      .end
        cmp     al, '.'
        jne     .nodot
        mov     bx, di
.nodot:
        cmp     al, '\'
        je      .sep
        cmp     al, '/'
        je      .sep
        cmp     al, ':'
        jne     .st
.sep:
        xor     bx, bx              ; a dot in a directory name doesn't count
.st:
        mov     [di], al
        inc     di
        inc     si
        jmp     .cp
.end:
        or      bx, bx
        jz      .app
        ; existing extension "$$$"?  then use "$$_"
        mov     ah, '$'
        cmp     [bx+1], ah
        jne     .trunc
        cmp     [bx+2], ah
        jne     .trunc
        cmp     [bx+3], ah
        jne     .trunc
        cmp     byte [bx+4], 0
        jne     .trunc
        mov     byte [bx+3], '_'
        mov     byte [bx+4], 0
        ret
.trunc:
        mov     di, bx
.app:
        mov     dword [di], '.$$$'
        mov     byte [di+4], 0
        ret

; ask_save: "Save changes? (Y/N/Esc)".  CF=0 -> quit (saved or discarded);
; CF=1 -> stay (Esc, or Y whose save failed).  An exhausted /T key script
; answers N so a scripted run can never hang in the prompt.
ask_save:
        mov     word [msgp], s_ask
        call    render
        cmp     byte [test_mode], 0
        je      .key
        call    dump_screen
.key:
        call    get_key
        cmp     byte [keys_out], 0
        jne     .discard
        cmp     al, 1Bh
        je      .cancel
        or      al, 20h             ; fold to lowercase
        cmp     al, 'y'
        je      .yes
        cmp     al, 'n'
        je      .discard
        jmp     ask_save            ; anything else: ask again
.yes:
        call    do_save
        jc      .stay               ; status line shows the failure
        ret
.discard:
        mov     word [msgp], 0
        clc
        ret
.cancel:
        mov     word [msgp], 0
.stay:
        stc
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
        mov     byte [keys_out], 1  ; (ask_save treats this as N)
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
        cmp     byte [dirty], 0
        je      .q
        call    ask_save            ; CF=1 -> stay in the editor
        jc      .r
.q:     mov     byte [quit], 1
.r:     ret

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
        cmp     word [msgp], 0      ; prompt / error replaces the hint
        je      .hint
        mov     si, [msgp]
.hint:
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

s_ask       db ' Save changes? (Y/N/Esc) ',0
s_savefail  db ' SAVE FAILED - file unchanged ',0
s_renfail   db ' SAVE FAILED - text is in .$$$ file ',0
s_toobig    db 'CCEDIT: file too large (max 48K) - not opened',13,10,'$'
s_rderr     db 'CCEDIT: read error - not opened',13,10,'$'

test_mode   db 0
quit        db 0
dirty       db 0
keys_out    db 0
haveattr    db 0
msgp        dw 0
origattr    dw 0
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
tmpname     resb 136
probe       resb 2
linebuf     resb 84
keybuf      resb 1024
textbuf     resb TEXTMAX
stackspace  resb 1024
stacktop:
