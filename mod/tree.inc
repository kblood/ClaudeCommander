; mod/tree.inc  --  FEAT_TREE
; A modal directory-tree browser, opened with Alt-F10 (NC's own "tree" key).
;
; It is NOT a panel body view (P_VIEW): a fully-expanded tree shares no shape
; with the flat entry array -- a dir refresh or a file op on a "tree node" would
; act on the wrong path. Instead this is a self-contained full-screen modal, in
; the same family as the F3 viewer and the F1 help pager: it owns its own node
; buffer, its own cursor, and its own key loop, and touches NO core file-op or
; refresh code. So adding it is purely additive -- one keytab line + this file.
;
; The node buffer is borrowed from viewbuf (the F3 pager's scratch, idle while
; the tree is up) so the tree costs no new large .bss -- only a few state words.
; A node is {name[14], depth[1]} = TNSIZE bytes; we DFS-preorder the active
; panel's dir tree (dirs only) into it, using the recurse.inc DTA-stack idiom.
;
; Enter on a node chdir's the active panel into that directory (reconstructed by
; walking the ancestor chain) and closes. Esc / F10 / Alt-F10 close unchanged.

TN_NAME    equ 0
TN_DEPTH   equ 14
TNSIZE     equ 16
MAX_TNODES equ 512             ; 512*16 = 8 KB, fits inside viewbuf (14 KB)
TREE_ROWS  equ 23              ; visible list rows (screen rows 1..23)
TREE_W     equ 78              ; list width (cols 1..78)
A_TREE_CUR equ 070h            ; cursor row: black on white
A_TREE_BAR equ 030h            ; title / help bar: black on cyan

; ax = node index -> si = &node (preserves ax,dx).
tnode_ptr:
        push    ax
        push    dx
        mov     dx, TNSIZE
        mul     dx                  ; ax = index * TNSIZE
        mov     si, viewbuf
        add     si, ax
        pop     dx
        pop     ax
        ret

; ---------------------------------------------------------------------------
; Build the dir-only tree of the active panel's path into the node buffer.
tree_build:
        mov     word [t_count], 0
        mov     word [t_cur], 0
        mov     word [t_top], 0
        mov     word [rdepth], 0
        mov     bx, [active]
        lea     si, [bx+P_PATH]
        mov     di, rsrc            ; rsrc = growable working path (recurse scratch)
        call    bp_copy_name        ; copy P_PATH (incl NUL) into rsrc
        call    tree_walk
        ret

; Recursive DFS preorder: append each subdir of rsrc as a node at depth=rdepth,
; then descend into it. Mirrors del_tree's DTA-stack / FindNext-restore pattern.
tree_walk:
        mov     ax, [rdepth]
        cmp     ax, MAX_DEPTH
        jae     .ret
        mov     ax, [t_count]
        cmp     ax, MAX_TNODES
        jae     .ret
        call    set_dta_cur
        call    make_findpat        ; findpat = rsrc + "\*.*"
        mov     ah, 4Eh
        mov     cx, 37h             ; RO|Hidden|System|Dir|Archive
        mov     dx, findpat
        int     21h
        jc      .ret
.loop:
        call    cur_dta_ptr         ; bx -> this depth's DTA
        test    byte [bx+15h], 10h  ; directory?
        jz      .next
        cmp     byte [bx+1Eh], '.'  ; skip "." and ".."
        je      .next
        mov     ax, [t_count]
        cmp     ax, MAX_TNODES
        jae     .ret                ; buffer full -> stop the whole walk
        call    tree_add            ; append {name, rdepth}
        ; descend: rsrc += "\" + name
        mov     di, rsrc
        call    strlen_di           ; di -> NUL of rsrc
        push    di                  ; remember truncation point
        mov     byte [di], '\'
        inc     di
        call    cur_dta_ptr
        lea     si, [bx+1Eh]
        call    bp_copy_name        ; append child name (+NUL)
        inc     word [rdepth]
        call    tree_walk
        dec     word [rdepth]
        pop     di
        mov     byte [di], 0        ; truncate rsrc back to this level
.next:
        call    set_dta_cur         ; recursion clobbered the DTA -> restore ours
        mov     ah, 4Fh
        int     21h
        jnc     .loop
.ret:
        ret

; Append one node: name from the current DTA, depth = rdepth.
tree_add:
        mov     ax, [t_count]
        call    tnode_ptr           ; si = dest node
        mov     di, si              ; di -> TN_NAME (offset 0)
        call    cur_dta_ptr         ; bx -> DTA
        lea     si, [bx+1Eh]        ; DTA filename (ASCIIZ)
        mov     cx, 13              ; name field cap (8.3 fits in 12 + NUL)
.cn:
        mov     al, [si]
        mov     [di], al
        or      al, al
        jz      .dep
        inc     si
        inc     di
        loop    .cn
        mov     byte [di], 0        ; over-long: force terminate
