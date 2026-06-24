; mod/viewer.inc  --  extracted from cc.asm (M1 module split, byte-identical)
; Plain implicit-text code only; no section/equ/macro (see plan/m1_split.md).

key_view:
        mov     byte [view_hex], 0  ; F3 always opens in text mode
        mov     bx, [active]
        mov     cx, [bx+P_COUNT]
        jcxz    .skip
        call    cur_entry_ptr       ; si=entry
        test    byte [si+E_ATTR], 10h
        jz      .ok                 ; not a directory -> proceed
.skip:
        ret
.ok:
        call    build_entry_path    ; targpath = full path (si preserved)
%ifdef FEAT_VIEW
        ; if the cursor file's extension is in the [view] map, run that viewer
        ; instead of the built-in text pager (skip for virtual container panels).
        mov     bx, [active]
        cmp     byte [bx+P_VFS], 0
        jne     view_open_builtin
        call    cur_entry_ptr
        lea     si, [si+E_NAME]
        call    view_lookup         ; CF=1 -> di = viewer helper
        jnc     view_open_builtin
        call    run_view_helper
        ret
%endif
        ; (no [view] map) fall through into the built-in pager

; Open targpath into viewbuf and run the built-in pager. Reached by F3's text
; path above and (with view_hex preset) by key_hexview from the Tools menu.
view_open_builtin:
        mov     word [vtop], 0
        mov     byte [view_edit_req], 0
        mov     byte [mouse_mode], MM_OFF  ; ignore panel clicks while viewing
.reload:                            ; (re)read targpath into viewbuf
        mov     ax, 3D00h
        mov     dx, targpath
        int     21h
        jc      .close              ; open failed -> bail (restores mouse mode)
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
.loop:
        call    render_view
        cmp     byte [test_mode], 0
        je      .nk
        call    dump_screen
.nk:
        call    get_key
        call    view_move           ; update vtop; CF=1 -> quit
        jc      .close
        cmp     byte [view_edit_req], 0
        je      .loop
        mov     byte [view_edit_req], 0
        call    view_launch_editor  ; run CCHEXED / configured editor on the file
        jmp     .reload             ; the file may have changed -> re-read it
.close:
        mov     byte [mouse_mode], MM_BROWSER
.ret:
        ret

; Launch an editor on the file currently in the pager (targpath). In hex mode
; that's CCHEXED; in text mode it's the configured editor (editor_name). Built
; as "<prog> <targpath>" in cmdbuf, run visibly via run_command. Reached by the
; E key in view_move.
view_launch_editor:
        mov     di, cmdbuf
        cmp     byte [view_hex], 0
        jne     .hex
%ifdef FEAT_EDIT
        mov     si, editor_name     ; text mode -> configured editor
.cn1:   mov     al, [si]
        or      al, al
        jz      .arg
        mov     [di], al
        inc     di
        inc     si
        jmp     .cn1
%else
        ret                         ; no editor configured in this build
%endif
.hex:
        mov     si, s_cchexed       ; hex mode -> CCHEXED
.cn2:   mov     al, [si]
        or      al, al
        jz      .arg
        mov     [di], al
        inc     di
        inc     si
        jmp     .cn2
.arg:
        mov     byte [di], ' '
        inc     di
        mov     si, targpath
.cp:    mov     al, [si]
        or      al, al
        jz      .fin
        mov     [di], al
        inc     di
        inc     si
        jmp     .cp
.fin:
        mov     ax, di
        sub     ax, cmdbuf
        mov     [cmdlen], ax
        call    run_command
        ret

%ifdef FEAT_VIEW
; di -> viewer helper name (in viewmap). Build "<helper> <targpath>" into cmdbuf
; and run it visibly (the viewer owns the screen), then redraw the panels.
run_view_helper:
        mov     si, di
        mov     di, cmdbuf
        call    vfs_cat             ; helper name (no NUL), di advances
        mov     byte [di], ' '
        inc     di
        mov     si, targpath
        call    vfs_cat             ; full file path
        mov     ax, di
        sub     ax, cmdbuf
        mov     [cmdlen], ax
        call    run_command         ; clears screen, EXECs, waits, re-reads dirs
        ret
%endif

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
        cmp     al, 'h'             ; toggle text <-> hex view
        je      .hex
        cmp     al, 'H'
        je      .hex
        cmp     al, 'e'             ; open this file in an editor
        je      .edit
        cmp     al, 'E'
        je      .edit
        clc
        ret
.hex:
        xor     byte [view_hex], 1  ; flip mode; restart at the top
        mov     word [vtop], 0
        clc
        ret
.edit:
        mov     byte [view_edit_req], 1  ; handled by view_open_builtin's loop
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
        call    view_nrows          ; cx = total rows in the active mode
        mov     ax, [vtop]
        inc     ax
        cmp     ax, cx
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
        call    view_nrows
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
        call    view_nrows
        jcxz    .stay
        mov     ax, cx
        dec     ax
        mov     [vtop], ax
        clc
        ret
.quit:
        stc
        ret

; -> cx = number of scrollable rows in the active mode (text lines, or hex
; rows = ceil(vlen/16)). Clobbers ax.
view_nrows:
        cmp     byte [view_hex], 0
        je      .text
        mov     ax, [vlen]
        add     ax, 15
        shr     ax, 1
        shr     ax, 1
        shr     ax, 1
        shr     ax, 1
        mov     cx, ax
        ret
.text:
        mov     cx, [vnlines]
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
        cmp     byte [view_hex], 0
        je      .text
        jmp     render_view_hex
