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
        call    real_cur            ; archive / results / drives panel -> refuse
        jc      .ret
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
.single:                            ; si = cursor entry (count_tagged keeps it)
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
        mov     dx, targpath
        jmp     del_file
.ret:   ret

; delete the file named by ds:dx (LFN-aware). Clobbers ax (and si under LFN).
del_file:
%ifndef FEAT_LFN_FULL
        mov     ah, 41h
%else
        mov     ax, 7141h           ; LFN Delete
        xor     si, si              ; SI=0 required
        stc                         ; pre-DOS7 leaves CF alone on AH=71h
%endif
        int     21h
        ret

; CF=1 unless the active panel is a real directory (not an archive, results or
; drives list) with at least one entry; the file ops that act on
; P_PATH\E_NAME must never run on a virtual row. -> bx = [active], si = cursor.
real_cur:
        mov     bx, [active]
        call    cur_entry_ptr       ; si = cursor entry (flags clobbered)
        cmp     byte [bx+P_SRC], SRC_VFS    ; CF=1 iff SRC_DIR
        cmc
        jc      .r
        cmp     word [bx+P_COUNT], 1        ; CF=1 iff empty
.r:     ret

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
        mov     word [ow_mode], 0   ; reset overwrite policy + ow_cancel (next byte)
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
        ; otherwise overwrite each file with itself -- 3Ch truncates the source).
        ; Copying into a SUBfolder of the source is allowed; copy_tree just
        ; skips the destination dir so it doesn't descend into the copy it is
        ; creating. The compare is on TRUENAMEs (canon_pair).
        call    canon_pair          ; rsrc/rdst = canonical src/dst; CF=1 if same
        jc      .ret
        test    dl, 10h
        jz      copy_file
        ; directory: record the destination root, then recursive copy
        mov     si, rdst
        mov     di, dstroot
        call    bp_copy_name
        mov     word [rdepth], 0
        jmp     copy_tree
.ret:   ret

; rsrc/rdst = TRUENAME (INT 21h/60h) of targpath/targpath2 -- or the raw path
; if 60h fails -- so 8.3 truncation, '.'/'..', SUBST and case can't hide a
; copy onto itself. -> CF=1 if both name the same file. Preserves dl.
canon_pair:
        mov     si, targpath
        mov     di, rsrc
        call    .one
        mov     si, targpath2
        mov     di, rdst
        call    .one
        mov     si, rsrc
        mov     di, rdst
        jmp     streqi
.one:
        push    ds
        pop     es
        mov     ah, 60h             ; TRUENAME ds:si -> es:di (128 bytes)
        int     21h
        jc      bp_copy_name        ; no canonical form -> compare the raw path
        ret

; ----------------------------------------------------------------------------
; F6 -- MOVE: like copy, but removes the source after a successful transfer.
; A same-drive move is a single DOS rename (INT 21h/56h, atomic, works for
; files and whole directory trees and even renames in flight). A cross-drive
; move falls back to copy-then-delete.
; ----------------------------------------------------------------------------
key_move:
        call    other_panel_ptr     ; never move INTO an archive / results list
        cmp     byte [bx+P_SRC], SRC_DIR
        jne     .ret
        call    real_cur            ; ...nor out of one (bx = active, si = cursor)
        jc      .ret
        mov     word [ow_mode], 0   ; + ow_cancel (next byte)
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
.single:                            ; si = cursor entry (count_tagged keeps it)
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
        call    canon_pair          ; same file -> nothing to do
        jc      .ret
        ; refuse a directory moved into its own subtree (dst = src + '\...'):
        ; the copy fallback would copy it into itself, then delete the lot.
        mov     si, rsrc
        mov     di, rdst
.pre:   lodsb
        or      al, al
        jz      .pend
        cmp     al, [di]
        jne     .go
        inc     di
        jmp     .pre
.pend:  cmp     byte [di], '\'
        je      .ret
.go:
        push    dx                  ; dl = source attr (dx is needed below)
        push    ds                  ; fast path: same-drive rename/move
        pop     es
        mov     dx, targpath        ; ds:dx old name
        mov     di, targpath2       ; es:di new name
%ifndef FEAT_LFN_FULL
        mov     ah, 56h
%else
        mov     ax, 7156h           ; LFN Rename/Move
        stc
%endif
        int     21h
        pop     dx
        jnc     .ret                ; moved (and renamed) in one step
        ; rename failed: cross-drive, or destination exists. Copy across, then
        ; delete the source so the net effect is still a move -- but only if
        ; every file really arrived (skip / open / create / read / write / mkdir
        ; failures all set cp_fail) and the user didn't cancel.
        mov     byte [cp_fail], 0
        push    dx
        call    copy_one_paths
        pop     dx
        mov     al, [cp_fail]
        or      al, [ow_cancel]
        jnz     .ret                ; something was not copied -> keep the source
        test    dl, 10h
        jz      .delfile
        mov     word [rdepth], 0    ; rsrc = the source root (copy_tree restores it)
        jmp     del_tree
.delfile:
        mov     dx, targpath
        jmp     del_file
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

