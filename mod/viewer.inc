; mod/viewer.inc  --  extracted from cc.asm (M1 module split, byte-identical)
; Plain implicit-text code only; no section/equ/macro (see plan/m1_split.md).

key_view:
        mov     bx, [active]
        mov     cx, [bx+P_COUNT]
        jcxz    .ret
        call    cur_entry_ptr       ; si=entry
        test    byte [si+E_ATTR], 10h
        jnz     .ret                ; do not view directories
        call    build_entry_path    ; targpath = full path (si preserved)
        mov     ax, 3D00h
        mov     dx, targpath
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
        mov     byte [mouse_mode], MM_OFF  ; ignore panel clicks while viewing
.loop:
        call    render_view
        cmp     byte [test_mode], 0
        je      .nk
        call    dump_screen
.nk:
        call    get_key
        call    view_move           ; update vtop; CF=1 -> quit
        jnc     .loop
        mov     byte [mouse_mode], MM_BROWSER
.ret:
        ret

; view_move: al=ascii, ah=scan -> adjust [vtop]; returns CF=1 to close viewer
view_move:
        or      al, al
        jnz     .ascii
        cmp     ah, 48h
        je      .up
        cmp     ah, 50h
        je      .down
        cmp     ah, 49h
        je      .pgup
        cmp     ah, 51h
        je      .pgdn
        cmp     ah, 47h
        je      .home
        cmp     ah, 4Fh
        je      .end
        cmp     ah, 3Dh             ; F3 again
        je      .quit
        cmp     ah, 44h             ; F10
        je      .quit
        clc
        ret
.ascii:
        cmp     al, 1Bh             ; Esc
        je      .quit
        cmp     al, 'q'
        je      .quit
        cmp     al, 'Q'
        je      .quit
        clc
        ret
.up:
        cmp     word [vtop], 0
        je      .stay
        dec     word [vtop]
.stay:
        clc
        ret
.down:
        mov     ax, [vtop]
        inc     ax
        cmp     ax, [vnlines]
        jae     .stay
        mov     [vtop], ax
        clc
        ret
.pgup:
        mov     ax, [vtop]
        sub     ax, VIEW_ROWS
        jns     .pu1
        xor     ax, ax
.pu1:
        mov     [vtop], ax
        clc
        ret
.pgdn:
        mov     cx, [vnlines]
        jcxz    .stay
        mov     ax, [vtop]
        add     ax, VIEW_ROWS
        cmp     ax, cx
        jb      .pd1
        mov     ax, cx
        dec     ax
.pd1:
        mov     [vtop], ax
        clc
        ret
.home:
        mov     word [vtop], 0
        clc
        ret
.end:
        mov     cx, [vnlines]
        jcxz    .stay
        mov     ax, cx
        dec     ax
        mov     [vtop], ax
        clc
        ret
.quit:
        stc
        ret

; build the line-offset table over viewbuf[0..vlen) -> lineoff[], vnlines
view_build_lines:
        mov     word [vnlines], 0
        mov     cx, [vlen]
        jcxz    .done
        xor     si, si              ; byte offset
        mov     word [lineoff], 0   ; line 0 at offset 0
        mov     bx, 1               ; nlines
.scan:
        cmp     si, [vlen]
        jae     .fin
        mov     al, [viewbuf+si]
        inc     si
        cmp     al, 0Ah             ; LF -> next line begins at si
        jne     .scan
        cmp     si, [vlen]
        jae     .fin                ; trailing LF -> no empty line after
        cmp     bx, MAX_VLINES
        jae     .fin
        mov     di, bx
        shl     di, 1
        add     di, lineoff
        mov     [di], si
        inc     bx
        jmp     .scan
.fin:
        mov     [vnlines], bx
.done:
        ret

; render the viewer screen (header + VIEW_ROWS text rows + help bar)
render_view:
        push    es
        mov     ax, VIDEO
        mov     es, ax
        ; clear to text attr
        xor     di, di
        mov     ax, (A_VTXT<<8)|' '
        mov     cx, SCR_W*SCR_H
        rep     stosw
        ; header bar
        xor     di, di
        mov     ax, (A_VHDR<<8)|' '
        mov     cx, SCR_W
        rep     stosw
        mov     di, 2
        mov     bx, [active]
        call    cur_entry_ptr       ; si=entry
        lea     si, [si+E_NAME]
        mov     ah, A_VHDR
.hn:    mov     al, [si]
        or      al, al
        jz      .hlbl
        mov     [es:di], al
        mov     [es:di+1], ah
        inc     si
        add     di, 2
        jmp     .hn
.hlbl:
        mov     si, s_viewhdr
.hl:    mov     al, [si]
        or      al, al
        jz      .rows
        mov     [es:di], al
        mov     [es:di+1], ah
        inc     si
        add     di, 2
        jmp     .hl
.rows:
        xor     bp, bp              ; visible row index
.row:
        cmp     bp, VIEW_ROWS
        jae     .bar
        mov     ax, [vtop]
        add     ax, bp
        cmp     ax, [vnlines]
        jae     .nextrow            ; past end -> blank
        ; di = (FIRST_ROW+bp)*ROW_BYTES
        mov     ax, bp
        add     ax, FIRST_ROW
        imul    ax, ROW_BYTES
        mov     di, ax
        ; si = lineoff[vtop+bp]
        mov     ax, [vtop]
        add     ax, bp
        mov     bx, ax
        shl     bx, 1
        add     bx, lineoff
        mov     si, [bx]
        xor     cx, cx              ; column
        mov     ah, A_VTXT
.emit:
        cmp     cx, SCR_W
        jae     .nextrow
        cmp     si, [vlen]
        jae     .nextrow
        mov     al, [viewbuf+si]
        cmp     al, 0Ah
        je      .nextrow
        inc     si
        cmp     al, 0Dh
        je      .emit               ; skip CR (no column advance)
        cmp     al, 9
        je      .tab
        cmp     al, 20h
        jae     .put
        mov     al, '.'             ; show controls as dots
.put:
        mov     [es:di], al
        mov     [es:di+1], ah
        add     di, 2
        inc     cx
        jmp     .emit
.tab:
        mov     al, ' '
.tsp:
        cmp     cx, SCR_W
        jae     .nextrow
        mov     [es:di], al
        mov     [es:di+1], ah
        add     di, 2
        inc     cx
        test    cx, 7
        jnz     .tsp
        jmp     .emit
.nextrow:
        inc     bp
        jmp     .row
.bar:
        mov     di, FKEY_ROW*ROW_BYTES
        mov     ax, (A_VBAR<<8)|' '
        mov     cx, SCR_W
        rep     stosw
        mov     di, FKEY_ROW*ROW_BYTES
        mov     si, s_viewbar
        mov     ah, A_VBAR
.bl:    mov     al, [si]
        or      al, al
        jz      .done
        mov     [es:di], al
        mov     [es:di+1], ah
        inc     si
        add     di, 2
        jmp     .bl
.done:
        pop     es
        ret

