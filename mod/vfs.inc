; mod/vfs.inc  --  FEAT_VFS: browse container files (ZIP, ...) as folders.
;
; A panel is either a REAL directory or a VIRTUAL container view (P_VFS=1).
; Entering a container runs "<helper> L <container> >DIR\CCVFS.LST" (the helper
; emits one "<size> <name>" line per member), then loads that listing into the
; panel's entry array with a synthetic ".." at the top. Backspace / Enter on
; ".." (handled in go_parent) clears P_VFS and re-reads the real directory.
;
; The extension -> helper map lives in cc.ini's [open] section (see ini.inc),
; so new container formats are added with a new .COM + one cc.ini line.

; si = cursor entry (a file whose extension is registered). Remember the
; container name, mark the panel virtual, and list it.
vfs_enter:
        mov     bx, [active]
        lea     si, [si+E_NAME]
        lea     di, [bx+P_CNAME]
        call    vfs_cpz             ; P_CNAME = container filename
        mov     bx, [active]
        mov     byte [bx+P_VFS], 1
        call    vfs_relist          ; bx = panel
        ret

; bx = a virtual panel (P_VFS=1, P_CNAME set). Build the helper command and the
; listing path, run the helper, then parse the listing into the panel.
vfs_relist:
        mov     [vfs_pan], bx
        ; vfs_lpath = P_PATH + '\' + "CCVFS.LST"
        lea     si, [bx+P_PATH]
        mov     di, vfs_lpath
        call    bp_copy_dir
        mov     si, s_vfslst
        call    bp_copy_name
        ; vfs_cpath = P_PATH + '\' + P_CNAME   (the container's real path)
        mov     bx, [vfs_pan]
        lea     si, [bx+P_PATH]
        mov     di, vfs_cpath
        call    bp_copy_dir
        mov     bx, [vfs_pan]
        lea     si, [bx+P_CNAME]
        call    bp_copy_name
        ; helper for this extension
        mov     bx, [vfs_pan]
        lea     si, [bx+P_CNAME]
        call    open_lookup         ; di -> helper, CF=1 if found
        jnc     .empty
        mov     [vfs_helper], di
        ; cmdbuf = helper + " L " + vfs_cpath + " >" + vfs_lpath
        mov     di, cmdbuf
        mov     si, [vfs_helper]
        call    vfs_cat
        mov     si, s_vfs_l
        call    vfs_cat
        mov     si, vfs_cpath
        call    vfs_cat
        mov     si, s_vfs_redir
        call    vfs_cat
        mov     si, vfs_lpath
        call    vfs_cat
        mov     ax, di
        sub     ax, cmdbuf
        mov     [cmdlen], ax
        call    run_helper          ; silent EXEC (no screen/panel/key churn)
        mov     word [cmdlen], 0
        call    vfs_load
        ret
.empty:
        ; unknown container: present an empty folder (just "..")
        call    vfs_load_empty
        ret

; Parse vfs_lpath ("<size> <name>" lines) into the panel entries, ".." first.
vfs_load:
        call    vfs_load_empty      ; seed ".." and count=1
        mov     ax, 3D00h
        mov     dx, vfs_lpath
        int     21h
        jc      .ret
        mov     bx, ax
        mov     ah, 3Fh
        mov     cx, VIEW_MAX-1
        mov     dx, viewbuf
        int     21h
        push    ax
        mov     ah, 3Eh             ; close (bx still = handle)
        int     21h
        mov     ah, 41h             ; delete the scratch listing (kept in RAM)
        mov     dx, vfs_lpath
        int     21h
        pop     ax                  ; bytes read
        mov     si, viewbuf
        add     ax, si
        mov     [vfs_end], ax
.pl:
        cmp     si, [vfs_end]
        jae     .fin
        mov     al, [si]
        or      al, al
        jz      .fin
        cmp     al, 0Dh
        je      .skip
        cmp     al, 0Ah
        je      .skip
        cmp     al, ' '
        je      .skip
        call    vfs_parse_line      ; consumes one line, adds one entry
        jmp     .pl
.skip:
        inc     si
        jmp     .pl
.fin:
        mov     bx, [vfs_pan]
        mov     ax, [_count]
        mov     [bx+P_COUNT], ax
        mov     word [bx+P_TOP], 0
        mov     word [bx+P_CUR], 0
