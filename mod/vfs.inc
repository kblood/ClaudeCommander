; @feature VFS
; @title   browse archives (.zip/.d64/...) as folders
; @needs   INI
; @cost    2440
;
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
        mov     byte [bx+P_CPATH], 0    ; start at the archive root
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
        mov     word [vfs_fidx], 0  ; global file index (matches the helper's X order)
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

; si -> start of a "<decimal-size> <name>\r\n" line (one per FILE; the helper
; already skipped directory members). The member name may carry sub-folders as
; "a/b/c.txt". We show only the level given by the panel's P_CPATH prefix:
; members directly at this level become file entries (their global file index
; is stashed in E_TIME for F5 extraction); a member deeper than this level
; contributes its first sub-component as a synthetic directory entry (deduped).
; Every line advances vfs_fidx so the stored index matches the helper's X order.
; Leaves si at the line's CR/LF/NUL terminator.
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
        mov     [vfs_lsize], ax
        mov     [vfs_lsize+2], dx
.sp:
        cmp     byte [si], ' '
        jne     .pfx
        inc     si
        jmp     .sp
.pfx:
        ; match the panel's P_CPATH prefix against the member name
        mov     bx, [vfs_pan]
        lea     di, [bx+P_CPATH]
.pl:
        mov     ah, [di]            ; prefix char
        or      ah, ah
        jz      .matched            ; whole prefix consumed -> at our level
        mov     al, [si]            ; name char
        or      al, al
        jz      .endline            ; name shorter than prefix -> not here
        cmp     al, 0Dh
        je      .endline
        cmp     al, 0Ah
        je      .endline
        call    vfs_norm_al         ; al -> upper, '\'->'/'
        xchg    al, ah              ; normalize prefix char too
        call    vfs_norm_al
        xchg    al, ah              ; al=name(norm), ah=prefix(norm)
        cmp     al, ah
        jne     .endline
        inc     si
        inc     di
        jmp     .pl
.matched:
        ; si = remainder start. Scan to the line terminator, remembering the
        ; first '/' or '\' (the sub-folder boundary). The add helpers clobber si
        ; via entry_ptr, so stash the resume cursor first and restore it after.
        mov     bx, si              ; bx = remainder start
        xor     dx, dx              ; dx = first separator pos (0 = none)
.scan:
        mov     al, [si]
        or      al, al
        jz      .scend
        cmp     al, 0Dh
        je      .scend
        cmp     al, 0Ah
        je      .scend
        cmp     al, '/'
        je      .sep
        cmp     al, '\'
        je      .sep
        inc     si
        jmp     .scan
.sep:
        or      dx, dx
        jnz     .sepskip            ; only the FIRST separator marks the level
        mov     dx, si
.sepskip:
        inc     si
        jmp     .scan
.scend:
        mov     [vfs_rcur], si      ; resume cursor = the line terminator
        or      dx, dx
        jz      .mkfile
        ; deeper member -> first component is a sub-folder
        mov     si, dx              ; vfs_copy_comp copies [bx..si) = component
        call    vfs_copy_comp
        call    vfs_add_dir
        jmp     .et
.mkfile:
        mov     si, [vfs_rcur]      ; file at this level: name = [bx..terminator)
        call    vfs_copy_comp
        call    vfs_add_file
        jmp     .et
.endline:
        ; (prefix mismatch) advance the still-valid listing cursor to the
        ; terminator so the caller resumes on the next line.
        mov     al, [si]
        or      al, al
        jz      .et2
        cmp     al, 0Dh
        je      .et2
        cmp     al, 0Ah
        je      .et2
        inc     si
        jmp     .endline
.et2:
        inc     word [vfs_fidx]
        ret
.et:
        mov     si, [vfs_rcur]      ; restore the listing cursor (helpers used si)
        inc     word [vfs_fidx]
        ret

; al -> uppercase, with '\' mapped to '/'.
vfs_norm_al:
        cmp     al, '\'
        jne     .nb
        mov     al, '/'
        ret
.nb:
        cmp     al, 'a'
        jb      .d
        cmp     al, 'z'
        ja      .d
        sub     al, 20h
.d:     ret

; copy [bx..si) into vfs_comp, truncated to 13 chars, NUL-terminated. si/bx kept.
vfs_copy_comp:
        push    si
        push    bx
        mov     di, vfs_comp
        mov     cx, 13
.cp:
        cmp     bx, si
        jae     .d
        jcxz    .d
        mov     al, [bx]
        mov     [di], al
        inc     bx
        inc     di
        dec     cx
        jmp     .cp
.d:
        mov     byte [di], 0
        pop     bx
        pop     si
        ret

; Add a synthetic sub-directory entry named vfs_comp, unless one already exists
; at this level (members of the same sub-folder share the first component).
vfs_add_dir:
        mov     cx, [_count]
        mov     dx, 1               ; entry 0 is ".."
.dl:
        cmp     dx, cx
        jae     .add
        push    cx
        push    dx
        mov     ax, dx
        call    entry_ptr           ; si = entry (ppanel = vfs_pan)
        test    byte [si+E_ATTR], 10h
        jz      .next
        lea     di, [si+E_NAME]
        mov     si, vfs_comp
        call    streqi              ; CF=1 if equal (ci); si/di preserved
        jc      .dup
.next:
        pop     dx
        pop     cx
        inc     dx
        jmp     .dl
.dup:
        pop     dx
        pop     cx
        ret
.add:
        mov     cx, [_count]
        cmp     cx, MAX_FILES
        jae     .ret
        mov     ax, cx
        call    entry_ptr
        mov     byte [si+E_ATTR], 10h
        mov     word [si+E_SIZE], 0
        mov     word [si+E_SIZE+2], 0
        mov     word [si+E_TIME], 0
        lea     di, [si+E_NAME]
        mov     si, vfs_comp
        call    vfs_cpz
        inc     word [_count]
.ret:
        ret

; Add a file entry named vfs_comp with vfs_lsize as its size and vfs_fidx as the
; stashed global file index (used by F5 extract).
vfs_add_file:
        mov     cx, [_count]
        cmp     cx, MAX_FILES
        jae     .ret
        mov     ax, cx
        call    entry_ptr
        mov     ax, [vfs_lsize]
        mov     [si+E_SIZE], ax
        mov     ax, [vfs_lsize+2]
        mov     [si+E_SIZE+2], ax
        mov     byte [si+E_ATTR], 20h
        mov     ax, [vfs_fidx]
        mov     [si+E_TIME], ax
        lea     di, [si+E_NAME]
        mov     si, vfs_comp
        call    vfs_cpz
        inc     word [_count]
.ret:
        ret

; Enter on a synthetic sub-folder (si = cursor entry): append "<name>/" to the
; active panel's internal archive path, then relist at the new level.
vfs_descend:
        mov     bx, [active]
        lea     di, [bx+P_CPATH]
.fin:
        cmp     byte [di], 0
        je      .at
        inc     di
        jmp     .fin
.at:
        ; guard against overflowing the 64-byte P_CPATH buffer
        mov     ax, di
        sub     ax, bx
        sub     ax, P_CPATH
        cmp     ax, 48
        jae     .ret                ; too deep -> ignore (rare)
        lea     si, [si+E_NAME]
.cp:
        mov     al, [si]
        or      al, al
        jz      .done
        mov     [di], al
        inc     si
        inc     di
        jmp     .cp
.done:
        mov     byte [di], '/'
        inc     di
        mov     byte [di], 0
        mov     bx, [active]
        call    vfs_relist
.ret:
        ret

; ".." inside a container: drop the last component of P_CPATH and relist. If
; already at the archive root (P_CPATH empty), leave the container entirely.
vfs_go_up:
        mov     bx, [active]
        lea     di, [bx+P_CPATH]
        cmp     byte [di], 0
        jne     .pop
        jmp     go_parent           ; at root -> clear P_VFS, re-read real dir
.pop:
        mov     si, di              ; find the NUL
.fe:
        cmp     byte [si], 0
        je      .fnd
        inc     si
        jmp     .fe
.fnd:
        dec     si                  ; -> trailing '/'
.bk:
        cmp     si, di
        jbe     .root
        dec     si
        cmp     byte [si], '/'
        jne     .bk
        mov     byte [si+1], 0      ; keep up to and including the previous '/'
        jmp     .relist
.root:
        mov     byte [di], 0
.relist:
        mov     bx, [active]
        call    vfs_relist
        ret

; F5 on a container panel: extract the cursor member into the OTHER panel's
; directory via "<helper> X <container> <member-index> <destdir>". The member
; index matches the L listing (entry 0 is the synthetic ".."), so it is the
; cursor index minus one.
vfs_extract:
        mov     bx, [active]
        call    cur_entry_ptr       ; si = cursor entry
        test    byte [si+E_ATTR], 10h
        jnz     .ret                ; ".." or a sub-folder -> nothing to extract
        mov     ax, [si+E_TIME]     ; stashed global file index (matches helper X)
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

; F3 on a container panel: VIEW the cursor member in place, WITHOUT extracting,
; via "<viewhelper> <container> <member-index>". The viewer reads the member
; straight from the archive by its TOC index (CCGB does this for .DAX images).
; The member's own extension selects the [view] helper, exactly like F3 on a
; real file -- only the argument is "<container> <index>", not a standalone path.
vfs_view:
        mov     bx, [active]
        call    cur_entry_ptr           ; si = cursor entry
        test    byte [si+E_ATTR], 10h
        jnz     .ret                    ; ".." / sub-folder -> nothing to view
        mov     ax, [si+E_TIME]         ; stashed 0-based member index (matches X/L)
        mov     [vfs_idx], ax
        mov     [vfs_pan], bx
        ; view helper for THIS MEMBER's extension (e.g. .GBI -> CCGB)
        lea     si, [si+E_NAME]
        call    view_lookup             ; CF=1 -> di = helper; si preserved
        jnc     .ret                    ; unmapped member type -> nothing to do
        mov     [vfs_helper], di
        ; vfs_cpath = P_PATH + '\' + P_CNAME  (the container's full path)
        mov     bx, [vfs_pan]
        lea     si, [bx+P_PATH]
        mov     di, vfs_cpath
        call    bp_copy_dir
        mov     bx, [vfs_pan]
        lea     si, [bx+P_CNAME]
        call    bp_copy_name
        ; cmdbuf = helper + " " + vfs_cpath + " " + idx
        mov     di, cmdbuf
        mov     si, [vfs_helper]
        call    vfs_cat
        mov     si, s_vfs_sp
        call    vfs_cat
        mov     si, vfs_cpath
        call    vfs_cat
        mov     si, s_vfs_sp
        call    vfs_cat
        mov     ax, [vfs_idx]
        call    vfs_putdec
        mov     ax, di
        sub     ax, cmdbuf
        mov     [cmdlen], ax
        call    run_command             ; viewer owns the screen; then redraw
