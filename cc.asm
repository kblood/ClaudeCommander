; ============================================================================
;  Claude Commander (cc.com) -- a Volkov Commander-style file manager for DOS
;  Stage A: B800 renderer, two panels, directory read+sort, navigation.
;
;  Assemble:  nasm -f bin cc.asm -o cc.com
;  Target:    DOS, 286+, color text mode (80x25).
;
;  Test mode: "cc /T"  -> reads keystroke script cc.key (pairs of bytes
;                         al,ah), feeds them to the dispatcher, and appends
;                         the 80x25 screen (chars only) to CCDUMP.TXT after
;                         each frame; quits when the script is exhausted.
;             "cc /D"  -> render one frame, dump it, quit (no key script).
; ============================================================================

cpu 386
bits 16
org 100h

; ---- constants -------------------------------------------------------------
VIDEO       equ 0B800h
SCR_W       equ 80
SCR_H       equ 25
ROW_BYTES   equ SCR_W*2

; panel geometry (shared single divider at col 39)
; left  : border col 0 , content cols 1..38 (w=38), divider col 39
; right : divider col 39, content cols 40..78 (w=39), border col 79
L_CONX      equ 1
L_CONW      equ 38
R_CONX      equ 40
R_CONW      equ 39
TOP_ROW     equ 0          ; top frame
FIRST_ROW   equ 1          ; first file row
VIS_ROWS    equ 21         ; visible file rows (rows 1..21)
BOT_ROW     equ 22         ; bottom frame
CMD_ROW     equ 23         ; command line
FKEY_ROW    equ 24         ; function-key bar

; attributes (bg<<4 | fg)
A_NORM      equ 017h       ; light grey on blue (files)
A_DIR       equ 01Fh       ; bright white on blue (dirs)
A_TAG       equ 01Eh       ; yellow on blue (tagged entries)
A_CUR       equ 030h       ; black on cyan (cursor, active panel)
A_CURI      equ 070h       ; black on grey (cursor, inactive panel)
A_FRAME     equ 017h       ; light grey on blue
A_FRAMEA    equ 01Fh       ; bright white on blue (active frame)
A_TITLE     equ 030h       ; black on cyan (active path title)
A_TITLEI    equ 017h       ; grey on blue (inactive path title)
A_CMD       equ 007h       ; grey on black
A_FKN       equ 007h       ; grey on black (fkey number)
A_FKL       equ 030h       ; black on cyan (fkey label)
A_BG        equ 017h

; box-drawing chars (CP437)
C_TL        equ 0DAh
C_TR        equ 0BFh
C_BL        equ 0C0h
C_BR        equ 0D9h
C_H         equ 0C4h
C_V         equ 0B3h
C_TT        equ 0C2h       ; top tee
C_BT        equ 0C1h       ; bottom tee

; panel struct layout
P_PATH      equ 0          ; ASCIIZ current dir, e.g. "C:\GAMES"  (68 bytes)
P_COUNT     equ 68         ; word: number of entries
P_TOP       equ 70         ; word: first visible entry index
P_CUR       equ 72         ; word: cursor entry index (absolute)
P_ENTRIES   equ 74         ; entry array
MAX_FILES   equ 512         ; per panel (keeps the whole .COM within one 64KB segment)
ENTSIZE     equ 24
PANELSIZE   equ P_ENTRIES + MAX_FILES*ENTSIZE

; recursive copy/delete: per-level DTA stack
DTASZ       equ 64         ; bytes per FindFirst DTA (record is 43)
MAX_DEPTH   equ 24         ; max directory nesting we will recurse

; entry layout
E_NAME      equ 0          ; 14 bytes ASCIIZ (8.3 max 12 + nul)
E_ATTR      equ 14
E_SIZE      equ 16         ; dword
E_TIME      equ 20         ; word
E_DATE      equ 22         ; word

; ============================================================================
start:
        cld
        mov     sp, stacktop        ; relocate stack into resident region
        ; --- parse command tail for /T and /D ---
        mov     si, 81h             ; PSP command tail text
        movzx   cx, byte [80h]      ; tail length
        jcxz    .noargs
.scan:
        lodsb
        cmp     al, '/'
        jne     .next
        cmp     cx, 1
        jb      .noargs
        mov     al, [si]            ; char after '/'
        or      al, 20h             ; tolower
        cmp     al, 't'
        je      .set_test
        cmp     al, 'd'
        je      .set_dump
        cmp     al, 'c'
        je      .set_count
        cmp     al, 's'
        je      .set_snap
        jmp     .next
.set_test:
        mov     byte [test_mode], 1
        mov     byte [want_keys], 1
        jmp     .next
.set_dump:
        mov     byte [test_mode], 1
        jmp     .next
.set_count:
        mov     byte [test_mode], 1
        mov     byte [count_dbg], 1
        jmp     .next
.set_snap:
        mov     byte [snap_mode], 1
.next:
        loop    .scan
.noargs:

        ; --- shrink memory block so EXEC (Stage B) has room; keep up to end ---
        mov     ax, prog_end
        add     ax, 15
        shr     ax, 4               ; paragraphs of resident image
        add     ax, 16              ; + a little slack for stack
        mov     bx, ax
        mov     ah, 4Ah
        int     21h                 ; resize PSP block (ES=PSP at entry)

        ; --- save original video mode, switch to 80x25 colour text ---
        mov     ah, 0Fh
        int     10h
        mov     [orig_mode], al
        mov     ax, 0003h
        int     10h
        call    hide_cursor

        ; --- test-mode setup: open dump file, load key script ---
        cmp     byte [test_mode], 0
        je      .noteset
        call    open_dump
        cmp     byte [want_keys], 0
        je      .noteset
        call    load_keys
.noteset:

        ; --- init both panels to current drive/dir ---
        mov     di, panelL
        call    init_panel_cwd
        mov     di, panelR
        call    init_panel_cwd

        mov     word [active], panelL
        mov     word [cmdlen], 0

        ; --- diagnostic: write panel counts + first names, then exit ---
        cmp     byte [count_dbg], 0
        je      .nodbg
        call    selftest
        call    close_dump
        mov     ah, 0
        mov     al, [orig_mode]
        int     10h
        mov     ax, 4C00h
        int     21h
.nodbg:

        ; --- snapshot mode: render once, dump raw VRAM to CCSNAP.BIN, exit ---
        cmp     byte [snap_mode], 0
        je      .nosnap
        call    render_all
        call    snap_vram
        mov     ah, 0
        mov     al, [orig_mode]
        int     10h
        call    show_cursor
        mov     ax, 4C00h
        int     21h
.nosnap:

        ; --- mouse init (live mode only) ---
        mov     byte [mouse_ok], 0
        mov     byte [mouse_mode], MM_BROWSER
        mov     byte [m_lb], 0
        mov     byte [m_rb], 0
        mov     word [m_lastpan], 0FFFFh
        cmp     byte [test_mode], 0
        jne     .nomouse
        xor     ax, ax
        int     33h                 ; reset / detect mouse driver
        or      ax, ax
        jz      .nomouse            ; AX=0 -> no driver
        mov     byte [mouse_ok], 1
        mov     ax, 1
        int     33h                 ; show mouse cursor
.nomouse:

; ---- main loop -------------------------------------------------------------
main_loop:
        call    mouse_hide
        call    render_all
        call    mouse_show
        cmp     byte [test_mode], 0
        je      .live
        call    dump_screen
.live:
        call    get_key             ; -> al=ascii, ah=scan
        call    dispatch
        cmp     byte [quit_flag], 0
        je      main_loop

        ; --- exit: close dump, restore video ---
        cmp     byte [test_mode], 0
        je      .noclose
        call    close_dump
.noclose:
        call    mouse_hide
        mov     ah, 0
        mov     al, [orig_mode]
        int     10h
        call    show_cursor
        mov     ax, 4C00h
        int     21h

; ============================================================================
;  DISPATCH
; ============================================================================
dispatch:
        or      al, al
        jnz     .ascii
        ; --- extended key: dispatch on scan code in ah ---
        cmp     ah, 48h
        je      key_up
        cmp     ah, 50h
        je      key_down
        cmp     ah, 49h
        je      key_pgup
        cmp     ah, 4Bh             ; Left  -> page up
        je      key_pgup
        cmp     ah, 51h
        je      key_pgdn
        cmp     ah, 4Dh             ; Right -> page down
        je      key_pgdn
        cmp     ah, 47h
        je      key_home
        cmp     ah, 4Fh
        je      key_end
        cmp     ah, 3Dh             ; F3  View
        je      key_view
        cmp     ah, 3Fh             ; F5  Copy
        je      key_copy
        cmp     ah, 40h             ; F6  Rename/Move
        je      key_rename
        cmp     ah, 41h             ; F7  MkDir
        je      key_mkdir
        cmp     ah, 42h             ; F8  Delete
        je      key_delete
        cmp     ah, 52h             ; Insert  tag
        je      key_tag
        cmp     ah, 68h             ; Alt+F1  left drive
        je      key_drive_l
        cmp     ah, 69h             ; Alt+F2  right drive
        je      key_drive_r
        cmp     ah, 44h             ; F10
        je      key_quit
        ret