.ret:
        ret

; Seed the panel with a single ".." directory entry (count = 1).
vfs_load_empty:
        mov     bx, [vfs_pan]
        mov     [ppanel], bx
        xor     ax, ax
        call    entry_ptr           ; si = entry[0]
        mov     byte [si+E_NAME], '.'
        mov     byte [si+E_NAME+1], '.'
        mov     byte [si+E_NAME+2], 0
        mov     byte [si+E_ATTR], 10h
        mov     word [si+E_SIZE], 0
        mov     word [si+E_SIZE+2], 0
        mov     word [_count], 1
        mov     bx, [vfs_pan]
        mov     word [bx+P_COUNT], 1
        mov     word [bx+P_TOP], 0
        mov     word [bx+P_CUR], 0
        ret

; si -> start of a "<decimal-size> <name>\r\n" line. Adds an entry; leaves si
; at the line's CR/LF/NUL terminator.
vfs_parse_line:
        xor     ax, ax              ; dx:ax = running size
        xor     dx, dx
.num:
        mov     bl, [si]
        cmp     bl, '0'
        jb      .numd
        cmp     bl, '9'
        ja      .numd
        sub     bl, '0'
        xor     bh, bh              ; bx = digit
        push    bx
        push    si
        mov     cx, dx              ; dx:ax = dx:ax * 10
        mov     bx, 10
        mul     bx                  ; dx:ax = oldlow*10, dx = carry
        mov     si, dx
        xchg    ax, cx              ; ax = oldhigh, cx = newlow
        mul     bx                  ; ax = oldhigh*10
        add     ax, si
        mov     dx, ax              ; new high
        mov     ax, cx              ; new low
        pop     si
        pop     bx                  ; bx = digit
        add     ax, bx
        adc     dx, 0
        inc     si
        jmp     .num
.numd:
        push    ax                  ; stash size (low, high)
        push    dx
.sp:
        cmp     byte [si], ' '
        jne     .name
        inc     si
        jmp     .sp
.name:
        mov     cx, [_count]
        cmp     cx, MAX_FILES
        jae     .full
        push    si                  ; save read cursor
        mov     ax, cx
        call    entry_ptr           ; si = dest entry
        mov     di, si
        pop     si                  ; restore read cursor
        pop     dx                  ; size high
        pop     ax                  ; size low
        mov     [di+E_SIZE], ax
        mov     [di+E_SIZE+2], dx
        mov     byte [di+E_ATTR], 20h   ; archive bit = plain file
        push    di
        lea     di, [di+E_NAME]
        mov     cx, 13
.cn:
        mov     al, [si]
        or      al, al
        jz      .cne
        cmp     al, 0Dh
        je      .cne
        cmp     al, 0Ah
        je      .cne
        jcxz    .cna
        mov     [di], al
        inc     di
        dec     cx
.cna:
        inc     si
        jmp     .cn
.cne:
        mov     byte [di], 0
        pop     di
        inc     word [_count]
        ret
.full:
        pop     dx                  ; discard stashed size
        pop     ax
.fsk:
        mov     al, [si]
        or      al, al
        jz      .fd
        cmp     al, 0Ah
        je      .fd
        inc     si
        jmp     .fsk
.fd:
        ret

; F5 on a container panel: extract the cursor member into the OTHER panel's
; directory via "<helper> X <container> <member-index> <destdir>". The member
; index matches the L listing (entry 0 is the synthetic ".."), so it is the
; cursor index minus one.
vfs_extract:
        mov     bx, [active]
        mov     ax, [bx+P_CUR]
        or      ax, ax
        jz      .ret                ; cursor on ".." -> nothing to extract
        dec     ax
        mov     [vfs_idx], ax
        mov     [vfs_pan], bx
        ; vfs_cpath = P_PATH + '\' + P_CNAME
        lea     si, [bx+P_PATH]
        mov     di, vfs_cpath
        call    bp_copy_dir
        mov     bx, [vfs_pan]
        lea     si, [bx+P_CNAME]
        call    bp_copy_name
        ; helper for this container's extension
        mov     bx, [vfs_pan]
        lea     si, [bx+P_CNAME]
        call    open_lookup         ; di -> helper, CF=1 if found
        jnc     .ret
        mov     [vfs_helper], di
        ; cmdbuf = helper + " X " + vfs_cpath + " " + idx + " " + destdir
        mov     di, cmdbuf
        mov     si, [vfs_helper]
        call    vfs_cat
        mov     si, s_vfs_x
        call    vfs_cat
        mov     si, vfs_cpath
        call    vfs_cat
        mov     si, s_vfs_sp
        call    vfs_cat
        mov     ax, [vfs_idx]
        call    vfs_putdec
        mov     si, s_vfs_sp
        call    vfs_cat
        call    other_panel_ptr     ; bx = destination (real) panel
        lea     si, [bx+P_PATH]
        call    vfs_cat
        mov     ax, di
        sub     ax, cmdbuf
        mov     [cmdlen], ax
        call    run_helper          ; silent EXEC
        mov     word [cmdlen], 0
        call    refresh_panels      ; show the extracted file in the other panel