.ret:
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
        ; pass the active dir as the pack-root so members are stored relative to
        ; it (a packed sub-folder keeps its structure; flat files stay flat)
        mov     si, s_vfs_sp
        call    vfs_cat
        mov     bx, [active]
        lea     si, [bx+P_PATH]
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

; F5 when the OTHER panel is inside a container: add the active panel's
; tagged entries (or the cursor), files and folders recursively, INTO that
; archive. Builds CCPACK.LST exactly like key_pack, then runs
; "<helper> AP <archive> @<list> <root>" so the helper appends the members and
; rewrites the central directory. Afterwards the container panel is relisted so
; the new members appear. No name prompt -- the target archive is already open.
vfs_addto:
        ; build the file list in the active panel's dir (reuses vfs_lpath)
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
        call    count_tagged
        or      cx, cx
        jz      .single
        mov     word [iter_i], 0
.tl:
        mov     bx, [active]
        mov     ax, [iter_i]
        cmp     ax, [bx+P_COUNT]
        jae     .wdone
        mov     [ppanel], bx
        call    entry_ptr
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
        cmp     word [pack_n], 0
        jne     .havefiles
        mov     si, s_packempty
        call    dlg_confirm
        mov     ah, 41h
        mov     dx, vfs_lpath
        int     21h
        call    refresh_panels
        ret