.ascii:
        cmp     al, 09h             ; Tab
        je      key_tab
        cmp     al, 0Dh             ; Enter
        je      on_enter
        cmp     al, 1Bh             ; Esc -> clear command line
        je      on_esc
        cmp     al, 08h             ; Backspace
        je      on_bksp
        cmp     al, 20h             ; printable range -> append to cmd line
        jb      .ret
        cmp     al, 7Eh
        ja      .ret
        call    cmd_addchar
.ret:
        ret

key_quit:
        mov     byte [quit_flag], 1
        ret

; Enter: if the command line has text, run it; else act on the current entry
on_enter:
        cmp     word [cmdlen], 0
        jne     run_command
        jmp     key_enter

on_esc:
        mov     word [cmdlen], 0
        ret

on_bksp:
        mov     ax, [cmdlen]
        or      ax, ax
        jz      .parent             ; empty command line -> go up a folder
        dec     ax
        mov     [cmdlen], ax
        ret
.parent:
        call    go_parent
        ret

cmd_addchar:
        mov     bx, [cmdlen]
        cmp     bx, 127
        jae     .r
        mov     [cmdbuf+bx], al
        inc     word [cmdlen]
.r:
        ret

key_tab:
        ; swap active <-> other
        mov     ax, [active]
        cmp     ax, panelL
        jne     .toL
        mov     word [active], panelR
        ret
.toL:
        mov     word [active], panelL
        ret

; cursor movement helpers (operate on active panel) ---------------------------
key_up:
        mov     bx, [active]
        mov     ax, [bx+P_CUR]
        or      ax, ax
        jz      .done
        dec     ax
        mov     [bx+P_CUR], ax
        call    fix_scroll
.done:
        ret

key_down:
        mov     bx, [active]
        mov     ax, [bx+P_CUR]
        mov     cx, [bx+P_COUNT]
        jcxz    .done
        inc     ax
        cmp     ax, cx
        jb      .ok
        mov     ax, cx
        dec     ax
.ok:
        mov     [bx+P_CUR], ax
        call    fix_scroll
.done:
        ret

key_pgup:
        mov     bx, [active]
        mov     ax, [bx+P_CUR]
        sub     ax, VIS_ROWS-1
        jns     .ok
        xor     ax, ax
.ok:
        mov     [bx+P_CUR], ax
        call    fix_scroll
        ret

key_pgdn:
        mov     bx, [active]
        mov     cx, [bx+P_COUNT]
        jcxz    .done
        mov     ax, [bx+P_CUR]
        add     ax, VIS_ROWS-1
        cmp     ax, cx
        jb      .ok
        mov     ax, cx
        dec     ax
.ok:
        mov     [bx+P_CUR], ax
        call    fix_scroll
.done:
        ret

key_home:
        mov     bx, [active]
        mov     word [bx+P_CUR], 0
        call    fix_scroll
        ret

key_end:
        mov     bx, [active]
        mov     cx, [bx+P_COUNT]
        jcxz    .done
        dec     cx
        mov     [bx+P_CUR], cx
        call    fix_scroll
.done:
        ret

; keep cursor visible: adjust P_TOP (bx = panel) -----------------------------
fix_scroll:
        mov     ax, [bx+P_CUR]
        ; if cur < top -> top = cur
        cmp     ax, [bx+P_TOP]
        jae     .belowtop
        mov     [bx+P_TOP], ax
        ret
.belowtop:
        ; if cur >= top + VIS_ROWS -> top = cur - VIS_ROWS + 1
        mov     dx, [bx+P_TOP]
        add     dx, VIS_ROWS
        cmp     ax, dx
        jb      .ok
        sub     ax, VIS_ROWS-1
        mov     [bx+P_TOP], ax
.ok:
        ret

; ============================================================================
;  ENTER: descend into dir, or go up on ".."
; ============================================================================
key_enter:
        mov     bx, [active]
        mov     cx, [bx+P_COUNT]
        jcxz    .ret
        call    cur_entry_ptr       ; -> si = entry ptr
        test    byte [si+E_ATTR], 10h
        jz      .file               ; not a directory -> maybe run it
        ; directory: is it ".."?
        mov     al, [si+E_NAME]
        cmp     al, '.'
        jne     .descend
        cmp     byte [si+E_NAME+1], '.'
        jne     .descend
        ; go up, landing the cursor on the folder we came from
        call    go_parent
        ret
.descend:
        ; append "\name" to path
        lea     di, [si+E_NAME]
        call    path_append
        call    read_dir
.ret:
        ret
.file:
        call    is_exec             ; si -> CF set if .EXE/.COM/.BAT
        jnc     .ret
        ; copy filename onto the command line and shell-run it
        push    si
        lea     si, [si+E_NAME]
        mov     di, cmdbuf
        xor     cx, cx
.fc:
        mov     al, [si]
        mov     [di], al
        or      al, al
        jz      .fce
        inc     si
        inc     di
        inc     cx
        jmp     .fc
.fce:
        mov     [cmdlen], cx
        pop     si
        call    set_active_cwd
        jmp     run_command

; si=entry -> CF=1 if the name ends in .EXE/.COM/.BAT (case-insensitive)
is_exec:
        push    si
        lea     si, [si+E_NAME]
        xor     bx, bx              ; bx = ptr just past last '.'
.f:
        mov     al, [si]
        or      al, al
        jz      .chk
        cmp     al, '.'
        jne     .nx
        lea     bx, [si+1]
.nx:
        inc     si
        jmp     .f
.chk:
        or      bx, bx
        jz      .no
        mov     si, bx
        mov     di, s_exe
        call    cmp3
        je      .yes
        mov     si, bx
        mov     di, s_com
        call    cmp3
        je      .yes
        mov     si, bx
        mov     di, s_bat
        call    cmp3
        je      .yes
.no:
        pop     si
        clc
        ret
.yes:
        pop     si
        stc
        ret

; compare 3 bytes [si] (uppercased) vs [di]; ZF=1 if equal
cmp3:
        mov     cx, 3
.l:
        mov     al, [si]
        cmp     al, 'a'
        jb      .u
        cmp     al, 'z'
        ja      .u
        sub     al, 20h
.u:
        cmp     al, [di]
        jne     .ne
        inc     si
        inc     di
        loop    .l
        xor     al, al              ; ZF=1 (equal)
        ret
.ne:
        mov     al, 1
        or      al, al              ; ZF=0 (differ)
        ret

; set the DOS current drive + directory to the active panel's path
set_active_cwd:
        mov     bx, [active]
        mov     dl, [bx+P_PATH]
        sub     dl, 'A'
        mov     ah, 0Eh             ; select drive
        int     21h
        lea     dx, [bx+P_PATH]
        mov     ah, 3Bh             ; chdir
        int     21h
        ret

; ============================================================================
;  RENDER
; ============================================================================
render_all:
        call    clear_bg
        ; left panel
        mov     bx, panelL
        mov     byte [pcx], L_CONX
        mov     byte [pcw], L_CONW
        call    draw_panel
        ; right panel
        mov     bx, panelR
        mov     byte [pcx], R_CONX
        mov     byte [pcw], R_CONW
        call    draw_panel
        call    draw_frames
        call    draw_cmdline
        call    draw_fkeys
        ret

; fill whole screen with blue spaces ------------------------------------------
clear_bg:
        push    es
        mov     ax, VIDEO
        mov     es, ax
        xor     di, di
        mov     ax, (A_BG<<8) | ' '
        mov     cx, SCR_W*SCR_H
        rep     stosw
        pop     es
        ret

; draw both panel frames (single line, shared divider) ------------------------
draw_frames:
        push    es
        mov     ax, VIDEO
        mov     es, ax
        ; top row
        mov     bx, TOP_ROW
        mov     al, C_TL
        mov     cl, C_TR
        mov     ch, C_TT
        call    frame_row
        ; bottom row
        mov     bx, BOT_ROW
        mov     al, C_BL
        mov     cl, C_BR
        mov     ch, C_BT
        call    frame_row
        ; verticals on file rows
        mov     bx, FIRST_ROW
.vloop:
        cmp     bx, BOT_ROW
        jae     .vdone
        ; col 0
        mov     ax, bx
        imul    ax, ROW_BYTES
        mov     di, ax
        mov     ah, A_FRAME
        mov     al, C_V
        mov     [es:di], ax
        ; col 39 (divider)
        mov     [es:di + 39*2], ax
        ; col 79
        mov     [es:di + 79*2], ax
        inc     bx
        jmp     .vloop
.vdone:
        pop     es
        call    draw_titles
        ret

; draw a frame row: bx=row, al=left char, cl=right char, ch=tee char ----------
; (es already = VIDEO)
frame_row:
        push    bx
        mov     ax, bx
        imul    ax, ROW_BYTES
        mov     di, ax
        pop     bx
        push    cx                  ; save right/tee
        ; left corner
        mov     ah, A_FRAME
        mov     [es:di], al
        mov     [es:di+1], ah
        ; horizontal fill cols 1..78
        add     di, 2
        mov     al, C_H
        mov     cx, 78