.ret:
        ret

; append the decimal representation of ax at [di]; di advanced.
vfs_putdec:
        push    bx
        push    cx
        push    dx
        mov     bx, 10
        xor     cx, cx
.dv:
        xor     dx, dx
        div     bx
        push    dx
        inc     cx
        or      ax, ax
        jnz     .dv
.pp:
        pop     dx
        add     dl, '0'
        mov     [di], dl
        inc     di
        loop    .pp
        pop     dx
        pop     cx
        pop     bx
        ret

; Alt-F9: extract EVERY member of the .zip under the cursor (real panel) into
; the other panel via "<helper> XA <container> <destdir>".
key_unpackall:
        mov     bx, [active]
        cmp     byte [bx+P_VFS], 0
        jne     .ret                ; cursor must be a real file (the archive)
        mov     [vfs_pan], bx
        call    cur_entry_ptr       ; si = cursor entry
        cmp     byte [si+E_NAME], '.'
        je      .ret
        push    si
        mov     bx, [vfs_pan]
        lea     si, [bx+P_PATH]
        mov     di, vfs_cpath
        call    bp_copy_dir
        pop     si
        lea     si, [si+E_NAME]
        call    bp_copy_name        ; vfs_cpath = P_PATH\name
        mov     bx, [vfs_pan]
        call    cur_entry_ptr
        lea     si, [si+E_NAME]
        call    open_lookup         ; di -> helper, CF=1 if found
        jnc     .ret
        mov     [vfs_helper], di
        mov     di, cmdbuf
        mov     si, [vfs_helper]
        call    vfs_cat
        mov     si, s_vfs_xa
        call    vfs_cat
        mov     si, vfs_cpath
        call    vfs_cat
        mov     si, s_vfs_sp
        call    vfs_cat
        call    other_panel_ptr     ; bx = destination panel
        lea     si, [bx+P_PATH]
        call    vfs_cat
        mov     ax, di
        sub     ax, cmdbuf
        mov     [cmdlen], ax
        call    run_helper
        mov     word [cmdlen], 0
        call    refresh_panels
.ret:
        ret

; Alt-F5: pack the tagged entries (or the cursor) of the active panel into a
; new archive in the OTHER panel.  Prompts for the archive name; the target's
; extension selects the packer via the [open] map (so ARCHIVE.ZIP -> CCZIP).
; Files are listed (one full path per line) into a scratch CCPACK.LST that the
; helper consumes as "<helper> A <target> @<listfile>".
key_pack:
        mov     bx, [active]
        cmp     byte [bx+P_VFS], 0
        jne     .ret                ; can't pack from inside a container
        mov     si, s_defzip
        mov     di, dlgbuf
        call    vfs_cat
        mov     ax, di
        sub     ax, dlgbuf
        mov     [dlglen], ax
        mov     si, s_packto
        call    dlg_input_pre
        jc      .ret
        cmp     word [dlglen], 0
        je      .ret
        ; listpath = active P_PATH\CCPACK.LST  (reuses vfs_lpath storage)
        mov     bx, [active]
        lea     si, [bx+P_PATH]
        mov     di, vfs_lpath
        call    bp_copy_dir
        mov     si, s_packlst
        call    bp_copy_name
        mov     ah, 3Ch
        xor     cx, cx
        mov     dx, vfs_lpath
        int     21h
        jc      .ret
        mov     [pack_fh], ax
        mov     word [pack_n], 0
        call    count_tagged        ; cx = # tagged
        or      cx, cx
        jz      .single
        mov     word [iter_i], 0