.havefiles:
        ; target archive = other panel's P_PATH\P_CNAME
        call    other_panel_ptr
        mov     [vfs_pan], bx           ; remember it so we can relist after
        lea     si, [bx+P_PATH]
        mov     di, packtarg
        call    bp_copy_dir
        mov     bx, [vfs_pan]
        lea     si, [bx+P_CNAME]
        call    bp_copy_name            ; packtarg = full archive path
        mov     bx, [vfs_pan]
        lea     si, [bx+P_CNAME]
        call    open_lookup             ; helper from the archive's extension
        jnc     .done
        mov     [vfs_helper], di
        mov     di, cmdbuf
        mov     si, [vfs_helper]
        call    vfs_cat
        mov     si, s_vfs_ap
        call    vfs_cat
        mov     si, packtarg
        call    vfs_cat
        mov     si, s_vfs_atl
        call    vfs_cat
        mov     si, vfs_lpath
        call    vfs_cat
        ; pass the active dir as the pack-root (relative stored names)
        mov     si, s_vfs_sp
        call    vfs_cat
        mov     bx, [active]
        lea     si, [bx+P_PATH]
        call    vfs_cat
        mov     ax, di
        sub     ax, cmdbuf
        mov     [cmdlen], ax
        call    run_helper
        mov     word [cmdlen], 0
        ; delete the scratch list BEFORE relisting (vfs_relist reuses vfs_lpath)
        mov     ah, 41h
        mov     dx, vfs_lpath
        int     21h
        mov     bx, [vfs_pan]
        call    vfs_relist              ; rebuild the listing -> new members show
        call    refresh_panels
        ret