.hf:
        mov     [es:di], al
        mov     [es:di+1], ah
        add     di, 2
        loop    .hf
        ; tee at col 39 (di currently at col 79)
        pop     cx                  ; cl=right, ch=tee
        mov     bx, TOP_ROW         ; scratch
        ; right corner at col 79 (di points here)
        mov     al, cl
        mov     [es:di], al
        mov     [es:di+1], ah
        ; tee at col 39
        mov     al, ch
        push    di
        sub     di, (79-39)*2
        mov     [es:di], al
        mov     [es:di+1], ah
        pop     di
        ret

; draw path titles into top frame for both panels ----------------------------
draw_titles:
        ; left
        mov     bx, panelL
        mov     cx, L_CONX
        mov     dx, L_CONW
        call    one_title
        ; right
        mov     bx, panelR
        mov     cx, R_CONX
        mov     dx, R_CONW
        call    one_title
        ret

; bx=panel, cx=content x, dx=content w
one_title:
        push    es
        mov     ax, VIDEO
        mov     es, ax
        ; attr: active panel title highlighted
        mov     al, A_TITLEI
        cmp     bx, [active]
        jne     .a
        mov     al, A_TITLE
.a:
        mov     [tattr], al
        ; compute strlen(path)
        lea     si, [bx+P_PATH]
        call    strlen              ; -> ax = len
        mov     bp, ax              ; bp = path len
        ; field width = dx-2 (leave a space each side)
        mov     di, dx
        sub     di, 2
        ; if len > field, show last (field) chars
        cmp     bp, di
        jbe     .fits
        ; advance si to show tail
        mov     ax, bp
        sub     ax, di
        add     si, ax
        mov     bp, di
.fits:
        ; start col = contentx + (w - (len+2))/2 , centered. Add framing spaces.
        ; compute video offset for row 0
        mov     ax, cx              ; content x
        ; center: startcol = cx + (dx - (bp+2))/2
        mov     bx, dx
        sub     bx, bp
        sub     bx, 2
        shr     bx, 1
        add     ax, bx              ; ax = start col
        push    ax
        ; di = row0 offset
        mov     di, ax
        shl     di, 1               ; col*2 (row 0)
        mov     ah, [tattr]
        ; leading space
        mov     al, ' '
        stosw                       ; note: es=VIDEO, di advances by 2
        ; path chars
        mov     cx, bp
.pl:
        lodsb
        stosw
        loop    .pl
        ; trailing space
        mov     al, ' '
        stosw
        pop     ax
        pop     es
        ret

; ---------------------------------------------------------------------------
; draw one panel's file list. bx=panel ptr, [pcx]=content x, [pcw]=content w
draw_panel:
        mov     [ppanel], bx
        ; for row i in 0..VIS_ROWS-1
        xor     bp, bp              ; bp = visible row index
.row:
        cmp     bp, VIS_ROWS
        jae     .done
        ; build rowbuf (filled with spaces) FIRST -- it clobbers AL
        call    clear_rowbuf
        mov     bx, [ppanel]
        mov     ax, [bx+P_TOP]
        add     ax, bp              ; entry index
        cmp     ax, [bx+P_COUNT]
        jae     .blank              ; past end -> blank row
        ; format entry into rowbuf
        push    ax
        call    entry_ptr           ; ax=index -> si
        call    format_entry        ; si -> rowbuf
        pop     ax
        ; choose attribute
        push    ax
        call    pick_attr           ; ax=index -> al=attr
        mov     [rattr], al
        pop     ax
        jmp     .emit
.blank:
        mov     byte [rattr], A_NORM
.emit:
        ; emit rowbuf at (FIRST_ROW+bp, pcx) width pcw
        push    bp
        mov     ax, FIRST_ROW
        add     ax, bp
        movzx   bx, byte [pcx]
        call    rc_to_off           ; ax=row,bx=col -> di
        mov     si, rowbuf
        movzx   cx, byte [pcw]
        mov     ah, [rattr]
        call    putbuf
        pop     bp
        inc     bp
        jmp     .row
.done:
        call    draw_info
        ret

; choose attribute for entry index ax in panel [ppanel] -> al
pick_attr:
        mov     bx, [ppanel]
        cmp     ax, [bx+P_CUR]
        jne     .notcur
        ; cursor row: active panel cyan, inactive grey
        mov     al, A_CURI
        cmp     bx, [active]
        jne     .ret
        mov     al, A_CUR
        ret
.notcur:
        push    ax
        call    entry_ptr           ; -> si
        pop     ax
        test    byte [si+E_ATTR], 40h
        jnz     .tagged
        mov     al, A_NORM
        test    byte [si+E_ATTR], 10h
        jz      .ret
        mov     al, A_DIR
.ret:
        ret
.tagged:
        mov     al, A_TAG
        ret

; draw info line (bottom frame title) for both panels ------------------------
draw_info:
        ; show current entry size or <DIR> at bottom frame of this panel
        mov     bx, [ppanel]
        mov     cx, [bx+P_COUNT]
        jcxz    .ret
        mov     ax, [bx+P_CUR]
        call    entry_ptr           ; -> si
        ; build "[ name ]" small? For v1 show name in bottom frame title.
        ; We'll just show the highlighted file name centered in bottom border.
        push    es
        mov     ax, VIDEO
        mov     es, ax
        movzx   ax, byte [pcx]
        add     ax, 1               ; start a bit in
        mov     di, ax
        shl     di, 1
        add     di, BOT_ROW*ROW_BYTES
        mov     ah, A_FRAME
        mov     al, ' '
        stosw
        lea     si, [si+E_NAME]
        movzx   cx, byte [pcw]
        sub     cx, 4
.nl:
        lodsb
        or      al, al
        jz      .pad
        stosw
        loop    .nl
        jmp     .sp
.pad:
.sp:
        mov     al, ' '
        stosw
        pop     es
.ret:
        ret

; ---------------------------------------------------------------------------
; command line (row 23): show active path + ">"
draw_cmdline:
        push    es
        mov     ax, VIDEO
        mov     es, ax
        mov     di, CMD_ROW*ROW_BYTES
        ; clear row
        mov     ax, (A_CMD<<8)|' '
        mov     cx, SCR_W
        rep     stosw
        ; write path>
        mov     di, CMD_ROW*ROW_BYTES
        mov     bx, [active]
        lea     si, [bx+P_PATH]
        mov     ah, A_CMD
.pl:
        lodsb
        or      al, al
        jz      .gt
        stosw
        jmp     .pl
.gt:
        mov     al, '>'
        stosw
        ; typed command-line text
        mov     si, cmdbuf
        mov     cx, [cmdlen]
        jcxz    .nocmd
.cl:
        lodsb
        stosw
        loop    .cl
.nocmd:
        pop     es
        ret

; function-key bar (row 24): 10 evenly-spaced 8-column slots. Each slot shows
; the digit(s) in grey-on-black and the label in black-on-cyan, so the keys
; read as separated buttons.
draw_fkeys:
        push    es
        mov     ax, VIDEO
        mov     es, ax
        ; clear the row to grey-on-black (the gaps between buttons)
        mov     di, FKEY_ROW*ROW_BYTES
        mov     ax, (A_FKN<<8)|' '
        mov     cx, SCR_W
        rep     stosw
        xor     bp, bp              ; slot index 0..9
.slot:
        cmp     bp, 10
        jae     .done
        mov     ax, bp             ; di = row base + slot*8 cells
        shl     ax, 4              ; *16 bytes (8 cols * 2)
        add     ax, FKEY_ROW*ROW_BYTES
        mov     di, ax
        mov     bx, bp             ; si = fk_tbl[slot]
        shl     bx, 1
        mov     si, [fk_tbl+bx]
.ch:
        mov     al, [si]
        or      al, al
        jz      .nextslot
        mov     ah, A_FKL          ; label -> black on cyan
        cmp     al, '0'
        jb      .put
        cmp     al, '9'
        ja      .put
        mov     ah, A_FKN          ; digit -> grey on black
.put:
        mov     [es:di], al
        mov     [es:di+1], ah
        add     di, 2
        inc     si
        jmp     .ch
.nextslot:
        inc     bp
        jmp     .slot
.done:
        pop     es
        ret

; ============================================================================
;  DIRECTORY READING
; ============================================================================
; init a panel to the current drive + directory. di = panel ptr
init_panel_cwd:
        push    di
        ; drive letter
        mov     ah, 19h             ; get current drive (0=A)
        int     21h
        add     al, 'A'
        mov     [di+P_PATH], al
        mov     byte [di+P_PATH+1], ':'
        mov     byte [di+P_PATH+2], '\'
        ; current dir (without leading backslash) appended after "C:\"
        push    di
        lea     si, [di+P_PATH+3]
        mov     ah, 47h
        xor     dl, dl              ; current drive
        int     21h
        pop     di
        ; ensure terminator: AH=47h null-terminates. If empty -> "C:\"
        mov     word [di+P_COUNT], 0
        mov     word [di+P_TOP], 0
        mov     word [di+P_CUR], 0
        mov     bx, di
        call    read_dir
        pop     di
        ret

