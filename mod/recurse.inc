; @core (always compiled in; not a selectable feature)
;
; mod/recurse.inc  --  extracted from cc.asm (M1 module split, byte-identical)
; Plain implicit-text code only; no section/equ/macro (see plan/m1_split.md).

; ============================================================================
;  RECURSIVE DIRECTORY COPY / DELETE
;    rsrc / rdst : growable ASCIIZ working paths
;    findpat     : rsrc + "\*.*" search template
;    rdepth      : current recursion depth (selects a private DTA)
; ============================================================================
; set DOS DTA to the current depth's private buffer
set_dta_cur:
        push    ax
        push    dx
        mov     ax, [rdepth]
        mov     dx, DTASZ
        mul     dx
        add     ax, dta_stack
        mov     dx, ax
        mov     ah, 1Ah
        int     21h
        pop     dx
        pop     ax
        ret

; -> bx = current depth's DTA pointer
cur_dta_ptr:
        push    ax
        push    dx
        mov     ax, [rdepth]
        mov     dx, DTASZ
        mul     dx
        add     ax, dta_stack
        mov     bx, ax
        pop     dx
        pop     ax
        ret

; findpat = rsrc + "\*.*"
make_findpat:
        mov     si, rsrc
        mov     di, findpat
.cp:
        mov     al, [si]
        mov     [di], al
        or      al, al
        jz      .e
        inc     si
        inc     di
        jmp     .cp
.e:
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

; del_tree: delete the directory tree whose path is in rsrc, then the dir
; itself. Uses dta_stack[rdepth]; recurses with rdepth+1.
del_tree:
        mov     ax, [rdepth]
        cmp     ax, MAX_DEPTH
        jae     .ret                ; safety cap -> leave it
        call    set_dta_cur
        call    make_findpat
        mov     ah, 4Eh
        mov     cx, 37h
        mov     dx, findpat
        int     21h
        jc      .rmdir
.loop:
        call    cur_dta_ptr
        cmp     byte [bx+1Eh], '.'
        je      .next               ; '.' or '..'
        mov     di, rsrc
        call    strlen_di           ; di -> NUL of rsrc
        push    di                  ; truncation point
        mov     byte [di], '\'
        inc     di
        call    cur_dta_ptr
        lea     si, [bx+1Eh]
        call    bp_copy_name        ; append name
        call    cur_dta_ptr
        test    byte [bx+15h], 10h
        jz      .file
        inc     word [rdepth]       ; subdirectory -> recurse
        call    del_tree
        dec     word [rdepth]
        jmp     .after
.file:
        mov     si, rsrc
        call    busy_name
        mov     ah, 41h
        mov     dx, rsrc
        int     21h
.after:
        pop     di
        mov     byte [di], 0        ; truncate rsrc back
.next:
        call    set_dta_cur         ; recursion changed the DTA -> restore ours
        mov     ah, 4Fh
        int     21h
        jnc     .loop
.rmdir:
        mov     ah, 3Ah
        mov     dx, rsrc
        int     21h
.ret:
        ret

; copy_tree: copy the directory tree rsrc -> rdst (both ASCIIZ), creating rdst.
copy_tree:
        mov     ax, [rdepth]
        cmp     ax, MAX_DEPTH
        jae     .ret
        mov     ah, 39h             ; mkdir dest (ignore "exists")
        mov     dx, rdst
        int     21h
        call    set_dta_cur
        call    make_findpat        ; from rsrc
        mov     ah, 4Eh
        mov     cx, 37h
        mov     dx, findpat
        int     21h
        jc      .ret
.loop:
        call    cur_dta_ptr
        cmp     byte [bx+1Eh], '.'
        je      .next
        mov     di, rsrc            ; append \name to rsrc
        call    strlen_di
        push    di
        mov     byte [di], '\'
        inc     di
        call    cur_dta_ptr
        lea     si, [bx+1Eh]
        call    bp_copy_name        ; rsrc = full child source path
        ; skip the destination directory itself, so we don't recurse into the
        ; copy we are creating (copying a folder into its own subtree)
        mov     si, rsrc
        mov     di, dstroot
        call    streqi
        jc      .skipchild
        mov     di, rdst            ; append \name to rdst
        call    strlen_di
        push    di
        mov     byte [di], '\'
        inc     di
        call    cur_dta_ptr
        lea     si, [bx+1Eh]
        call    bp_copy_name
        call    cur_dta_ptr
        test    byte [bx+15h], 10h
        jz      .file
        inc     word [rdepth]       ; subdirectory -> recurse
        call    copy_tree
        dec     word [rdepth]
        jmp     .after
.file:
        mov     si, rsrc            ; copy_file uses targpath/targpath2
        mov     di, targpath
        call    bp_copy_name
        mov     si, rdst
        mov     di, targpath2
        call    bp_copy_name
        call    copy_file
.after:
        pop     di                  ; rdst truncation (pushed last)
        mov     byte [di], 0
        pop     di                  ; rsrc truncation
        mov     byte [di], 0
        cmp     byte [ow_cancel], 0
        jne     .ret                ; cancelled: stack is balanced here, unwind
        jmp     .next
.skipchild:
        pop     di                  ; only rsrc truncation was pushed
        mov     byte [di], 0
.next:
        call    set_dta_cur
        mov     ah, 4Fh
        int     21h
        jnc     .loop
.ret:
        ret