.done:
        mov     ah, 41h
        mov     dx, vfs_lpath
        int     21h
        call    refresh_panels
.ret:
        ret

; Add one selected entry (si) to the pack list. Skips . / .. ; a plain file is
; written as one line; a directory is walked recursively (pack_tree) so the
; whole tree is packed (the packer stores paths relative to the active dir).
pack_write_line:
        cmp     byte [si+E_NAME], '.'
        je      .ret
        ; rsrc = active P_PATH \ E_NAME  (full path of the entry)
        push    si
        mov     bx, [active]
        lea     si, [bx+P_PATH]
        mov     di, rsrc
        call    bp_copy_dir
        pop     si
        push    si
        lea     si, [si+E_NAME]
        call    bp_copy_name        ; rsrc = full path + NUL
        pop     si
        test    byte [si+E_ATTR], 10h
        jz      .file
        mov     word [rdepth], 0    ; directory -> recurse
        call    pack_tree
        ret
.file:
        mov     si, rsrc
        call    pack_emit
.ret:
        ret

; Walk the directory whose ASCIIZ path is in rsrc, writing every file within
; (recursively) to the pack list. Uses the shared rdepth/dta_stack walker.
pack_tree:
        mov     ax, [rdepth]
        cmp     ax, MAX_DEPTH
        jae     .ret
        call    set_dta_cur
        call    make_findpat        ; findpat = rsrc + "\*.*"
        mov     ah, 4Eh
        mov     cx, 37h
        mov     dx, findpat
        int     21h
        jc      .ret
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
        call    bp_copy_name        ; rsrc = child full path
        call    cur_dta_ptr
        test    byte [bx+15h], 10h
        jz      .file
        inc     word [rdepth]       ; subdirectory -> recurse
        call    pack_tree
        dec     word [rdepth]
        jmp     .after
.file:
        mov     si, rsrc
        call    pack_emit
.after:
        pop     di
        mov     byte [di], 0        ; truncate rsrc back
.next:
        call    set_dta_cur         ; recursion changed the DTA -> restore ours
        mov     ah, 4Fh
        int     21h
        jnc     .loop
.ret:
        ret

; Append "<ASCIIZ path in si>\r\n" to pack_fh, counting it in pack_n.
pack_emit:
        push    si
        mov     di, cmdbuf
.cp:
        mov     al, [si]
        or      al, al
        jz      .ce
        mov     [di], al
        inc     si
        inc     di
        jmp     .cp
.ce:
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
        pop     si
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
s_vfs_ap    db ' AP ',0
s_vfs_atl   db ' @',0
s_vfs_sp    db ' ',0
s_packto    db 'Pack tagged/cursor to archive:',0
s_packempty db 'No files to pack - tag files or folders with Ins',0
s_defzip    db 'ARCHIVE.ZIP',0
s_packlst   db 'CCPACK.LST',0