; read directory for panel bx into its entry array, then sort -----------------
read_dir:
        mov     [ppanel], bx
        ; set DTA = dta_buf
        push    dx
        mov     ah, 1Ah
        mov     dx, dta_buf
        int     21h
        pop     dx
        ; build search string "PATH\*.*"
        call    build_search        ; -> srchbuf
        mov     word [_count], 0
        ; FindFirst
        mov     ah, 4Eh
        mov     cx, 37h             ; RO|Hidden|System|Dir|Archive
        mov     dx, srchbuf
        int     21h
        jc      .finish
.loop:
        call    accept_dta
        mov     ah, 4Fh
        int     21h
        jnc     .loop
.finish:
        mov     bx, [ppanel]
        mov     ax, [_count]
        mov     [bx+P_COUNT], ax
        mov     word [bx+P_TOP], 0
        mov     word [bx+P_CUR], 0
        call    sort_panel
        ret

; copy current DTA result into the entry array (if not "." and not root "..")
accept_dta:
        ; skip "." always
        mov     al, [dta_buf+1Eh]
        cmp     al, '.'
        jne     .keep
        mov     al, [dta_buf+1Fh]
        or      al, al
        jz      .skip               ; "."  -> skip
        cmp     al, '.'
        jne     .keep
        ; ".." -> skip if at root
        mov     bx, [ppanel]
        lea     si, [bx+P_PATH]
        call    strlen
        cmp     ax, 3               ; "C:\" == root
        jbe     .skip
.keep:
        mov     ax, [_count]
        cmp     ax, MAX_FILES
        jae     .skip
        call    entry_ptr           ; ax=index -> si = dest
        mov     di, si
        ; copy name (DTA+1Eh) ASCIIZ, max 13
        mov     si, dta_buf+1Eh
        mov     cx, 13
.cpn:
        lodsb
        mov     [di], al
        inc     di
        or      al, al
        jz      .nend
        loop    .cpn
        mov     byte [di], 0
.nend:
        ; attr
        mov     ax, [_count]
        call    entry_ptr           ; -> si=dest base
        mov     al, [dta_buf+15h]
        mov     [si+E_ATTR], al
        ; size dword (DTA+1Ah)
        mov     ax, [dta_buf+1Ah]
        mov     [si+E_SIZE], ax
        mov     ax, [dta_buf+1Ch]
        mov     [si+E_SIZE+2], ax
        ; time / date
        mov     ax, [dta_buf+16h]
        mov     [si+E_TIME], ax
        mov     ax, [dta_buf+18h]
        mov     [si+E_DATE], ax
        inc     word [_count]
.skip:
        ret

; build "PATH\*.*" ASCIIZ into srchbuf (panel = [ppanel]) ---------------------
build_search:
        mov     bx, [ppanel]
        lea     si, [bx+P_PATH]
        mov     di, srchbuf
.cp:
        lodsb
        or      al, al
        jz      .end
        mov     [di], al
        inc     di
        jmp     .cp
.end:
        ; di points after path. Ensure trailing backslash.
        cmp     byte [di-1], '\'
        je      .star
        mov     byte [di], '\'
        inc     di
.star:
        mov     byte [di], '*'
        mov     byte [di+1], '.'
        mov     byte [di+2], '*'
        mov     byte [di+3], 0
        ret

; ============================================================================
;  PATH MANIPULATION
; ============================================================================
; append "\NAME" to active panel path. di -> NAME (ASCIIZ). bx=panel.
path_append:
        mov     si, di              ; si = name
        mov     bx, [active]
        lea     di, [bx+P_PATH]
        call    strlen_di           ; -> ax=len, di at end
        ; if last char != '\' add one
        cmp     byte [di-1], '\'
        je      .nm
        mov     byte [di], '\'
        inc     di
.nm:
        ; copy name
.cn:
        lodsb
        mov     [di], al
        inc     di
        or      al, al
        jnz     .cn
        ret

; go up one directory in active panel path -----------------------------------
path_up:
        mov     bx, [active]
        lea     di, [bx+P_PATH]
        call    strlen_di           ; di at terminator
        ; di-1 = last char. Walk back to previous '\'
        dec     di                  ; last char
