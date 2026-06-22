; mod/fileops.inc  --  extracted from cc.asm (M1 module split, byte-identical)
; Plain implicit-text code only; no section/equ/macro (see plan/m1_split.md).

; F7 -- make directory
key_mkdir:
        mov     si, s_mkdir
        call    dlg_input
        jc      .ret
        cmp     word [dlglen], 0
        je      .ret
        call    build_target_path
        mov     dx, targpath2
        mov     ah, 39h
        int     21h
        call    refresh_panels
.ret:   ret

; F8 -- delete: all tagged entries if any, else the cursor entry. Recurses
; into directory trees. One confirm for the whole batch.
key_delete:
        mov     bx, [active]
        mov     cx, [bx+P_COUNT]
        jcxz    .ret
        call    count_tagged        ; -> cx = # tagged in active panel
        jcxz    .single
        mov     si, s_delconf
        call    dlg_confirm
        jc      .ret
        mov     si, s_busy_del
        call    busy_box
        mov     word [iter_i], 0
.bl:
        mov     bx, [active]
        mov     ax, [iter_i]
        cmp     ax, [bx+P_COUNT]
        jae     .bdone
        mov     [ppanel], bx
        call    entry_ptr           ; si = entry[ax]
        test    byte [si+E_ATTR], 40h
        jz      .bnext
        call    delete_one
.bnext:
        inc     word [iter_i]
        jmp     .bl
.bdone:
        call    refresh_panels
        ret
.single:
        mov     bx, [active]
        call    cur_entry_ptr       ; si=entry
        mov     al, [si+E_NAME]
        cmp     al, '.'
        jne     .ok
        cmp     byte [si+E_NAME+1], '.'
        je      .ret                ; never delete ".."
.ok:
        push    si
        mov     si, s_delconf
        call    dlg_confirm
        pop     si
        jc      .ret                ; user said No
        push    si
        mov     si, s_busy_del
        call    busy_box
        pop     si
        call    delete_one
        call    refresh_panels
.ret:   ret

; delete one entry (si=entry in active panel): file, or whole directory tree
delete_one:
        mov     al, [si+E_NAME]
        cmp     al, '.'
        je      .ret                ; never touch '.' / '..'
        call    build_entry_path    ; targpath = active\name (si preserved)
        test    byte [si+E_ATTR], 10h
        jz      .file
        push    si                  ; recursive directory delete
        mov     si, targpath
        mov     di, rsrc
        call    bp_copy_name
        mov     word [rdepth], 0
        call    del_tree
        pop     si
        ret
.file:
        mov     si, targpath
        call    busy_name
        mov     ah, 41h
        mov     dx, targpath
        int     21h
.ret:   ret

; F5 -- copy: all tagged entries if any, else the cursor entry. Recurses into
; directory trees. One confirm for the whole batch.
key_copy:
        mov     byte [ow_mode], 0   ; reset overwrite policy for this operation
        mov     byte [ow_cancel], 0
        mov     bx, [active]
        mov     cx, [bx+P_COUNT]
        jcxz    .ret
        call    count_tagged        ; -> cx = # tagged
        jcxz    .single
        mov     si, s_copyconf
        call    dlg_confirm
        jc      .ret
        mov     si, s_busy_copy
        call    busy_box
        mov     word [iter_i], 0
.bl:
        mov     bx, [active]
        mov     ax, [iter_i]
        cmp     ax, [bx+P_COUNT]
        jae     .bdone
        mov     [ppanel], bx
        call    entry_ptr           ; si = entry[ax]
        test    byte [si+E_ATTR], 40h
        jz      .bnext
        call    copy_one
        cmp     byte [ow_cancel], 0
        jne     .bdone              ; user cancelled the whole batch
.bnext:
        inc     word [iter_i]
        jmp     .bl
.bdone:
        call    refresh_panels
        ret
.single:
        mov     bx, [active]
        call    cur_entry_ptr
        push    si
        mov     si, s_copyconf
        call    dlg_confirm
        pop     si
        jc      .ret
        push    si
        mov     si, s_busy_copy
        call    busy_box
        pop     si
        call    copy_one
        call    refresh_panels
.ret:   ret

; copy one entry (si=entry in active panel) to the OTHER panel's directory.
; File -> copy_file; directory -> recursive copy_tree. Skips '.'/'..' and any
; case where source path == destination path (would self-destruct).
copy_one:
        mov     al, [si+E_NAME]
        cmp     al, '.'
        je      .ret
        call    build_entry_path    ; targpath  = active\name (si preserved)
        call    build_other_path    ; targpath2 = other\name  (si preserved)
        mov     dl, [si+E_ATTR]     ; remember attr across the guard
        ; refuse ONLY the exact same-location copy (it is a no-op and would
        ; otherwise overwrite each file with itself). Copying into a SUBfolder
        ; of the source is allowed; copy_tree just skips the destination dir so
        ; it doesn't descend into the copy it is creating.
        mov     si, targpath
        mov     di, targpath2
        call    streqi              ; CF=1 if dst path == src path
        jc      .ret
        test    dl, 10h
        jz      .file
        ; directory: record the destination root, then recursive copy
        mov     si, targpath2
        mov     di, dstroot
        call    bp_copy_name
        mov     si, targpath
        mov     di, rsrc
        call    bp_copy_name
        mov     si, targpath2
        mov     di, rdst
        call    bp_copy_name
        mov     word [rdepth], 0
        call    copy_tree
        ret
.file:
        call    copy_file
.ret:   ret

; count tagged (E_ATTR bit 0x40) entries in the active panel -> cx
count_tagged:
        push    ax
        push    bx
        push    si
        mov     bx, [active]
        mov     [ppanel], bx
        xor     cx, cx
        xor     ax, ax
.l:
        cmp     ax, [bx+P_COUNT]
        jae     .e
        push    ax
        call    entry_ptr           ; si = entry[ax]
        test    byte [si+E_ATTR], 40h
        jz      .nx
        inc     cx
.nx:
        pop     ax
        inc     ax
        jmp     .l
.e:
        pop     si
        pop     bx
        pop     ax
        ret

; compare ASCIIZ ds:si vs ds:di -> ZF=1 if equal. Preserves dl.
; case-insensitive ASCIIZ compare ds:si vs ds:di -> CF=1 if equal, else CF=0.
; Preserves dl; clobbers al/ah.
streqi:
        push    si
        push    di
.l:
        mov     al, [si]
        mov     ah, [di]
        cmp     al, 'a'             ; uppercase al
        jb      .a1
        cmp     al, 'z'
        ja      .a1
        sub     al, 20h
.a1:
        cmp     ah, 'a'             ; uppercase ah
        jb      .a2
        cmp     ah, 'z'
        ja      .a2
        sub     ah, 20h
.a2:
        cmp     al, ah
        jne     .ne
        or      al, al
        jz      .eq
        inc     si
        inc     di
        jmp     .l
.eq:
        pop     di
        pop     si
        stc
        ret
.ne:
        pop     di
        pop     si
        clc
        ret

