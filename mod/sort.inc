; @feature SORT
; @title   sort by name/ext/size/date (Ctrl-F1..F4)
; @cost    60
;
; mod/sort.inc  --  FEAT_SORT
; Sort-order selection. The comparison logic lives in core order_cmp (driven
; by [sort_mode]); this module just provides the key handlers that set the
; mode and re-sort both panels. Bound via keytab (Ctrl-F3..Ctrl-F6).

sort_name:
        mov     byte [sort_mode], 0
        jmp     sort_apply
sort_ext:
        mov     byte [sort_mode], 1
        jmp     sort_apply
sort_size:
        mov     byte [sort_mode], 2
        jmp     sort_apply
sort_date:
        mov     byte [sort_mode], 3
sort_apply:
        mov     word [ppanel], panelL
        call    sort_panel
        mov     word [ppanel], panelR
        call    sort_panel
        ret