.back:
        ; stop if di reaches path+3 (just after "C:\")
        lea     ax, [bx+P_PATH+2]   ; the root backslash position
        cmp     di, ax
        jbe     .root
        cmp     byte [di], '\'
        je      .cut
        dec     di
        jmp     .back
.cut:
        ; di points at a backslash that separates parent\child
        ; if it's the root backslash, keep it (set terminator after it)
        lea     ax, [bx+P_PATH+2]
        cmp     di, ax
        jne     .normal
        mov     byte [di+1], 0
        ret
.normal:
        mov     byte [di], 0
        ret
.root:
        ; already at root "C:\" -> keep terminator after backslash
        mov     byte [bx+P_PATH+3], 0
        ret

; go up a folder in the active panel, leaving the cursor on the child we left
go_parent:
        mov     bx, [active]
        ; capture the last path component of P_PATH into comefrom
        lea     si, [bx+P_PATH]
        mov     di, si
.fend:
        cmp     byte [di], 0
        je      .feod
        inc     di
        jmp     .fend
.feod:
        ; di at terminator; walk back to the separating '\'
.fb:
        cmp     di, si
        jbe     .nolf
        dec     di
        cmp     byte [di], '\'
        jne     .fb
        inc     di                  ; di -> leaf start
        mov     si, di
        mov     di, comefrom
.fc:
        mov     al, [si]
        mov     [di], al
        or      al, al
        jz      .doup
        inc     si
        inc     di
        jmp     .fc
.nolf:
        mov     byte [comefrom], 0
.doup:
        mov     bx, [active]
        call    path_up
        mov     bx, [active]
        call    read_dir
        ; select the remembered child among the parent's entries
        cmp     byte [comefrom], 0
        je      .ret
        mov     bx, [active]
        mov     [ppanel], bx
        mov     cx, [bx+P_COUNT]
        jcxz    .ret
        xor     dx, dx              ; entry index
.scan:
        mov     ax, dx
        call    entry_ptr           ; si -> entry (name at offset 0)
        mov     di, comefrom
        call    streqi              ; CF=1 if equal (cx/dx preserved)
        jc      .found
        inc     dx
        cmp     dx, cx
        jb      .scan
        ret                         ; not found -> cursor stays at top
.found:
        mov     bx, [active]
        mov     [bx+P_CUR], dx
        call    fix_scroll
.ret:
        ret

; ============================================================================
;  SORT (insertion sort on entry array; dirs first, ".." first, name asc)
; ============================================================================
sort_panel:
        mov     bx, [ppanel]
        mov     cx, [bx+P_COUNT]
        cmp     cx, 2
        jb      .done
        mov     bp, 1               ; i
.outer:
        cmp     bp, cx
        jae     .done
        ; temp = entry[i]
        mov     ax, bp
        call    entry_ptr           ; -> si
        mov     di, sort_tmp
        push    cx
        mov     cx, ENTSIZE
        rep     movsb
        pop     cx
        ; j = i-1
        mov     dx, bp
        dec     dx                  ; j (signed via comparisons)
.inner:
        ; while j>=0 and order(entry[j], tmp) > 0
        ; check j>=0
        cmp     dx, 0
        jl      .place
        mov     ax, dx
        call    entry_ptr           ; -> si = entry[j]
        mov     di, sort_tmp
        push    cx
        push    dx
        call    order_cmp           ; si vs di -> ax (>0 means si after di)
        pop     dx
        pop     cx
        or      ax, ax
        jle     .place
        ; entry[j+1] = entry[j]
        mov     ax, dx
        call    entry_ptr           ; si = entry[j]
        push    si
        mov     ax, dx
        inc     ax
        call    entry_ptr           ; si = entry[j+1] (dest)
        mov     di, si
        pop     si
        push    cx
        mov     cx, ENTSIZE
        rep     movsb
        pop     cx
        dec     dx
        jmp     .inner
.place:
        ; entry[j+1] = tmp
        mov     ax, dx
        inc     ax
        call    entry_ptr           ; -> si dest
        mov     di, si
        mov     si, sort_tmp
        push    cx
        mov     cx, ENTSIZE
        rep     movsb
        pop     cx
        inc     bp
        jmp     .outer
.done:
        ret

; compare two entries by sort order. si=A, di=B.
; returns ax > 0 if A should come AFTER B; <0 before; 0 equal.
order_cmp:
        push    si
        push    di
        ; rank: ".." =0, dir=1, file=2
        call    rank_of             ; si -> al
        mov     bl, al
        xchg    si, di
        call    rank_of
        mov     bh, al
        xchg    si, di
        ; compare ranks
        mov     al, bl
        sub     al, bh              ; rankA - rankB
        cbw
        or      ax, ax
        jnz     .ret
        ; same rank -> case-insensitive name compare
        lea     si, [si+E_NAME]
        lea     di, [di+E_NAME]
        call    strcmp_ci           ; -> ax
.ret:
        pop     di
        pop     si
        ret

; rank of entry at si -> al (0=="..",1=dir,2=file)
rank_of:
        mov     al, [si+E_NAME]
        cmp     al, '.'
        jne     .notdd
        cmp     byte [si+E_NAME+1], '.'
        jne     .notdd
        cmp     byte [si+E_NAME+2], 0
        jne     .notdd
        xor     al, al              ; ".." -> 0
        ret
.notdd:
        test    byte [si+E_ATTR], 10h
        jz      .file
        mov     al, 1
        ret
.file:
        mov     al, 2
        ret

; ============================================================================
;  FORMATTING
; ============================================================================
; format entry (si) into rowbuf (already space-filled to [pcw]):
;   name left-justified, then size (or <DIR>/<UP>) right-justified.
SIZEW       equ 8
format_entry:
        push    si
        mov     di, rowbuf
        ; name field width = pcw - SIZEW - 1
        movzx   cx, byte [pcw]
        sub     cx, SIZEW+1
        lea     si, [si+E_NAME]
.nl:
        mov     al, [si]
        or      al, al
        jz      .ndone
        mov     [di], al
        inc     di
        inc     si
        loop    .nl
.ndone:
        pop     si
        ; size field at rowbuf + (pcw - SIZEW)
        movzx   bx, byte [pcw]
        sub     bx, SIZEW
        lea     di, [rowbuf+bx]
        ; ".." -> "<UP>", dir -> "<DIR>", file -> decimal size
        mov     al, [si+E_NAME]
        cmp     al, '.'
        jne     .chkdir
        cmp     byte [si+E_NAME+1], '.'
        jne     .chkdir
        mov     si, str_up
        jmp     .putlabel
.chkdir:
        test    byte [si+E_ATTR], 10h
        jz      .num
        mov     si, str_dir
.putlabel:
        ; right-justify label in SIZEW field
        push    si
        call    strlen              ; ax=len
        mov     cx, SIZEW
        sub     cx, ax              ; leading spaces
        add     di, cx
        pop     si
.lp:
        mov     al, [si]
        or      al, al
        jz      .ret
        mov     [di], al
        inc     di
        inc     si
        jmp     .lp
.num:
        ; format dword size right-justified into SIZEW field
        mov     ax, [si+E_SIZE]
        mov     dx, [si+E_SIZE+2]
        ; di -> field start; produce into numbuf then right-justify
        call    u32toa              ; dx:ax -> numbuf, returns cx=len, si=numbuf
        mov     bx, SIZEW
        sub     bx, cx              ; leading spaces
        add     di, bx
.cp:
        mov     al, [si]
        or      al, al
        jz      .ret
        mov     [di], al
        inc     di
        inc     si
        jmp     .cp
.ret:
        ret

; fill rowbuf with [pcw] spaces, null-terminate
clear_rowbuf:
        mov     di, rowbuf
        movzx   cx, byte [pcw]
        mov     al, ' '
        push    cx
        rep     stosb
        pop     cx
        mov     byte [rowbuf+0], ' '   ; (already) ; ensure
        ; null terminator just past field
        movzx   bx, byte [pcw]
        mov     byte [rowbuf+bx], 0
        ret

; unsigned 32-bit dx:ax -> decimal ASCII (left aligned) ending at numbuf+15.
; returns si=first digit, cx=length.
u32toa:
        push    di                  ; preserve caller's di (it builds output position)
        mov     di, numbuf+15
        mov     byte [di], 0
.dl:
        ; divide dx:ax by 10 -> quotient in (si:ax), remainder in dx
        mov     cx, ax              ; save low
        mov     ax, dx              ; high
        xor     dx, dx
        mov     bx, 10
        div     bx                  ; ax = high/10 , dx = high%10
        mov     si, ax              ; quotient high
        mov     ax, cx              ; low
        div     bx                  ; ax = quotient low , dx = remainder digit
        add     dl, '0'
        dec     di
        mov     [di], dl
        mov     dx, si              ; dx:ax = quotient
        mov     cx, ax
        or      cx, dx
        jnz     .dl
        mov     si, di              ; first digit (build pointer)
        mov     cx, numbuf+15
        sub     cx, si              ; length = end - start
        pop     di                  ; restore caller's di
        ret

; ============================================================================
;  SMALL HELPERS
; ============================================================================
; ax=index -> si = &panel[ppanel].entries[index]
entry_ptr:
        push    ax
        push    dx
        mov     dx, ENTSIZE
        mul     dx                  ; dx:ax = index*ENTSIZE  (index<700 -> no carry)
        mov     si, [ppanel]
        add     si, P_ENTRIES
        add     si, ax
        pop     dx
        pop     ax
        ret

; bx=panel -> si = entry at cursor
cur_entry_ptr:
        push    ax
        mov     [ppanel], bx
        mov     ax, [bx+P_CUR]
        call    entry_ptr
        pop     ax
        ret

; si -> ax = strlen (si preserved)
strlen:
        push    si
        xor     ax, ax
.l:
        cmp     byte [si], 0
        je      .e
        inc     si
        inc     ax
        jmp     .l
.e:
        pop     si
        ret

; di advanced to its NUL terminator (di on entry -> string)
strlen_di:
.l:
        cmp     byte [di], 0
        je      .e
        inc     di
        jmp     .l
.e:
        ret

; case-insensitive compare ds:si vs ds:di -> ax (<0,0,>0). si/di clobbered.
strcmp_ci:
.l:
        mov     al, [si]
        mov     bl, [di]
        cmp     al, 'A'
        jb      .a1
        cmp     al, 'Z'
        ja      .a1
        add     al, 20h
.a1:
        cmp     bl, 'A'
        jb      .b1
        cmp     bl, 'Z'
        ja      .b1
        add     bl, 20h
.b1:
        cmp     al, bl
        jne     .diff
        or      al, al
        jz      .eq
        inc     si
        inc     di
        jmp     .l
.diff:
        sub     al, bl
        cbw
        ret
.eq:
        xor     ax, ax
        ret

; ax=row, bx=col -> di = byte offset into video
rc_to_off:
        push    ax
        push    dx
        mov     dx, ROW_BYTES
        mul     dx
        mov     di, ax
        shl     bx, 1
        add     di, bx
        shr     bx, 1
        pop     dx
        pop     ax
        ret

; write cx chars from ds:si to video at di, attribute ah
putbuf:
        push    es
        push    ax
        mov     ax, VIDEO
        mov     es, ax
        pop     ax                  ; restore ah=attr
.l:
        mov     al, [si]
        mov     [es:di], al
        mov     [es:di+1], ah
        inc     si
        add     di, 2
        loop    .l
        pop     es
        ret

hide_cursor:
        mov     ah, 1
        mov     cx, 2000h
        int     10h
        ret
show_cursor:
        mov     ah, 1
        mov     cx, 0607h
        int     10h
        ret

; ============================================================================
;  TEST-MODE: screen dump + scripted keys
; ============================================================================
open_dump:
        mov     ah, 3Ch
        xor     cx, cx
        mov     dx, dumpname
        int     21h
        jc      .err
        mov     [dumph], ax
        ret
.err:
        mov     word [dumph], 0FFFFh
        ret

close_dump:
        mov     bx, [dumph]
        cmp     bx, 0FFFFh
        je      .r
        mov     ah, 3Eh
        int     21h
.r:
        ret

dump_screen:
        mov     bx, [dumph]
        cmp     bx, 0FFFFh
        je      .r
        push    es
        xor     bp, bp              ; row
.row:
        cmp     bp, SCR_H
        jae     .sep
        mov     ax, VIDEO
        mov     es, ax
        mov     ax, bp
        mov     dx, ROW_BYTES
        mul     dx
        mov     si, ax              ; video source offset
        mov     di, linebuf
        mov     cx, SCR_W
.col:
        mov     al, [es:si]
        mov     [di], al
        inc     di
        add     si, 2
        loop    .col
        mov     word [di], 0A0Dh    ; CR,LF
        mov     cx, SCR_W+2
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
.r:
        ret

load_keys:
        mov     ah, 3Dh
        xor     al, al
        mov     dx, keyname
        int     21h
        jc      .none
        mov     bx, ax
        mov     ah, 3Fh
        mov     cx, KEYBUF_MAX
        mov     dx, keybuf
        int     21h
        mov     [keylen], ax
        mov     ah, 3Eh
        int     21h
        ret
.none:
        mov     word [keylen], 0
        ret

; -> al=ascii, ah=scan
get_key:
        cmp     byte [test_mode], 0
        je      .live
        cmp     byte [want_keys], 0
        je      .quit
        mov     bx, [keypos]
        cmp     bx, [keylen]
        jae     .quit
        mov     al, [keybuf+bx]
        mov     ah, [keybuf+bx+1]
        add     word [keypos], 2
        ret
.quit:
        xor     al, al
        mov     ah, 44h             ; simulate F10
        ret
.live:
        cmp     byte [mouse_ok], 0
        je      .kbonly
.poll:
        mov     ah, 1               ; keystroke waiting?
        int     16h
        jnz     .kbonly
        call    mouse_poll          ; CF=1 -> ax = synthetic key
        jc      .mret
        jmp     .poll
.kbonly:
        mov     ah, 00h             ; legacy read: gray arrows -> al=0, ah=scan
        int     16h
.mret:
        ret

; ============================================================================
;  COMMAND EXECUTION  (shell out to COMSPEC /C <cmdline>)
; ============================================================================
%include "mod/shell.inc"
; ============================================================================
;  MODAL DIALOGS  (shared by file operations)
; ============================================================================
DLG_R0  equ 9
DLG_R1  equ 13
DLG_C0  equ 14
DLG_C1  equ 65
A_DLG   equ 030h            ; black on cyan (box + prompt)
A_DLGF  equ 070h            ; black on grey (input field)
A_BTN   equ 03Fh            ; bright white on cyan (unfocused button)
A_BTNSEL equ 070h           ; black on white (focused button)
; confirm-dialog button geometry (row + column spans), symmetric in the box
BTN_ROW equ DLG_R0+3
YES_C0  equ 28
YES_C1  equ 34              ; "[ Yes ]" (7 cols)
NO_C0   equ 45
NO_C1   equ 50              ; "[ No ]"  (6 cols)
; overwrite-dialog button geometry: [Overwrite] [Skip] [All] [Cancel]
OWR_C0  equ 17
OWR_C1  equ 27              ; "[Overwrite]" (11 cols)
SKP_C0  equ 31
SKP_C1  equ 36              ; "[Skip]" (6 cols)
OAL_C0  equ 40
OAL_C1  equ 44              ; "[All]" (5 cols)
CAN_C0  equ 48
CAN_C1  equ 55              ; "[Cancel]" (8 cols)
; mouse routing modes
MM_BROWSER  equ 0
MM_OFF      equ 1
MM_CONFIRM  equ 2
MM_OWRITE   equ 3

; draw the double-line dialog box + clear interior
dlg_box:
        push    es
        mov     ax, VIDEO
        mov     es, ax
        mov     bx, DLG_R0
.row:
        mov     ax, bx
        imul    ax, ROW_BYTES
        add     ax, DLG_C0*2
        mov     di, ax
        mov     si, DLG_C0
.col:
        call    dlg_cell            ; bx=row si=col -> al=char
        mov     ah, A_DLG
        mov     [es:di], ax
        add     di, 2
        inc     si
        cmp     si, DLG_C1
        jbe     .col
        inc     bx
        cmp     bx, DLG_R1
        jbe     .row
        pop     es
        ret

; pick the CP437 char for cell (bx=row, si=col) -> al
dlg_cell:
        cmp     bx, DLG_R0
        je      .top
        cmp     bx, DLG_R1
        je      .bot
        cmp     si, DLG_C0
        je      .v
        cmp     si, DLG_C1
        je      .v
        mov     al, ' '
        ret
.v:     mov     al, 0BAh            ; vertical
        ret
.top:
        cmp     si, DLG_C0
        je      .tl
        cmp     si, DLG_C1
        je      .tr
        mov     al, 0CDh            ; horizontal
        ret
.tl:    mov     al, 0C9h
        ret
.tr:    mov     al, 0BBh
        ret
.bot:
        cmp     si, DLG_C0
        je      .bl
        cmp     si, DLG_C1
        je      .br
        mov     al, 0CDh
        ret
.bl:    mov     al, 0C8h
        ret
.br:    mov     al, 0BCh
        ret

; write ASCIIZ ds:si at es:di (es set to VIDEO here), attribute ah; di advances
putzstr:
        push    es
        push    ax
        mov     ax, VIDEO
        mov     es, ax
        pop     ax
.l:     mov     al, [si]
        or      al, al
        jz      .e
        mov     [es:di], al
        mov     [es:di+1], ah
        inc     si
        add     di, 2
        jmp     .l
.e:     pop     es
        ret

; ----------------------------------------------------------------------------
; progress / "please wait" box, shown during long copy/delete operations so the
; screen doesn't look frozen. busy_box draws the frame + title once; busy_name
; updates the second line with the item currently being processed. Both save
; every register so they can be sprinkled inside the recursive tree walkers.
; ----------------------------------------------------------------------------
busy_box:                       ; ds:si = title
        pusha
        push    es
        call    mouse_hide
        call    dlg_box
        mov     ax, DLG_R0+1
        mov     bx, DLG_C0+2
        call    rc_to_off
        mov     ah, A_DLG
        call    putzstr
        pop     es
        popa
        ret

busy_name:                      ; ds:si = ASCIIZ name/path (clipped to box width)
        pusha
        push    es
        mov     ax, VIDEO
        mov     es, ax
        mov     ax, DLG_R0+2
        mov     bx, DLG_C0+2
        call    rc_to_off           ; di = row start
        mov     dx, DLG_C1-DLG_C0-3 ; interior width
        mov     cx, dx
        push    di
.clr:   mov     byte [es:di], ' '
        mov     byte [es:di+1], A_DLG
        add     di, 2
        loop    .clr
        pop     di
        mov     cx, dx
.wr:    mov     al, [si]
        or      al, al
        jz      .done
        jcxz    .done
        mov     [es:di], al
        mov     byte [es:di+1], A_DLG
        inc     si
        add     di, 2
        dec     cx
        jmp     .wr
.done:
        pop     es
        popa
        ret

; input dialog: si=prompt. Text -> dlgbuf (NUL-term) + dlglen. CF=1 if cancelled.
dlg_input:
        mov     [dlg_prompt], si
        call    dlg_box
        mov     ax, DLG_R0+1
        mov     bx, DLG_C0+2
        call    rc_to_off
        mov     si, [dlg_prompt]
        mov     ah, A_DLG
        call    putzstr
        mov     word [dlglen], 0
        mov     byte [mouse_mode], MM_OFF
.loop:
        call    dlg_field
        call    get_key
        cmp     al, 0Dh
        je      .ok
        cmp     al, 1Bh
        je      .cancel
        cmp     al, 08h
        je      .bksp
        cmp     al, 20h
        jb      .loop
        cmp     al, 7Eh
        ja      .loop
        mov     bx, [dlglen]
        cmp     bx, 40
        jae     .loop
        mov     [dlgbuf+bx], al
        inc     word [dlglen]
        jmp     .loop
.bksp:
        cmp     word [dlglen], 0
        je      .loop
        dec     word [dlglen]
        jmp     .loop
.ok:
        mov     byte [mouse_mode], MM_BROWSER
        mov     bx, [dlglen]
        mov     byte [dlgbuf+bx], 0
        clc
        ret
.cancel:
        mov     byte [mouse_mode], MM_BROWSER
        mov     word [dlglen], 0
        mov     byte [dlgbuf], 0
        stc
        ret

; redraw the input field row with current dlgbuf + trailing cursor
dlg_field:
        push    es
        mov     ax, VIDEO
        mov     es, ax
        mov     ax, DLG_R0+2
        mov     bx, DLG_C0+2
        call    rc_to_off
        mov     cx, DLG_C1-DLG_C0-3
        mov     ah, A_DLGF
        push    di
.clr:   mov     byte [es:di], ' '
        mov     [es:di+1], ah
        add     di, 2
        loop    .clr
        pop     di
        mov     si, dlgbuf
        mov     cx, [dlglen]
        jcxz    .cur
.wr:    mov     al, [si]
        mov     [es:di], al
        mov     [es:di+1], ah
        inc     si
        add     di, 2
        loop    .wr
.cur:
        mov     byte [es:di], '_'
        mov     [es:di+1], ah
        pop     es
        ret

; confirm dialog: si=message. CF=0 if YES, CF=1 if NO.
; Navigable: Left/Right/Tab move focus, Enter/Space activate, Y/N shortcut,
; Esc = No, and the Yes/No buttons are mouse-clickable.
dlg_confirm:
        mov     [dlg_prompt], si
        mov     byte [dlg_focus], 0     ; default focus = Yes
        call    dlg_box
        mov     ax, DLG_R0+1
        mov     bx, DLG_C0+2
        call    rc_to_off
        mov     si, [dlg_prompt]
        mov     ah, A_DLG
        call    putzstr
        mov     byte [mouse_mode], MM_CONFIRM
.draw:
        call    dlg_draw_buttons
        cmp     byte [test_mode], 0
        jz      .k
        call    dump_screen         ; test harness: capture the dialog frame
.k:
        call    get_key
        cmp     al, 'y'
        je      .yes
        cmp     al, 'Y'
        je      .yes
        cmp     al, 'n'
        je      .no
        cmp     al, 'N'
        je      .no
        cmp     al, 1Bh             ; Esc -> No
        je      .no
        cmp     al, 0Dh             ; Enter -> activate focus
        je      .activate
        cmp     al, 20h             ; Space -> activate focus
        je      .activate
        cmp     al, 09h             ; Tab -> toggle focus
        je      .toggle
        or      al, al
        jnz     .k                  ; other ascii: ignore
        cmp     ah, 4Bh             ; Left  -> focus Yes
        je      .focusy
        cmp     ah, 4Dh             ; Right -> focus No
        je      .focusn
        jmp     .k
.toggle:
        xor     byte [dlg_focus], 1
        jmp     .draw
.focusy:
        mov     byte [dlg_focus], 0
        jmp     .draw
.focusn:
        mov     byte [dlg_focus], 1
        jmp     .draw
.activate:
        cmp     byte [dlg_focus], 0
        je      .yes
        jmp     .no
.yes:
        mov     byte [mouse_mode], MM_BROWSER
        clc
        ret
.no:
        mov     byte [mouse_mode], MM_BROWSER
        stc
        ret

; draw the Yes/No buttons, highlighting the one with focus
dlg_draw_buttons:
        mov     ax, BTN_ROW
        mov     bx, YES_C0
        call    rc_to_off
        mov     si, s_btn_yes
        mov     ah, A_BTN
        cmp     byte [dlg_focus], 0
        jne     .y2
        mov     ah, A_BTNSEL
.y2:    call    putzstr
        mov     ax, BTN_ROW
        mov     bx, NO_C0
        call    rc_to_off
        mov     si, s_btn_no
        mov     ah, A_BTN
        cmp     byte [dlg_focus], 1
        jne     .n2
        mov     ah, A_BTNSEL
.n2:    call    putzstr
        ret

; ----------------------------------------------------------------------------
; overwrite prompt: ds:si = name of the file about to be overwritten.
; Returns the choice in al: 0=overwrite, 1=skip, 2=overwrite All, 3=cancel.
; Keyboard O/S/A/C(+Esc), Enter/Space activate the focused button, Left/Right
; and Tab move focus, and all four buttons are mouse-clickable.
; ----------------------------------------------------------------------------
dlg_overwrite:
        mov     [dlg_prompt], si       ; stash the filename pointer
        mov     byte [ow_focus], 0     ; default focus = Overwrite
        call    mouse_show             ; copy hid the cursor; show it for clicks
        call    dlg_box
        mov     ax, DLG_R0+1
        mov     bx, DLG_C0+2
        call    rc_to_off
        mov     si, s_owmsg
        mov     ah, A_DLG
        call    putzstr
        mov     si, [dlg_prompt]
        call    busy_name              ; draws the clipped filename on line 2
        mov     byte [mouse_mode], MM_OWRITE
.draw:
        call    ow_draw_buttons
        cmp     byte [test_mode], 0
        jz      .k
        call    dump_screen
.k:
        call    get_key
        cmp     al, 'o'
        je      .ovr
        cmp     al, 'O'
        je      .ovr
        cmp     al, 's'
        je      .skp
        cmp     al, 'S'
        je      .skp
        cmp     al, 'a'
        je      .all
        cmp     al, 'A'
        je      .all
        cmp     al, 'c'
        je      .can
        cmp     al, 'C'
        je      .can
        cmp     al, 1Bh             ; Esc -> cancel
        je      .can
        cmp     al, 0Dh             ; Enter -> activate focus
        je      .activate
        cmp     al, 20h             ; Space -> activate focus
        je      .activate
        cmp     al, 09h             ; Tab -> next focus
        je      .tabf
        or      al, al
        jnz     .k
        cmp     ah, 4Bh             ; Left
        je      .leftf
        cmp     ah, 4Dh             ; Right
        je      .rightf
        jmp     .k
.tabf:
        mov     al, [ow_focus]
        inc     al
        cmp     al, 4
        jb      .setf
        xor     al, al
.setf:  mov     [ow_focus], al
        jmp     .draw
.leftf:
        mov     al, [ow_focus]
        or      al, al
        jz      .draw
        dec     al
        mov     [ow_focus], al
        jmp     .draw
.rightf:
        mov     al, [ow_focus]
        cmp     al, 3
        jae     .draw
        inc     al
        mov     [ow_focus], al
        jmp     .draw
.activate:
        mov     al, [ow_focus]
        cmp     al, 0
        je      .ovr
        cmp     al, 1
        je      .skp
        cmp     al, 2
        je      .all
        jmp     .can
.ovr:   mov     al, 0
        jmp     .done
.skp:   mov     al, 1
        jmp     .done
.all:   mov     al, 2
        jmp     .done
.can:   mov     al, 3
.done:
        mov     byte [mouse_mode], MM_BROWSER
        call    mouse_hide             ; restore the during-copy hidden state
        ret

; draw the four overwrite buttons, highlighting the focused one
ow_draw_buttons:
        mov     bx, OWR_C0
        mov     si, s_btn_ovr
        xor     cx, cx
        call    ow_one_btn
        mov     bx, SKP_C0
        mov     si, s_btn_skp
        mov     cx, 1
        call    ow_one_btn
        mov     bx, OAL_C0
        mov     si, s_btn_all
        mov     cx, 2
        call    ow_one_btn
        mov     bx, CAN_C0
        mov     si, s_btn_can
        mov     cx, 3
        call    ow_one_btn
        ret

; draw one button: bx=col, ds:si=label, cl=button index; highlight if focused
ow_one_btn:
        push    ax
        mov     ax, BTN_ROW
        call    rc_to_off
        mov     ah, A_BTN
        cmp     cl, [ow_focus]
        jne     .w
        mov     ah, A_BTNSEL
.w:     call    putzstr
        pop     ax
        ret

; ============================================================================
;  PATH BUILDERS for file ops
;    targpath  = source / existing entry's full path
;    targpath2 = destination / new name
; ============================================================================
; targpath = active-panel path + '\' + current entry name. si=entry (preserved).
build_entry_path:
        push    si
        mov     bx, [active]
        lea     si, [bx+P_PATH]
        mov     di, targpath
        call    bp_copy_dir
        pop     si
        push    si
        lea     si, [si+E_NAME]
        call    bp_copy_name
        pop     si
        ret

; targpath2 = active-panel path + '\' + dlgbuf  (mkdir / rename target)
build_target_path:
        mov     bx, [active]
        lea     si, [bx+P_PATH]
        mov     di, targpath2
        call    bp_copy_dir
        mov     si, dlgbuf
        call    bp_copy_name
        ret

; targpath2 = OTHER-panel path + '\' + current entry name. si=entry (preserved).
build_other_path:
        push    si
        call    other_panel_ptr     ; -> bx
        lea     si, [bx+P_PATH]
        mov     di, targpath2
        call    bp_copy_dir
        pop     si
        push    si
        lea     si, [si+E_NAME]
        call    bp_copy_name
        pop     si
        ret

; copy ASCIIZ dir ds:si -> es?no, ds:di, ensure trailing '\'. di left past it.
bp_copy_dir:
.cp:    mov     al, [si]
        or      al, al
        jz      .e
        mov     [di], al
        inc     di
        inc     si
        jmp     .cp
.e:     cmp     byte [di-1], '\'
        je      .done
        mov     byte [di], '\'
        inc     di
.done:  ret

; append ASCIIZ name ds:si -> ds:di (including terminator)
bp_copy_name:
.c:     mov     al, [si]
        mov     [di], al
        or      al, al
        jz      .done
        inc     di
        inc     si
        jmp     .c
.done:  ret

; bx = the panel that is NOT active
other_panel_ptr:
        mov     bx, [active]
        cmp     bx, panelL
        jne     .l
        mov     bx, panelR
        ret
.l:     mov     bx, panelL
        ret

; ============================================================================
;  FILE OPERATIONS
; ============================================================================
; re-read both panels (so a directory shown in both stays in sync after an op)
refresh_panels:
        mov     bx, panelL
        call    read_dir
        mov     bx, panelR
        call    read_dir
        ret

%include "mod/fileops.inc"
%include "mod/recurse.inc"
%include "mod/mouse.inc"
; BIOS tick counter low word (0040:006Ch) -> ax
get_tick:
        push    es
        push    bx
        xor     bx, bx
        mov     es, bx
        mov     ax, [es:046Ch]
        pop     bx
        pop     es
        ret

; map a click column [m_col] on the F-key bar to a synthetic key in ax.
; The bar is 10 even slots of 8 cols; slot = col/8, F-number = slot+1.
fbar_to_key:
        mov     ax, [m_col]
        shr     ax, 3               ; slot 0..9
        cmp     ax, 2
        je      .f3
        cmp     ax, 4
        je      .f5
        cmp     ax, 5
        je      .f6
        cmp     ax, 6
        je      .f7
        cmp     ax, 7
        je      .f8
        cmp     ax, 9
        je      .f10
.none:  xor     ax, ax
        ret
.f3:    mov     ax, 3D00h
        ret
.f5:    mov     ax, 3F00h
        ret
.f6:    mov     ax, 4000h
        ret
.f7:    mov     ax, 4100h
        ret
.f8:    mov     ax, 4200h
        ret
.f10:   mov     ax, 4400h
        ret

; F6 -- rename / move current entry to a name typed in a dialog
key_rename:
        mov     bx, [active]
        mov     cx, [bx+P_COUNT]
        jcxz    .ret
        call    cur_entry_ptr
        mov     al, [si+E_NAME]
        cmp     al, '.'
        jne     .ok
        cmp     byte [si+E_NAME+1], '.'
        je      .ret
.ok:
        push    si
        mov     si, s_rename
        call    dlg_input
        pop     si
        jc      .ret
        cmp     word [dlglen], 0
        je      .ret
        call    build_entry_path    ; targpath  = old full path
        call    build_target_path   ; targpath2 = active\newname
        push    ds
        pop     es
        mov     dx, targpath        ; ds:dx old
        mov     di, targpath2       ; es:di new
        mov     ah, 56h
        int     21h
        call    refresh_panels
.ret:   ret

; copy file targpath -> targpath2 (512-byte chunks)
copy_file:
        cmp     byte [ow_cancel], 0
        jne     .ret                ; whole operation was cancelled
        mov     si, targpath        ; show what we're copying (anti-"frozen")
        call    busy_name
        ; overwrite policy: does the destination already exist?
        mov     ax, 4300h           ; get file attributes
        mov     dx, targpath2
        int     21h
        jc      .open               ; not found -> copy freely
        cmp     byte [ow_mode], 1
        je      .open               ; overwrite-all
        cmp     byte [ow_mode], 2
        je      .ret                ; skip-all
        mov     si, targpath2       ; ask: returns al = 0/1/2/3
        call    dlg_overwrite
        push    ax
        mov     si, s_busy_copy     ; the dialog clobbered the progress box
        call    busy_box
        mov     si, targpath
        call    busy_name
        pop     ax
        cmp     al, 1
        je      .ret                ; Skip this one
        cmp     al, 2
        je      .all
        cmp     al, 3
        je      .cancel
        jmp     .open               ; 0 = Overwrite this one
.all:
        mov     byte [ow_mode], 1
        jmp     .open
.cancel:
        mov     byte [ow_cancel], 1
        ret
.open:
        mov     ax, 3D00h           ; open src read-only
        mov     dx, targpath
        int     21h
        jc      .ret
        mov     [fh_src], ax
        xor     cx, cx              ; create dst (normal attr)
        mov     ah, 3Ch
        mov     dx, targpath2
        int     21h
        jc      .closesrc
        mov     [fh_dst], ax
.loop:
        mov     ah, 3Fh
        mov     bx, [fh_src]
        mov     cx, 512
        mov     dx, copybuf
        int     21h
        jc      .closeall
        or      ax, ax
        jz      .closeall           ; EOF
        mov     cx, ax
        mov     ah, 40h
        mov     bx, [fh_dst]
        mov     dx, copybuf
        int     21h
        jmp     .loop
.closeall:
        mov     ah, 3Eh
        mov     bx, [fh_dst]
        int     21h
.closesrc:
        mov     ah, 3Eh
        mov     bx, [fh_src]
        int     21h
.ret:   ret

; Insert -- toggle tag on current entry, advance cursor
key_tag:
        mov     bx, [active]
        mov     cx, [bx+P_COUNT]
        jcxz    .ret
        call    cur_entry_ptr
        mov     al, [si+E_NAME]
        cmp     al, '.'
        jne     .t
        cmp     byte [si+E_NAME+1], '.'
        je      .down               ; never tag ".."
.t:     xor     byte [si+E_ATTR], 40h
.down:
        call    key_down
.ret:   ret

; Alt+F1 / Alt+F2 -- switch a panel's drive (prompt for a letter)
key_drive_l:
        mov     bx, panelL
        jmp     set_panel_drive
key_drive_r:
        mov     bx, panelR
        jmp     set_panel_drive
set_panel_drive:
        push    bx
        mov     si, s_drive
        call    dlg_input
        pop     bx
        jc      .ret
        cmp     word [dlglen], 0
        je      .ret
        mov     al, [dlgbuf]
        cmp     al, 'a'
        jb      .u
        cmp     al, 'z'
        ja      .u
        sub     al, 20h
.u:
        mov     [bx+P_PATH], al
        mov     byte [bx+P_PATH+1], ':'
        mov     byte [bx+P_PATH+2], '\'
        mov     byte [bx+P_PATH+3], 0
        mov     word [bx+P_CUR], 0
        mov     word [bx+P_TOP], 0
        call    read_dir
.ret:   ret

; ============================================================================
;  F3 -- FILE VIEWER  (reads up to VIEW_MAX bytes, scrolls by line)
; ============================================================================
VIEW_MAX    equ 16384
MAX_VLINES  equ 1024
VIEW_ROWS   equ 23             ; text rows 1..23 (row 0 header, row 24 bar)
A_VHDR      equ 030h           ; black on cyan header
A_VTXT      equ 007h           ; grey on black text
A_VBAR      equ 030h           ; black on cyan bottom bar

%include "mod/viewer.inc"
%include "mod/harness.inc"

; ============================================================================
;  INITIALIZED DATA
; ============================================================================
; function-key bar: 10 labels, one per 8-column slot (drawn by draw_fkeys)
fk_tbl      dw fk0,fk1,fk2,fk3,fk4,fk5,fk6,fk7,fk8,fk9
fk0         db '1Help',0
fk1         db '2Menu',0
fk2         db '3View',0
fk3         db '4Edit',0
fk4         db '5Copy',0
fk5         db '6Move',0
fk6         db '7MkDir',0
fk7         db '8Del',0
fk8         db '9Menu',0
fk9         db '10Quit',0
str_dir     db '<DIR>',0
str_up      db '<UP>',0
dumpname    db 'CCDUMP.TXT',0
snapname    db 'CCSNAP.BIN',0
keyname     db 'cc.key',0
dumpsep     db '==== FRAME ====',0Dh,0Ah
dumpsep_len equ $-dumpsep
dbg_cnt     db 'count=',0
s_comspec   db 'COMSPEC=',0
s_defcom    db 'COMMAND.COM',0
s_slashc    db ' /C ',0
s_exe       db 'EXE'
s_com       db 'COM'
s_bat       db 'BAT'
s_runmsg    db 0Dh,0Ah,'[Claude Commander] running command...',0Dh,0Ah,'$'
s_anykey    db 0Dh,0Ah,'Press any key to return to Claude Commander...',0Dh,0Ah,'$'
s_mkdir     db 'Create directory:',0
s_rename    db 'Rename/move current entry to:',0
s_drive     db 'Switch to drive (A-Z):',0
s_delconf   db 'Delete the current entry?',0
s_copyconf  db 'Copy this file to the other panel?',0
s_busy_copy db 'Copying, please wait...',0
s_busy_del  db 'Deleting, please wait...',0
s_btn_yes   db '[ Yes ]',0
s_btn_no    db '[ No ]',0
s_owmsg     db 'File exists - overwrite?',0
s_btn_ovr   db '[Overwrite]',0
s_btn_skp   db '[Skip]',0
s_btn_all   db '[All]',0
s_btn_can   db '[Cancel]',0
s_viewhdr   db '   [ View ]',0
s_viewbar   db ' Up/Dn PgUp/PgDn Home/End: scroll      Esc or F3: quit',0

active      dw 0
ppanel      dw 0
quit_flag   db 0
test_mode   db 0
want_keys   db 0
count_dbg   db 0
snap_mode   db 0
orig_mode   db 3
pcx         db 0
pcw         db 0
tattr       db 0
rattr       db 0
_count      dw 0
keypos      dw 0
keylen      dw 0
dumph       dw 0FFFFh

; ============================================================================
;  RESERVED BUFFERS  (must stay LAST so the .COM emits no bytes for them)
; ============================================================================
KEYBUF_MAX  equ 512
section .bss
align 2
rowbuf      resb 84
numbuf      resb 16
srchbuf     resb 80
sort_tmp    resb ENTSIZE
linebuf     resb 84
keybuf      resb KEYBUF_MAX
dta_buf     resb 64
cmdbuf      resb 130
cmdlen      resw 1
cmdtail     resb 132
comspec_buf resb 80
epb         resb 16
save_sp     resw 1
save_ss     resw 1
dlgbuf      resb 44
dlglen      resw 1
dlg_prompt  resw 1
targpath    resb 128
targpath2   resb 128
copybuf     resb 512
fh_src      resw 1
fh_dst      resw 1
; --- tagged-set + recursive copy/delete state ---
iter_i      resw 1
rdepth      resw 1
rsrc        resb 128
rdst        resb 128
dstroot     resb 128       ; top-level copy destination (skipped during the walk)
comefrom    resb 16        ; leaf name we left when going to a parent folder
findpat     resb 132
dta_stack   resb MAX_DEPTH*DTASZ
; --- mouse state ---
mouse_ok    resb 1
mouse_mode  resb 1         ; MM_BROWSER / MM_OFF / MM_CONFIRM / MM_OWRITE
dlg_focus   resb 1         ; confirm dialog: 0=Yes 1=No
ow_focus    resb 1         ; overwrite dialog: 0=Overwrite 1=Skip 2=All 3=Cancel
ow_mode     resb 1         ; 0=ask each time, 1=overwrite-all, 2=skip-all
ow_cancel   resb 1         ; set when the user cancels the whole operation
m_lb        resb 1
m_rb        resb 1
m_x         resw 1
m_y         resw 1
m_row       resw 1
m_col       resw 1
m_vis       resw 1
m_lasttick  resw 1
m_lastidx   resw 1
m_lastpan   resw 1
vlen        resw 1
vtop        resw 1
vnlines     resw 1
viewbuf     resb VIEW_MAX
lineoff     resw MAX_VLINES
snapbuf     resb 4000
panelL      resb PANELSIZE
panelR      resb PANELSIZE
stackspace  resb 2048
stacktop:
prog_end:
