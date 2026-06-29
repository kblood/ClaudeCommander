; @feature MENUBAR
; @title   NC-style pull-down menu bar (F9; supersedes the MENU pop-up)
; @needs   WIDGETS
; @cost    675
;
; mod/menubar.inc  --  FEAT_MENUBAR
; The Norton-Commander pull-down MENU BAR: a horizontal strip of menu titles
; (Files / Commands / Options) across the top row, each opening a vertical
; drop-down of {label, handler} items. It is the richer sibling of the F9
; pop-up (mod/menu.inc) and is MUTUALLY EXCLUSIVE with it -- cc.asm binds F9
; to whichever of the two is compiled in, and includes only that one. So a
; build either pays for the small pop-up or the larger bar, never both; the
; menu bar is an opt-in widget (configure.ps1 -Add MENUBAR) and the resident
; size scales accordingly.
;
; Like the tree browser and the pop-up, this is a self-contained modal: it owns
; its own draw + 2D key loop and shares get_key (so the /T harness drives it),
; and it reuses the existing key_* command handlers, so adding/moving an action
; is just a row in the per-menu tables below.
;
;   mb_menus row (6 bytes):  dw title, dw items, dw anchor_col
;   items row    (4 bytes):  dw label, dw handler          (0-terminated)

MB_DROPW  equ 24            ; drop-down interior width
MB_TOP    equ 1            ; drop-down top-border row (row 0 is the bar)
A_MB      equ 030h         ; bar / box: black on cyan
A_MBSEL   equ 070h         ; active title + selected item: black on white

; --- widget key hook --------------------------------------------------------
; The menu bar is a self-contained widget: it draws through widgets_draw and
; claims its hotkey through widgets_key. dispatch offers every key here first;
; we take F9 (extended scan 43h, al=0) and decline everything else, so cc.asm
; needs no keytab row for the bar -- including this module is all it takes.
;   in:  al=ascii, ah=scan      out: CF=1 handled (key_menubar ran), else CF=0
mb_key:
        or      al, al                  ; F9 is an extended key (al==0)
        jnz     .no
        cmp     ah, 43h                 ; F9 scan code
        jne     .no
        call    key_menubar
        stc
        ret
.no:
        clc
        ret

; --- F9: drop a menu down from the (already-visible) bar --------------------
; The bar itself is drawn every frame by mb_bar_draw (the widget seam); this
; just sets mb_active so the bar highlights the current menu, then renders the
; drop-down and runs the 2D key loop.
;
; Live mode with a mouse driver: we poll the keyboard and mouse ourselves so
; we can hit-test bar titles and the open drop-down. Test-harness mode (/T)
; still delegates to get_key (which replays cc.key), preserving the existing
; automated test path exactly. mb_mlb tracks the left-button "was-down" state
; for edge detection (separate from m_lb used by the browser).
key_menubar:
        ; Opened by a bar click (mb_bar_hit stashed the menu index) or by F9
        ; (mb_click left at 0FFFFh -> default to Files/0). Consume mb_click so the
        ; next open starts fresh.
        mov     ax, [mb_click]
        mov     word [mb_click], 0FFFFh
        cmp     ax, 0FFFFh
        jne     .haveidx
        xor     ax, ax
.haveidx:
        mov     [mb_cur], ax
        mov     byte [mb_active], 1
        call    mb_recount              ; -> mb_n, mb_sel=0, mb_col, mb_items
.loop:
        call    mouse_hide
        call    render_all              ; redraws panels + bar (highlights mb_cur)
        call    mb_drop_draw            ; the drop-down for the active menu
        call    mouse_show
        cmp     byte [test_mode], 0
        je      .live
        call    dump_screen
.live:
        cmp     byte [test_mode], 0
        jne     .do_getkey              ; /T harness: replay cc.key, preserve dumps
        cmp     byte [mouse_ok], 0
        je      .kbonly                 ; no mouse driver: busy-wait on keyboard
