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

; --- F9: drop a menu down from the (already-visible) bar --------------------
; The bar itself is drawn every frame by mb_bar_draw (the widget seam); this
; just sets mb_active so the bar highlights the current menu, then renders the
; drop-down and runs the 2D key loop.
key_menubar:
        mov     word [mb_cur], 0
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
        call    get_key
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
        mov     ax, VIDEO
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
        mov     ax, VIDEO
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
        dw      mb_t_tools, mb_tools, 30
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
