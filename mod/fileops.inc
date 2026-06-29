; @core (always compiled in; not a selectable feature)
;
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
%ifndef FEAT_LFN_FULL
        mov     ah, 39h
%else
        mov     ax, 7139h           ; LFN Make Directory
%endif
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
%ifndef FEAT_LFN_FULL
        mov     ah, 41h
        mov     dx, targpath
%else
        mov     ax, 7141h           ; LFN Delete
        mov     dx, targpath
        xor     si, si              ; SI=0 required
%endif
        int     21h
.ret:   ret

; F5 -- copy: all tagged entries if any, else the cursor entry. Recurses into
; directory trees. One confirm for the whole batch.
key_copy:
%ifdef FEAT_RESULTS
        mov     bx, [active]
        cmp     byte [bx+P_SRC], SRC_RESULT
        je      .ret                ; copying from a results listing is disabled
%endif
%ifdef FEAT_VFS
        mov     bx, [active]
        cmp     byte [bx+P_VFS], 1  ; only a real container (==1) extracts members
        jne     .activereal
        jmp     vfs_extract         ; F5 inside a container -> extract member out
.activereal:
        ; active panel is real; if the OTHER panel is a container, copy the
        ; tagged/cursor files INTO that archive instead of onto the filesystem.
        call    other_panel_ptr
        cmp     byte [bx+P_VFS], 1
        jne     .notvfs
        jmp     vfs_addto           ; F5 -> add files into the other archive
.notvfs:
%endif
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
        ; single entry: prompt for the destination NAME (default = source
        ; name) in the OTHER panel -- this is how you copy-and-rename.
        mov     bx, [active]
        call    cur_entry_ptr
        mov     al, [si+E_NAME]
        cmp     al, '.'
        je      .ret                ; never copy '.' / '..'
        push    si
        call    prefill_name        ; dlgbuf = source name
        mov     si, s_copyto
        call    dlg_input_pre
        pop     si
        jc      .ret                ; Esc
        cmp     word [dlglen], 0
        je      .ret
        push    si
        mov     si, s_busy_copy
        call    busy_box
        pop     si
        call    build_entry_path    ; targpath  = source full path
        call    build_other_named   ; targpath2 = other-panel\dlgbuf
        mov     dl, [si+E_ATTR]
        call    copy_one_paths
        call    refresh_panels
.ret:   ret

; copy one entry (si=entry in active panel) to the OTHER panel's directory,
; keeping the same name. Used by the tagged-batch loop.
copy_one:
        mov     al, [si+E_NAME]
        cmp     al, '.'
        je      .ret
        call    build_entry_path    ; targpath  = active\name (si preserved)
        call    build_other_path    ; targpath2 = other\name  (si preserved)
        mov     dl, [si+E_ATTR]     ; remember attr across the guard
        jmp     copy_one_paths
.ret:   ret

; copy: targpath (src) and targpath2 (dst) are already built; dl = src attr.
; File -> copy_file; directory -> recursive copy_tree. Refuses a same-path
; copy (would self-destruct). Used by both the single and batch copy paths.
copy_one_paths:
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

; ----------------------------------------------------------------------------
; F6 -- MOVE: like copy, but removes the source after a successful transfer.
; A same-drive move is a single DOS rename (INT 21h/56h, atomic, works for
; files and whole directory trees and even renames in flight). A cross-drive
; move falls back to copy-then-delete.
; ----------------------------------------------------------------------------
key_move:
        mov     byte [ow_mode], 0
        mov     byte [ow_cancel], 0
        mov     bx, [active]
        mov     cx, [bx+P_COUNT]
        jcxz    .ret
        call    count_tagged        ; -> cx = # tagged
        jcxz    .single
        mov     si, s_moveconf
        call    dlg_confirm
        jc      .ret
        mov     si, s_busy_move
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
        call    move_one
        cmp     byte [ow_cancel], 0
        jne     .bdone
.bnext:
        inc     word [iter_i]
        jmp     .bl
.bdone:
        call    refresh_panels
        ret
.single:
        mov     bx, [active]
        call    cur_entry_ptr
        mov     al, [si+E_NAME]
        cmp     al, '.'
        je      .ret
        push    si
        call    prefill_name        ; dlgbuf = source name (editable -> rename)
        mov     si, s_moveto
        call    dlg_input_pre
        pop     si
        jc      .ret
        cmp     word [dlglen], 0
        je      .ret
        push    si
        mov     si, s_busy_move
        call    busy_box
        pop     si
        call    build_entry_path    ; targpath  = source full path
        call    build_other_named   ; targpath2 = other-panel\dlgbuf
        mov     dl, [si+E_ATTR]
        call    move_one_paths
        call    refresh_panels
.ret:   ret

; move one tagged entry (si) to the OTHER panel's dir, keeping its name.
move_one:
        mov     al, [si+E_NAME]
        cmp     al, '.'
        je      .ret
        call    build_entry_path
        call    build_other_path
        mov     dl, [si+E_ATTR]
        jmp     move_one_paths
.ret:   ret

; move: targpath (src) and targpath2 (dst) already built; dl = src attr.
move_one_paths:
        mov     si, targpath
        mov     di, targpath2
        call    streqi              ; same path -> nothing to do
        jc      .ret
        push    ds                  ; fast path: same-drive rename/move
        pop     es
        mov     dx, targpath        ; ds:dx old name
        mov     di, targpath2       ; es:di new name
%ifndef FEAT_LFN_FULL
        mov     ah, 56h
%else
        mov     ax, 7156h           ; LFN Rename/Move
%endif
        int     21h
        jnc     .ret                ; moved (and renamed) in one step
        ; rename failed: cross-drive, or destination exists. Copy across, then
        ; delete the source so the net effect is still a move.
        call    copy_one_paths
        cmp     byte [ow_cancel], 0
        jne     .ret                ; user cancelled overwrite -> keep source
        test    dl, 10h
        jz      .delfile
        mov     si, targpath        ; delete the source directory tree
        mov     di, rsrc
        call    bp_copy_name
        mov     word [rdepth], 0
        call    del_tree
        ret
.delfile:
%ifndef FEAT_LFN_FULL
        mov     ah, 41h
        mov     dx, targpath
%else
        mov     ax, 7141h           ; LFN Delete
        mov     dx, targpath
        xor     si, si              ; SI=0 required
%endif
        int     21h
.ret:   ret

; targpath2 = OTHER-panel path + '\' + dlgbuf (the typed destination name).
build_other_named:
        push    si
        call    other_panel_ptr     ; -> bx
        lea     si, [bx+P_PATH]
        mov     di, targpath2
        call    bp_copy_dir         ; copy dir, ensure trailing '\'
        mov     si, dlgbuf
        call    bp_copy_name        ; append the (possibly edited) name
        pop     si
        ret

; dlgbuf = source entry name (si=entry); set dlglen. Used to pre-fill the
; copy/move destination dialog so the user only edits to rename.
prefill_name:
        push    si
        lea     si, [si+E_NAME]
        mov     di, dlgbuf
.cp:    mov     al, [si]
        mov     [di], al
        or      al, al
        jz      .done
        inc     si
        inc     di
        jmp     .cp
.done:  mov     ax, di
        sub     ax, dlgbuf
        mov     [dlglen], ax
        pop     si
        ret

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