; ---- live mode with mouse: poll keyboard and mouse on each iteration --------
.poll:
        call    widgets_tick            ; allow the clock widget to tick
        mov     ah, 1
        int     16h                     ; BIOS: key waiting in buffer?
        jnz     .kbread                 ; yes -> consume it
        ; poll mouse (INT 33h AX=3 -> bx=buttons, cx=x pixels, dx=y pixels)
        mov     ax, 3
        int     33h
        mov     al, bl
        and     al, 1                   ; al = current left-button state
        mov     ah, [mb_mlb]            ; ah = previous state (was-down)
        mov     [mb_mlb], al            ; update state
        or      al, al
        jz      .poll                   ; button up -> no event
        or      ah, ah
        jnz     .poll                   ; was already down -> not a new edge
        ; ---- LEFT DOWN EDGE detected: cx=x(px), dx=y(px) ----
        shr     cx, 3                   ; cx = click column (cell)
        shr     dx, 3                   ; dx = click row (cell)
        or      dx, dx
        jnz     .mb_drop_hit            ; row > 0 -> check dropdown / outside
        ; === click on the menu bar (row 0): identify which title was clicked ===
        push    si                      ; preserve caller's si across scan
        xor     bx, bx                  ; bx = menu index k (0..MB_MENUS-1)
.bar_loop:
        cmp     bx, MB_MENUS
        jae     .bar_miss               ; no title matched -> ignore click
        mov     ax, bx
        call    mb_menu_ptr             ; si -> 6-byte menu row
        mov     ax, [si+4]              ; ax = anchor column A
        cmp     cx, ax                  ; click_col < anchor?
        jb      .bar_next               ; yes -> this menu starts to the right
        push    cx                      ; save click col during strlen
        mov     si, [si]                ; si = title string ptr
        xor     cx, cx                  ; cx = title length counter
.bar_len:
        cmp     byte [si], 0
        je      .bar_done
        inc     si
        inc     cx
        jmp     .bar_len
.bar_done:                              ; cx = len, ax = anchor A
        add     ax, cx                  ; ax = A + len (first col past title)
        pop     cx                      ; restore click col
        cmp     cx, ax
        jae     .bar_next               ; click beyond this title -> try next
        pop     si                      ; match: restore si
        mov     ax, bx                  ; ax = matched menu index
        jmp     .setmenu
.bar_next:
        inc     bx
        jmp     .bar_loop
.bar_miss:
        pop     si                      ; no title matched -> restore si
        jmp     .poll                   ; click on bar gap -> keep polling
; === click not on bar: check open dropdown ===
.mb_drop_hit:
        cmp     dx, MB_TOP+1            ; row < first item row?
        jb      .mb_outside             ; hit the top border -> close
        mov     ax, [mb_n]
        add     ax, MB_TOP              ; ax = row of last dropdown item
        cmp     dx, ax
        ja      .mb_outside             ; below last item (border or below) -> close
        mov     ax, [mb_col]
        cmp     cx, ax
        jb      .mb_outside             ; left of left border -> close
        add     ax, MB_DROPW+1          ; ax = right-border column
        cmp     cx, ax
        ja      .mb_outside             ; right of right border -> close
        ; inside dropdown: select item and execute
        mov     ax, dx
        sub     ax, MB_TOP+1            ; item index = row - (MB_TOP+1)
        mov     [mb_sel], ax
        jmp     .pick                   ; -> mb_handler + invoke
.mb_outside:
        jmp     .close                  ; click outside menu -> close
; ---- keyboard-only polling (live mode, no mouse driver) --------------------
.kbonly:
        call    widgets_tick
        mov     ah, 1
        int     16h                     ; BIOS peek
        jz      .kbonly                 ; no key yet
.kbread:
        mov     ah, 0
        int     16h                     ; read key: al=ascii, ah=scan
        jmp     .got_key
.do_getkey:
        call    get_key
.got_key:
        or      al, al
        jnz     .asc
        ; --- extended keys (al=0) ---
        cmp     ah, 4Bh                 ; Left -> previous menu
        jne     .nL
        mov     ax, [mb_cur]
        dec     ax
        jns     .setmenu
        mov     ax, MB_MENUS-1
        jmp     .setmenu
.nL:
        cmp     ah, 4Dh                 ; Right -> next menu
        jne     .nR
        mov     ax, [mb_cur]
        inc     ax
        cmp     ax, MB_MENUS
        jb      .setmenu
        xor     ax, ax
        jmp     .setmenu
.nR:
        cmp     ah, 48h                 ; Up
        jne     .nU
        cmp     word [mb_sel], 0
        je      .reloop
        dec     word [mb_sel]
        jmp     .reloop