.text:
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
        ; di = (VIEW_TOP+bp)*ROW_BYTES  (the pager owns the screen, so its
        ; content row is independent of the panel's FIRST_ROW)
        mov     ax, bp
        add     ax, VIEW_TOP
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

; --- built-in HEX view ------------------------------------------------------
; A second face of the same pager over the same viewbuf: 16 bytes per row as
; "offset  hh hh ..  |ascii|", scrolled by the shared view_move. Toggled with H
; (view_move) or entered directly via key_hexview (the Tools menu). No external
; process -- the CCHEX.COM helper stays for command-line/redirect use.
render_view_hex:
        push    es
        mov     ax, VIDEO
        mov     es, ax
        xor     di, di                      ; clear screen to text attr
        mov     ax, (A_VTXT<<8)|' '
        mov     cx, SCR_W*SCR_H
        rep     stosw
        xor     di, di                      ; header bar: filename + s_hexhdr
        mov     ax, (A_VHDR<<8)|' '
        mov     cx, SCR_W
        rep     stosw
        mov     di, 2
        mov     bx, [active]
        call    cur_entry_ptr
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
        mov     si, s_hexhdr
.hl:    mov     al, [si]
        or      al, al
        jz      .rows
        mov     [es:di], al
        mov     [es:di+1], ah
        inc     si
        add     di, 2
        jmp     .hl
.rows:
        xor     bp, bp                      ; visible row index
.row:
        cmp     bp, VIEW_ROWS
        jae     .bar
        mov     ax, [vtop]                  ; byteoff = (vtop+bp)*16
        add     ax, bp
        shl     ax, 1
        shl     ax, 1
        shl     ax, 1
        shl     ax, 1
        cmp     ax, [vlen]
        jae     .nextrow                    ; past EOF -> leave blank
        call    hex_format_row              ; -> linebuf[0..HEXW)  (preserves bp)
        mov     ax, bp                      ; di = (VIEW_TOP+bp)*ROW_BYTES
        add     ax, VIEW_TOP
        imul    ax, ROW_BYTES
        mov     di, ax
        mov     si, linebuf
        mov     cx, HEXW
        mov     ah, A_VTXT
.put:
        mov     al, [si]
        mov     [es:di], al
        mov     [es:di+1], ah
        inc     si
        add     di, 2
        loop    .put
.nextrow:
        inc     bp
        jmp     .row
.bar:
        mov     di, FKEY_ROW*ROW_BYTES
        mov     ax, (A_VBAR<<8)|' '
        mov     cx, SCR_W
        rep     stosw
        mov     di, FKEY_ROW*ROW_BYTES
        mov     si, s_hexbar
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

; ax = byte offset -> format one 16-byte hex row into linebuf (exactly HEXW
; chars: 8-hex offset, 2 spaces, 16*"hh ", 1 space, 16 ASCII). Clobbers
; ax,bx,cx,si,di; preserves bp.
hex_format_row:
        push    bp
        mov     bp, ax                      ; bp = row base offset
        mov     di, linebuf
        xor     ax, ax                      ; offset high word (0 for <=14 KB)
        call    put_hex16
        mov     ax, bp                      ; offset low word
        call    put_hex16
        mov     byte [di], ' '
        inc     di
        mov     byte [di], ' '
        inc     di
        xor     cx, cx                      ; hex byte column 0..15
.hb:
        cmp     cx, 16
        jae     .ascii
        mov     bx, bp
        add     bx, cx
        cmp     bx, [vlen]
        jae     .hpad
        mov     al, [viewbuf+bx]
        call    put_hex8
        jmp     .hsp
.hpad:
        mov     byte [di], ' '
        inc     di
        mov     byte [di], ' '
        inc     di
.hsp:
        mov     byte [di], ' '
        inc     di
        inc     cx
        jmp     .hb
.ascii:
        mov     byte [di], ' '              ; gutter before the ASCII column
        inc     di
        xor     cx, cx
.ac:
        cmp     cx, 16
        jae     .done
        mov     bx, bp
        add     bx, cx
        cmp     bx, [vlen]
        jae     .apad
        mov     al, [viewbuf+bx]
        cmp     al, 20h
        jb      .adot
        cmp     al, 7Eh
        ja      .adot
        jmp     .aput
.adot:
        mov     al, '.'
.aput:
        mov     [di], al
        inc     di
        inc     cx
        jmp     .ac
.apad:
        mov     byte [di], ' '
        inc     di
        inc     cx
        jmp     .ac
.done:
        pop     bp
        ret

; al = byte -> two hex digits at [di], di += 2. Preserves ax,bx,cx,bp.
put_hex8:
        push    ax
        mov     ah, al
        shr     al, 1
        shr     al, 1
        shr     al, 1
        shr     al, 1                       ; high nibble
        call    .nib
        mov     al, ah
        and     al, 0Fh                     ; low nibble
        call    .nib
        pop     ax
        ret
.nib:
        and     al, 0Fh
        cmp     al, 10
        jb      .dig
        add     al, 'A'-10
        jmp     .wr
.dig:
        add     al, '0'
.wr:
        mov     [di], al
        inc     di
        ret

; ax = word -> four hex digits at [di], di += 4. Clobbers ax; preserves bx,cx,bp.
put_hex16:
        push    ax
        mov     al, ah                      ; high byte first
        call    put_hex8
        pop     ax
        call    put_hex8                    ; low byte
        ret

; Enter hex view directly on the cursor file (Tools menu). Always built-in,
; bypassing the [view] external-viewer map.
key_hexview:
        mov     bx, [active]
        mov     cx, [bx+P_COUNT]
        jcxz    .skip
        call    cur_entry_ptr
        test    byte [si+E_ATTR], 10h
        jnz     .skip                       ; not a directory
        call    build_entry_path
        mov     byte [view_hex], 1
        jmp     view_open_builtin
.skip:
        ret

