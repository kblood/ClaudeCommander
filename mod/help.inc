; @feature HELP
; @title   built-in help pager (F1, reads cc.hlp)
; @cost    20
;
; mod/help.inc  --  FEAT_HELP
; F1 shows the help file cc.hlp through the built-in viewer: it is simply
; view_open_builtin on "cc.hlp", always in text mode (view_hex cleared, so a
; previous H toggle doesn't leave help in hex).  Pages and scrolls exactly like
; F3 View; F1 again closes it.  Ship cc.hlp beside cc.com; if it is missing,
; F1 is a no-op (the open fails and the viewer bails).

key_help:
        mov     si, s_helpfile
        mov     di, targpath
        call    bp_copy_name
        mov     byte [view_hex], 0
        jmp     view_open_builtin

s_helpfile  db 'cc.hlp',0