.dep:
        mov     ax, [t_count]
        call    tnode_ptr           ; si = node base
        mov     al, [rdepth]        ; rdepth < MAX_DEPTH(24) -> fits a byte
        mov     [si+TN_DEPTH], al
        inc     word [t_count]
        ret

; ---------------------------------------------------------------------------
; Modal entry point (Alt-F10).
key_tree:
        call    hide_cursor
        call    tree_build
.loop:
        call    tree_render
        cmp     byte [test_mode], 0
        je      .live
        call    dump_screen         ; /T harness: capture this modal frame
.live:
        call    get_key             ; al=ascii, ah=scan
        or      al, al
        jnz     .ascii
        ; --- extended keys (al=0, scan in ah). Each sets dx = candidate cursor,
        ;     then jumps to .apply which clamps it; non-nav keys jmp .loop/exit. ---
        cmp     ah, 48h             ; Up
        jne     .k50
        mov     dx, [t_cur]
        dec     dx
        jmp     .apply
.k50:
        cmp     ah, 50h             ; Down
        jne     .k49
        mov     dx, [t_cur]
        inc     dx
        jmp     .apply
.k49:
        cmp     ah, 49h             ; PgUp
        jne     .k51
        mov     dx, [t_cur]
        sub     dx, TREE_ROWS-1
        jmp     .apply
.k51:
        cmp     ah, 51h             ; PgDn
        jne     .k47
        mov     dx, [t_cur]
        add     dx, TREE_ROWS-1
        jmp     .apply
.k47:
        cmp     ah, 47h             ; Home
        jne     .k4f
        xor     dx, dx
        jmp     .apply
.k4f:
        cmp     ah, 4Fh             ; End
        jne     .ketc
        mov     dx, [t_count]
        dec     dx
        jmp     .apply
.ketc:
        cmp     ah, 1Ch
        je      .enter              ; gray-Enter variant
        cmp     ah, 44h
        je      .close              ; F10 (also get_key's script-exhaustion key)
        cmp     ah, 71h
        je      .close              ; Alt-F10 again -> toggle off
        jmp     .loop
.ascii:
        cmp     al, 1Bh
        je      .close              ; Esc
        cmp     al, 0Dh
        je      .enter              ; Enter
        jmp     .loop               ; ignore any other printable
; clamp dx into [0, t_count-1], store as cursor, keep visible, re-render.
.apply:
        mov     cx, [t_count]
        jcxz    .reloop             ; empty tree -> nothing to move
        or      dx, dx
        jns     .lo
        xor     dx, dx              ; below 0 -> 0
.lo:
        cmp     dx, cx
        jb      .hi
        mov     dx, cx
        dec     dx                  ; past end -> last
.hi:
        mov     [t_cur], dx
        call    tree_fix
.reloop:
        jmp     .loop
.enter:
        mov     cx, [t_count]
        jcxz    .close              ; no subdirs -> just close
        call    tree_goto
.close:
        call    render_all          ; repaint the normal two-panel screen
        ret

; Keep the cursor node within the visible window [t_top .. t_top+TREE_ROWS-1].
tree_fix:
        mov     ax, [t_cur]
        cmp     ax, [t_top]
        jae     .chkhi
        mov     [t_top], ax
        ret
.chkhi:
        mov     ax, [t_top]
        add     ax, TREE_ROWS-1
        cmp     [t_cur], ax
        jbe     .ret
        mov     ax, [t_cur]
        sub     ax, TREE_ROWS-1
        mov     [t_top], ax
.ret:
        ret

; ---------------------------------------------------------------------------
; chdir the active panel into the cursor node's directory.
;   1) forward-scan nodes 0..t_cur, recording tree_comp[depth] = &node.name for
;      the chain on the path to the cursor (a preorder scan leaves each ancestor
;      depth slot holding the most recent node at that depth -- i.e. our parent);
;   2) append comp[0..cursor-depth] onto the active panel path;
;   3) read_dir.
tree_goto:
        mov     ax, [t_cur]
        call    tnode_ptr
        movzx   ax, byte [si+TN_DEPTH]
        mov     [t_depth], ax
        xor     bx, bx              ; bx = scan index i
.scan:
        mov     ax, bx
        call    tnode_ptr           ; si = node i
        movzx   ax, byte [si+TN_DEPTH]
        cmp     ax, MAX_DEPTH
        jae     .cont
        shl     ax, 1
        mov     di, ax
        mov     [tree_comp+di], si  ; comp[depth] = &node (TN_NAME at offset 0)
.cont:
        cmp     bx, [t_cur]
        jae     .build
        inc     bx
        jmp     .scan
.build:
        xor     bx, bx              ; bx = chain level L = 0..t_depth
