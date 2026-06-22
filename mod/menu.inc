; mod/menu.inc  --  FEAT_MENU
; F9 pop-up command menu.  A data-driven {label, handler} table (menu_tbl) is
; drawn as a bordered drop-down at top-left; Up/Down move the highlight, Enter
; runs the selected handler, Esc / any other key cancels.  Runs its own key
; sub-loop (shares get_key, so the /T harness drives it).  Adding an action =
; add a row to menu_tbl; no changes to the loop or the renderer.

MENU_C0  equ 3              ; left border column
MENU_IW  equ 18             ; interior width (label field)
MENU_R0  equ 2              ; top border row
A_MENU   equ 030h           ; black on cyan (box + items)
A_MENUS  equ 070h           ; black on white (highlighted item)

key_menu:
        call    menu_count          ; -> [menu_n]
        mov     word [menu_sel], 0
.loop:
        call    mouse_hide
        call    render_all
        call    menu_draw
        call    mouse_show
        cmp     byte [test_mode], 0
        je      .live
        call    dump_screen
.live:
        call    get_key
        or      al, al
        jnz     .asc
        cmp     ah, 48h             ; Up
        je      .up
        cmp     ah, 50h             ; Down
        je      .dn
        jmp     .cancel             ; any other extended key (incl F10) cancels
.asc:
        cmp     al, 0Dh             ; Enter -> run selection
        je      .pick
        cmp     al, 1Bh             ; Esc -> cancel
        je      .cancel
        jmp     .loop               ; ignore other ascii
.up:
        cmp     word [menu_sel], 0
        je      .loop
        dec     word [menu_sel]
        jmp     .loop
.dn:
        mov     ax, [menu_sel]
        inc     ax
        cmp     ax, [menu_n]
        jae     .loop
        mov     [menu_sel], ax
        jmp     .loop
.pick:
        mov     bx, [menu_sel]
        shl     bx, 2               ; 4 bytes/row
        mov     bx, [menu_tbl + bx + 2]     ; handler ptr
        call    bx
        ret
.cancel:
        ret

; count menu items (rows until a 0 label) -> [menu_n]
menu_count:
        xor     ax, ax
        mov     bx, menu_tbl
.c:
        cmp     word [bx], 0
        je      .d
        inc     ax
        add     bx, 4
        jmp     .c
.d:
        mov     [menu_n], ax
        ret

; draw the whole popup (es=VIDEO set here)
menu_draw:
        push    es
        push    bp
        mov     ax, VIDEO
        mov     es, ax
        mov     bp, MENU_R0         ; top border
        xor     dl, dl
        call    menu_brow
        xor     cx, cx
.it:
        cmp     cx, [menu_n]
        jae     .bot
        push    cx
        mov     bp, MENU_R0+1
        add     bp, cx
        call    menu_irow           ; cx=index, bp=row
        pop     cx
        inc     cx
        jmp     .it
.bot:
        mov     bp, MENU_R0+1
        add     bp, [menu_n]
        mov     dl, 1               ; bottom border
        call    menu_brow
        pop     bp
        pop     es
        ret

; border row.  bp=row, dl=0 top / 1 bottom.  es=VIDEO.
menu_brow:
        mov     ax, bp
        mov     bx, MENU_C0
        call    rc_to_off           ; -> di
        mov     ah, A_MENU
        mov     al, 0C9h            ; top-left corner
        or      dl, dl
        jz      .lc
        mov     al, 0C8h            ; bottom-left corner
.lc:
        mov     [es:di], al
        mov     [es:di+1], ah
        add     di, 2
        mov     cx, MENU_IW
        mov     al, 0CDh            ; horizontal
.h:
        mov     [es:di], al
        mov     [es:di+1], ah
        add     di, 2
        loop    .h
        mov     al, 0BBh            ; top-right corner
        or      dl, dl
        jz      .rc
        mov     al, 0BCh            ; bottom-right corner
.rc:
        mov     [es:di], al
        mov     [es:di+1], ah
        ret

; item row.  cx=index, bp=row.  es=VIDEO.
menu_irow:
        mov     ax, bp
        mov     bx, MENU_C0
        call    rc_to_off           ; -> di
        mov     ah, A_MENU
        cmp     cx, [menu_sel]
        jne     .a
        mov     ah, A_MENUS         ; highlight the selected row
.a:
        ; left border (always plain box attr)
        mov     byte [es:di], 0BAh
        mov     byte [es:di+1], A_MENU
        add     di, 2
        ; fill interior with spaces in the item attribute
        push    cx
        push    di
        mov     cx, MENU_IW
        mov     al, ' '
.f:
        mov     [es:di], al
        mov     [es:di+1], ah
        add     di, 2
        loop    .f
        ; right border
        mov     byte [es:di], 0BAh
        mov     byte [es:di+1], A_MENU
        pop     di
        pop     cx
        ; label, indented one space
        add     di, 2
        mov     bx, cx
        shl     bx, 2
        mov     si, [menu_tbl + bx] ; label ptr
.lbl:
        mov     al, [si]
        or      al, al
        jz      .done
        mov     [es:di], al
        mov     [es:di+1], ah
        add     di, 2
        inc     si
        jmp     .lbl
.done:
        ret

; ---- the menu contents: {dw label, dw handler}, 0-terminated ----
menu_tbl:
%ifdef FEAT_SORT
        dw      mi_sname, sort_name
        dw      mi_sext,  sort_ext
        dw      mi_ssize, sort_size
        dw      mi_sdate, sort_date
%endif
%ifdef FEAT_COLS
        dw      mi_cols,  col_cycle
%endif
%ifdef FEAT_SEARCH
        dw      mi_find,  key_qsearch
%endif
%ifdef FEAT_MASK
        dw      mi_tag,   key_mask_sel
%endif
%ifdef FEAT_EDIT
        dw      mi_edit,  key_edit
%endif
        dw      mi_quit,  key_quit
        dw      0, 0

%ifdef FEAT_SORT
mi_sname    db 'Sort: Name',0
mi_sext     db 'Sort: Extension',0
mi_ssize    db 'Sort: Size',0
mi_sdate    db 'Sort: Date',0
%endif
%ifdef FEAT_COLS
mi_cols     db 'Columns: cycle',0
%endif
%ifdef FEAT_SEARCH
mi_find     db 'Quick search',0
%endif
%ifdef FEAT_MASK
mi_tag      db 'Tag by mask',0
%endif
%ifdef FEAT_EDIT
mi_edit     db 'Edit file (F4)',0
%endif
mi_quit     db 'Quit',0