.nU:
        cmp     ah, 50h                 ; Down
        jne     .nD
        mov     ax, [mb_sel]
        inc     ax
        cmp     ax, [mb_n]
        jae     .reloop
        mov     [mb_sel], ax
        jmp     .reloop
.nD:
        cmp     ah, 44h                 ; F10 -> close (also script-exhaustion key)
        je      .close
        jmp     .reloop
.asc:
        cmp     al, 0Dh                 ; Enter -> run selection
        je      .pick
        cmp     al, 1Bh                 ; Esc -> close
        je      .close
        jmp     .reloop
.setmenu:
        mov     [mb_cur], ax
        call    mb_recount
.reloop:
        jmp     .loop
.pick:
        mov     cx, [mb_n]
        jcxz    .close                  ; empty menu -> nothing to run
        call    mb_handler              ; -> bx = handler
        mov     byte [mb_active], 0
        call    mouse_hide
        push    bx
        call    render_all              ; close the drop-down before the action
        pop     bx
        call    mouse_show
        call    bx
        ret
.close:
        mov     byte [mb_active], 0     ; bar stays visible, just not dropped down
        call    mouse_hide
        call    render_all
        call    mouse_show
        ret

; Browser-mode click on the menu-bar row (called from mouse_left when a click
; lands on MENUBAR_ROW, BEFORE F9 is pressed). [m_col] = clicked cell column.
; If it hits a menu title, stash that menu index in mb_click and return a
; synthetic F9 (al=0, ah=43h) so dispatch routes through mb_key -> key_menubar,
; which opens the bar at the clicked menu. A miss returns ax=0 (harmless re-poll).
; mb_mlb is seeded to 1 (button currently down) so the menu's own poll doesn't
; mistake this still-held press for a fresh click inside the drop-down.
mb_bar_hit:
        mov     cx, [m_col]
        xor     bx, bx                  ; menu index
.l:
        cmp     bx, MB_MENUS
        jae     .miss
        mov     ax, bx
        call    mb_menu_ptr             ; si -> row (preserves bx,cx)
        mov     ax, [si+4]              ; anchor col A
        cmp     cx, ax
        jb      .next                   ; click is left of this title
        push    cx
        mov     si, [si]                ; title string ptr
        xor     cx, cx                  ; strlen
.len:
        cmp     byte [si], 0
        je      .done
        inc     si
        inc     cx
        jmp     .len
.done:
        add     ax, cx                  ; A + len = first col past the title
        pop     cx
        cmp     cx, ax
        jae     .next                   ; click is past this title
        mov     [mb_click], bx          ; hit menu bx
        mov     byte [mb_mlb], 1        ; press is still down -> not a fresh edge
        mov     al, 0
        mov     ah, 43h                 ; synthetic F9
        ret
.next:
        inc     bx
        jmp     .l
.miss:
        xor     ax, ax
        ret

; ax = menu index -> si = &mb_menus row. Preserves ax,bx,cx,dx.
mb_menu_ptr:
        push    ax
        push    dx
        mov     dx, 6
        mul     dx
        mov     si, mb_menus
        add     si, ax
        pop     dx
        pop     ax
        ret

; Cache the active menu's anchor col + items ptr, recount items, reset sel.
mb_recount:
        mov     ax, [mb_cur]
        call    mb_menu_ptr             ; si -> row
        mov     ax, [si+4]
        mov     [mb_col], ax
        mov     si, [si+2]              ; items ptr
        mov     [mb_items], si
        xor     cx, cx
.c:
        cmp     word [si], 0
        je      .d
        inc     cx
        add     si, 4
        jmp     .c
.d:
        mov     [mb_n], cx
        mov     word [mb_sel], 0
        ret

; -> bx = handler ptr of the selected item.
mb_handler:
        mov     bx, [mb_sel]
        shl     bx, 2
        add     bx, [mb_items]
        mov     bx, [bx+2]
        ret

; --- rendering --------------------------------------------------------------
; Persistent bar on row MENUBAR_ROW. Called every frame from the widget seam
; (widgets_draw). When a menu is open (mb_active) the current title is
; highlighted; otherwise all titles are plain.
mb_bar_draw:
        push    es
        push    bp
        mov     ax, [vseg]
        mov     es, ax
        mov     di, MENUBAR_ROW*ROW_BYTES
        mov     cx, SCR_W
        mov     ah, A_MB
        mov     al, ' '
