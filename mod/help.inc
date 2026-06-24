; @feature HELP
; @title   built-in help pager (F1, reads cc.hlp)
; @cost    90
;
; mod/help.inc  --  FEAT_HELP
; F1 shows the help file cc.hlp through the built-in viewer.  Reuses the
; viewer's line-builder and scroller (view_build_lines / render_view /
; view_move), so help pages and scrolls exactly like F3 View.  Ship cc.hlp
; beside cc.com; if it is missing, F1 is a no-op.

key_help:
        mov     ax, 3D00h
        mov     dx, s_helpfile
        int     21h
        jc      .ret
        mov     [fh_src], ax
        mov     bx, ax
        mov     ah, 3Fh
        mov     cx, VIEW_MAX
        mov     dx, viewbuf
        int     21h
        mov     [vlen], ax
        mov     bx, [fh_src]
        mov     ah, 3Eh
        int     21h
        call    view_build_lines
        mov     word [vtop], 0
        mov     byte [mouse_mode], MM_OFF
.loop:
        call    render_view
        cmp     byte [test_mode], 0
        je      .nk
        call    dump_screen
.nk:
        call    get_key
        call    view_move               ; CF=1 -> close
        jnc     .loop
        mov     byte [mouse_mode], MM_BROWSER
.ret:
        ret

s_helpfile  db 'cc.hlp',0