.tl:
        mov     bx, [active]
        mov     ax, [iter_i]
        cmp     ax, [bx+P_COUNT]
        jae     .wdone
        mov     [ppanel], bx
        call    entry_ptr           ; si = entry[ax]
        test    byte [si+E_ATTR], 40h
        jz      .tnext
        call    pack_write_line
.tnext:
        inc     word [iter_i]
        jmp     .tl
.single:
        mov     bx, [active]
        call    cur_entry_ptr
        call    pack_write_line
.wdone:
        mov     bx, [pack_fh]
        mov     ah, 3Eh
        int     21h
        ; nothing packable (only dirs / .. were selected)? warn, make no archive
        cmp     word [pack_n], 0
        jne     .havefiles
        mov     si, s_packempty
        call    dlg_confirm
        jmp     .cleanup
.havefiles:
        ; target = other P_PATH\<dlgbuf>
        call    other_panel_ptr
        lea     si, [bx+P_PATH]
        mov     di, packtarg
        call    bp_copy_dir
        mov     si, dlgbuf
        call    bp_copy_name
        mov     si, packtarg
        call    open_lookup         ; helper from the target extension
        jnc     .cleanup
        mov     [vfs_helper], di
        mov     di, cmdbuf
        mov     si, [vfs_helper]
        call    vfs_cat
        mov     si, s_vfs_a
        call    vfs_cat
        mov     si, packtarg
        call    vfs_cat
        mov     si, s_vfs_atl
        call    vfs_cat
        mov     si, vfs_lpath
        call    vfs_cat
        mov     ax, di
        sub     ax, cmdbuf
        mov     [cmdlen], ax
        call    run_helper
        mov     word [cmdlen], 0
.cleanup:
        mov     ah, 41h             ; delete the scratch listfile
        mov     dx, vfs_lpath
        int     21h
        call    refresh_panels
.ret:
        ret

; append "<active P_PATH>\<E_NAME>\r\n" to pack_fh ; si = entry.
; Skips the . / .. pseudo-entries AND real directories (the packers take a flat
; file list, not a tree), counting each line actually written in pack_n.
pack_write_line:
        cmp     byte [si+E_NAME], '.'
        je      .ret
        test    byte [si+E_ATTR], 10h   ; directory? -> can't pack, skip
        jnz     .ret
        push    si
        mov     bx, [active]
        lea     si, [bx+P_PATH]
        mov     di, cmdbuf          ; scratch line (reused before the command)
        call    bp_copy_dir
        pop     si
        lea     si, [si+E_NAME]
        call    bp_copy_name        ; cmdbuf = path\name + NUL
        mov     di, cmdbuf
.fe:
        cmp     byte [di], 0
        je      .fd
        inc     di
        jmp     .fe
.fd:
        mov     byte [di], 0Dh
        mov     byte [di+1], 0Ah
        mov     cx, di
        sub     cx, cmdbuf
        add     cx, 2
        mov     bx, [pack_fh]
        mov     ah, 40h
        mov     dx, cmdbuf
        int     21h
        inc     word [pack_n]
.ret:
        ret

; copy ASCIIZ ds:si -> ds:di INCLUDING the NUL (di left at the NUL).
vfs_cpz:
        mov     al, [si]
        mov     [di], al
        or      al, al
        jz      .d
        inc     si
        inc     di
        jmp     vfs_cpz
.d:     ret

; append ASCIIZ ds:si -> ds:di WITHOUT the NUL (di advanced past last byte).
vfs_cat:
        mov     al, [si]
        or      al, al
        jz      .d
        mov     [di], al
        inc     si
        inc     di
        jmp     vfs_cat
.d:     ret

s_vfslst    db 'CCVFS.LST',0
s_vfs_l     db ' L ',0
s_vfs_redir db ' >',0
s_vfs_x     db ' X ',0
s_vfs_xa    db ' XA ',0
s_vfs_a     db ' A ',0
s_vfs_atl   db ' @',0
s_vfs_sp    db ' ',0
s_packto    db 'Pack tagged/cursor to archive:',0
s_packempty db 'No files to pack - tag files with Ins (dirs are skipped)',0
s_defzip    db 'ARCHIVE.ZIP',0
s_packlst   db 'CCPACK.LST',0