.fill:
        mov     [es:di], al
        mov     [es:di+1], ah
        add     di, 2
        loop    .fill
        xor     bx, bx                  ; menu index
.titles:
        cmp     bx, MB_MENUS
        jae     .done
        push    bx
        mov     ax, bx
        call    mb_menu_ptr             ; si -> row
        mov     ax, [si+4]              ; anchor col
        shl     ax, 1
        mov     di, ax
        add     di, MENUBAR_ROW*ROW_BYTES
        mov     ah, A_MB
        cmp     byte [mb_active], 0
        je      .ta                     ; bar idle -> no highlight
        cmp     bx, [mb_cur]
        jne     .ta
        mov     ah, A_MBSEL
.ta:
        mov     si, [si]                ; title ptr
        call    mb_puts
        pop     bx
        inc     bx
        jmp     .titles
.done:
        pop     bp
        pop     es
        ret

; The drop-down for the active menu (drawn over the panels while mb_active).
mb_drop_draw:
        push    es
        push    bp
        mov     ax, [vseg]
        mov     es, ax
        mov     bp, MB_TOP              ; top border just under the bar
        mov     bx, [mb_col]
        mov     cx, MB_DROPW
        xor     dl, dl
        call    mb_brow
        xor     cx, cx                  ; item index
.itrow:
        cmp     cx, [mb_n]
        jae     .botb
        push    cx
        mov     bp, MB_TOP+1
        add     bp, cx
        mov     bx, [mb_col]
        call    mb_irow                 ; cx=idx, bp=row, bx=col
        pop     cx
        inc     cx
        jmp     .itrow
.botb:
        mov     bp, MB_TOP+1
        add     bp, [mb_n]
        mov     bx, [mb_col]
        mov     cx, MB_DROPW
        mov     dl, 1
        call    mb_brow
        pop     bp
        pop     es
        ret

; horizontal box border. bp=row, bx=col, cx=interior width, dl=0 top/1 bottom.
; es=VIDEO. Clobbers ax,di (cx restored).
mb_brow:
        mov     ax, bp
        call    rc_to_off               ; -> di (bx,cx preserved)
        mov     ah, A_MB
        mov     al, 0C9h                ; top-left
        or      dl, dl
        jz      .l
        mov     al, 0C8h                ; bottom-left
.l:
        mov     [es:di], al
        mov     [es:di+1], ah
        add     di, 2
        push    cx
        mov     al, 0CDh                ; horizontal
.h:
        mov     [es:di], al
        mov     [es:di+1], ah
        add     di, 2
        loop    .h
        pop     cx
        mov     al, 0BBh                ; top-right
        or      dl, dl
        jz      .r
        mov     al, 0BCh                ; bottom-right
.r:
        mov     [es:di], al
        mov     [es:di+1], ah
        ret

; one drop-down item row. cx=index, bp=row, bx=col. es=VIDEO.
mb_irow:
        mov     ax, bp
        call    rc_to_off               ; -> di (bx,cx preserved)
        mov     ah, A_MB
        cmp     cx, [mb_sel]
        jne     .a
        mov     ah, A_MBSEL             ; highlight selected
.a:
        mov     byte [es:di], 0BAh      ; left border (plain box attr)
        mov     byte [es:di+1], A_MB
        add     di, 2
        push    cx
        push    di
        mov     cx, MB_DROPW
        mov     al, ' '
.f:
        mov     [es:di], al
        mov     [es:di+1], ah
        add     di, 2
        loop    .f
        mov     byte [es:di], 0BAh      ; right border
        mov     byte [es:di+1], A_MB
        pop     di
        pop     cx
        add     di, 2                   ; one-space indent into interior
        mov     bx, cx
        shl     bx, 2
        add     bx, [mb_items]
        mov     si, [bx]                ; label ptr
        call    mb_puts
        ret

; blit ASCIIZ ds:si at es:di with attribute ah. Clobbers al,si,di.
mb_puts:
        mov     al, [si]
        or      al, al
        jz      .e
        mov     [es:di], al
        mov     [es:di+1], ah
        add     di, 2
        inc     si
        jmp     mb_puts