.ap:
        mov     ax, [t_depth]
        cmp     bx, ax
        ja      .reread
        mov     di, bx
        shl     di, 1
        mov     di, [tree_comp+di]  ; di -> node name (path_append wants di=name)
        push    bx
        call    path_append         ; appends "\name" to active P_PATH
        pop     bx
        inc     bx
        jmp     .ap
.reread:
        mov     bx, [active]
        call    read_dir
        ret

; ---------------------------------------------------------------------------
; Full-screen render: title bar (row 0) + indented node list + help bar (row 24).
tree_render:
        call    tree_clear
        ; --- title bar: " Tree: <active path>" padded to 80, attr A_TREE_BAR ---
        mov     di, linebuf
        mov     si, tree_hdr
        call    tree_appendz
        mov     bx, [active]
        lea     si, [bx+P_PATH]
        call    tree_appendz
        mov     ax, di
        sub     ax, linebuf         ; current length
        mov     cx, SCR_W
        sub     cx, ax
        jbe     .t0
        mov     al, ' '
        rep     stosb               ; pad to 80
.t0:
        mov     si, linebuf
        mov     cx, SCR_W
        mov     ah, A_TREE_BAR
        xor     di, di              ; row 0, col 0
        call    putbuf
        ; --- node rows ---
        xor     bp, bp              ; bp = visible row 0..TREE_ROWS-1
.row:
        cmp     bp, TREE_ROWS
        jae     .help
        mov     ax, [t_top]
        add     ax, bp
        cmp     ax, [t_count]
        jae     .nextrow            ; past the end -> leave cleared
        push    ax                  ; node index
        call    tnode_ptr           ; si = node
        call    tree_line           ; linebuf = indent+name padded to TREE_W
        mov     ax, bp
        inc     ax                  ; screen row = 1 + bp
        mov     bx, 1               ; col 1
        call    rc_to_off           ; -> di
        pop     ax                  ; node index
        mov     ah, A_DIR
        cmp     ax, [t_cur]
        jne     .a0
        mov     ah, A_TREE_CUR
.a0:
        mov     si, linebuf
        mov     cx, TREE_W
        call    putbuf
.nextrow:
        inc     bp
        jmp     .row
.help:
        mov     si, tree_help
        call    tree_pad80          ; linebuf = help text padded to 80
        mov     ax, 24
        xor     bx, bx
        call    rc_to_off           ; row 24, col 0 -> di
        mov     si, linebuf
        mov     cx, SCR_W
        mov     ah, A_TREE_BAR
        call    putbuf
        ret

; Clear the whole screen to A_NORM spaces.
tree_clear:
        push    es
        mov     ax, VIDEO
        mov     es, ax
        xor     di, di
        mov     cx, SCR_W*SCR_H
        mov     ax, (A_NORM<<8)|' '
        rep     stosw
        pop     es
        ret

; Build one node line into linebuf: depth*2 indent spaces + name, then space-pad
; to TREE_W (no NUL). si = node ptr on entry; clobbers ax,bx,cx,di,si.
tree_line:
        movzx   cx, byte [si+TN_DEPTH]
        shl     cx, 1               ; indent = depth * 2
        cmp     cx, 40
        jbe     .ic
        mov     cx, 40              ; cap runaway indent
.ic:
        mov     di, linebuf
        mov     al, ' '
        rep     stosb               ; emit indent
        lea     si, [si+TN_NAME]
.cp:
        mov     al, [si]
        or      al, al
        jz      .pad
        mov     bx, di
        sub     bx, linebuf
        cmp     bx, TREE_W
        jae     .pad
        mov     [di], al
        inc     di
        inc     si
        jmp     .cp
.pad:
        mov     ax, di
        sub     ax, linebuf
        cmp     ax, TREE_W
        jae     .done
        mov     cx, TREE_W
        sub     cx, ax
        mov     al, ' '
        rep     stosb
.done:
        ret

; Copy ASCIIZ ds:si into ds:di (di left just past last char, NUL not stored).
tree_appendz:
.c:
        mov     al, [si]
        or      al, al
        jz      .e
        mov     [di], al
        inc     di
        inc     si
        jmp     .c
.e:
        ret

; si = ASCIIZ -> linebuf = source then spaces to 80 (clipped at 80). Clobbers
; ax,cx,di,si.
tree_pad80:
        mov     di, linebuf
        mov     cx, SCR_W
.cp:
        mov     al, [si]
        or      al, al
        jz      .pad
        mov     [di], al
        inc     di
        inc     si
        loop    .cp
        ret
.pad:
        mov     al, ' '
        rep     stosb               ; remaining cx spaces
        ret

tree_hdr    db ' Tree: ', 0
tree_help   db ' Up/Dn  PgUp/PgDn  Home/End    Enter: go to dir    Esc: cancel', 0