.e:
        ret

; --- the menu contents ------------------------------------------------------
; key_view (F3) and key_quit (F10) are core, always present; the rest mirror
; the FEAT gating of mod/menu.inc so any a-la-carte set links cleanly.
mb_menus:
        dw      mb_t_files, mb_files, 1
        dw      mb_t_cmds,  mb_cmds,  9
        dw      mb_t_opts,  mb_opts,  20
%ifdef FEAT_TOOLS
  %ifdef FEAT_TOOLS_INI
        dw      mb_t_tools, tools_menu_rt, 30   ; runtime: builtins + cc.ini [tools]
  %else
        dw      mb_t_tools, mb_tools, 30
  %endif
MB_MENUS equ 4
%else
MB_MENUS equ 3
%endif

mb_files:
        dw      mb_l_view, key_view
%ifdef FEAT_EDIT
        dw      mb_l_edit, key_edit
%endif
        dw      mb_l_quit, key_quit
        dw      0

mb_cmds:
%ifdef FEAT_SEARCH
        dw      mb_l_qs,   key_qsearch
%endif
%ifdef FEAT_FIND
        dw      mb_l_find, key_find
%endif
%ifdef FEAT_GREP
        dw      mb_l_grep, key_grep
%endif
%ifdef FEAT_ZIP
        dw      mb_l_zip,  key_zip
%endif
        dw      0

mb_opts:
%ifdef FEAT_SORT
        dw      mb_l_sn, sort_name
        dw      mb_l_se, sort_ext
        dw      mb_l_sz, sort_size
        dw      mb_l_sd, sort_date
%endif
%ifdef FEAT_COLS
        dw      mb_l_col, col_cycle
%endif
%ifdef FEAT_ATTR
        dw      mb_l_attr, key_attr
%endif
%ifdef FEAT_VIEWS
        dw      mb_l_view3, key_view_toggle
%endif
        dw      0

%ifdef FEAT_TOOLS
mb_tools:
        dw      mb_l_hex,   key_hexview      ; built-in (F3 + H); rest shell out
        dw      mb_l_sum,   key_tools_sum
        dw      mb_l_cmp,   key_tools_cmp
        dw      mb_l_split, key_tools_split
        dw      mb_l_ren,   key_tools_ren
        dw      0
%endif

mb_t_files  db ' Files ', 0
mb_t_cmds   db ' Commands ', 0
mb_t_opts   db ' Options ', 0

mb_l_view   db 'View file (F3)', 0
%ifdef FEAT_EDIT
mb_l_edit   db 'Edit file (F4)', 0
%endif
mb_l_quit   db 'Quit', 0
%ifdef FEAT_SEARCH
mb_l_qs     db 'Quick search', 0
%endif
%ifdef FEAT_FIND
mb_l_find   db 'Find files (Alt-F7)', 0
%endif
%ifdef FEAT_GREP
mb_l_grep   db 'Grep contents (Alt-F8)', 0
%endif
%ifdef FEAT_ZIP
mb_l_zip    db 'List archive (Ctrl-F9)', 0
%endif
%ifdef FEAT_SORT
mb_l_sn     db 'Sort: Name', 0
mb_l_se     db 'Sort: Extension', 0
mb_l_sz     db 'Sort: Size', 0
mb_l_sd     db 'Sort: Date', 0
%endif
%ifdef FEAT_COLS
mb_l_col    db 'Columns: cycle', 0
%endif
%ifdef FEAT_ATTR
mb_l_attr   db 'Edit attribs (Ctrl-A)', 0
%endif
%ifdef FEAT_TOOLS
mb_t_tools  db ' Tools ', 0
mb_l_hex    db 'Hex dump (F3, then H)', 0
mb_l_sum    db 'Checksum (CRC-32)', 0
mb_l_cmp    db 'Compare (other panel)', 0
mb_l_split  db 'Split file...', 0
mb_l_ren    db 'Wildcard rename...', 0
%endif
%ifdef FEAT_VIEWS
mb_l_view3  db '3-col view (Ctrl-F10)', 0
%endif
mb_mlb      db 0                ; left-button state tracking (menu mouse support)
mb_click    dw 0FFFFh           ; menu index from a browser-mode bar click (FFFF=none)
