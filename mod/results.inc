; @feature RESULTS
; @title   Alt-F7 find -> in-panel results list (Enter jumps to the file)
; @needs   FIND
; @cost    4700
; @optin   not in the default STD set (its ~4 KB heap will not fit there);
;          select it explicitly: configure.ps1 -Base std -Remove VFS -Add RESULTS
;
; mod/results.inc  --  FEAT_RESULTS
; Turns Alt-F7 (find) from a screen-takeover into an in-cc panel: CCFIND's output
; is redirected to FINDOUT.TXT, parsed into the inactive panel as a third panel
; SOURCE (P_SRC = SRC_RESULT), and Enter on a row jumps the panel to that file's
; folder with the cursor on it. The full path of each row lives in res_heap; the
; entry carries only the basename (E_NAME) + a near offset into res_heap
; (E_RES_OFF, aliased over E_TIME -- see the hazard note at the struct defs).
;
; All three entry points are reached only when the active/target panel is a
; results panel (key_find builds it; key_enter/go_parent/read_dir fork on
; P_SRC==SRC_RESULT), so the E_TIME/E_DATE alias reuse is fenced.

; results_show: called by key_find after CCFIND wrote FINDOUT.TXT. Turn the
; INACTIVE panel into a results list of what we just searched, then focus it.
results_show:
        call    other_panel_ptr         ; bx = the panel that is NOT active
        mov     [rl_panel], bx
        ; copy the searched dir (active P_PATH) into the results panel's P_PATH
        ; so its title shows where the matches came from
        mov     si, [active]
        add     si, P_PATH
        mov     di, [rl_panel]
        add     di, P_PATH
        mov     cx, 68
        rep     movsb
        mov     bx, [rl_panel]
        mov     byte [bx+P_SRC], SRC_RESULT
        call    results_load            ; bx = panel -> fill entries from FINDOUT.TXT
        mov     bx, [rl_panel]
        mov     [active], bx            ; focus the results
        ret

; results_load: bx = the results panel. Parse FINDOUT.TXT (full path per line,
; CRLF) into entries + res_heap. Truncates with a single status row.
results_load:
        mov     [ppanel], bx
        mov     word [bx+P_COUNT], 0
        mov     word [bx+P_TOP], 0
        mov     word [bx+P_CUR], 0
        mov     dx, s_findout
        mov     ax, 3D00h               ; open for read
        int     21h
        jc      .done                   ; no file -> empty results
        mov     bx, ax                  ; handle
        mov     ah, 3Fh
        mov     cx, VIEW_MAX
        mov     dx, viewbuf             ; use the F3 viewbuf only for this parse
        int     21h                     ; ax = bytes read
        push    ax
        mov     ah, 3Eh
        int     21h                     ; close (bx = handle)
        pop     ax
        mov     [rl_end], ax
        mov     si, viewbuf
        mov     di, res_heap
.line:
        mov     ax, si
        sub     ax, viewbuf
        cmp     ax, [rl_end]
        jae     .done
        mov     al, [si]
        cmp     al, 0Dh
        je      .skipc
        cmp     al, 0Ah
        je      .skipc
        mov     bx, [ppanel]
        mov     ax, [bx+P_COUNT]
        cmp     ax, MAX_FILES-1         ; leave one slot for a status row
        jae     .trunc
        mov     [rl_path], di
.copy:
        mov     ax, si
        sub     ax, viewbuf
        cmp     ax, [rl_end]
        jae     .eol
        mov     ax, di                  ; heap bound check BEFORE loading the char
        sub     ax, res_heap            ; (this clobbers al, so do it first)
        cmp     ax, RESHEAP_MAX-2       ; room for this char + NUL?
        jae     .trunc
        mov     al, [si]
        cmp     al, 0Dh
        je      .eol
        cmp     al, 0Ah
        je      .eol
        mov     [di], al
        inc     si
        inc     di
        jmp     .copy
.eol:
        mov     byte [di], 0
        inc     di
        mov     ax, di
        dec     ax
        cmp     ax, [rl_path]           ; empty line -> no entry
        je      .line
        push    si
        push    di
        mov     bx, [ppanel]
        mov     ax, [bx+P_COUNT]
        call    entry_ptr               ; si = &entry[count]
        ; basename = chars after the last '\' in rl_path
        mov     bp, [rl_path]
        mov     dx, bp
.bn:
        mov     al, [bp]
        or      al, al
        jz      .bndone
        inc     bp
        cmp     al, '\'
        jne     .bn
        mov     dx, bp
        jmp     .bn
.bndone:
        mov     bp, dx
        lea     di, [si+E_NAME]
        mov     cx, 12
.nc:
        mov     al, [bp]
        or      al, al
        jz      .nce
        mov     [di], al
        inc     bp
        inc     di
        loop    .nc
.nce:
        mov     byte [di], 0
        mov     byte [si+E_ATTR], 20h        ; archive bit -> renders as a file
        mov     word [si+E_SIZE], 0          ; size 0 keeps sort/columns harmless
        mov     word [si+E_SIZE+2], 0
        mov     ax, [rl_path]
        mov     [si+E_RES_OFF], ax           ; (= E_TIME) path ptr
        mov     word [si+E_RES_LINE], 0      ; (= E_DATE) line (W2 grep)
        mov     bx, [ppanel]
        inc     word [bx+P_COUNT]
        pop     di
        pop     si
        jmp     .line
.skipc:
        inc     si
        jmp     .line
.trunc:
        mov     bx, [ppanel]
        mov     ax, [bx+P_COUNT]
        cmp     ax, MAX_FILES
        jae     .done
        call    entry_ptr               ; si = &entry[count]
        mov     bp, s_resmore
        lea     di, [si+E_NAME]
.tc:
        mov     al, [bp]
        or      al, al
        jz      .tce
        mov     [di], al
        inc     bp
        inc     di
        jmp     .tc
.tce:
        mov     byte [di], 0
        mov     byte [si+E_ATTR], E_ATTR_STATUS
        mov     word [si+E_RES_OFF], 0FFFFh
        mov     bx, [ppanel]
        inc     word [bx+P_COUNT]
.done:
        ret

; results_enter: Enter on the active results panel. Inert on the status row;
; otherwise turn the panel into a real listing of the file's folder and land the
; cursor on the file.
results_enter:
        mov     bx, [active]
        call    cur_entry_ptr           ; si = entry, ppanel = bx
        test    byte [si+E_ATTR], E_ATTR_STATUS
        jnz     .ret
        mov     si, [si+E_RES_OFF]      ; si = full path in res_heap
        ; copy the full path into the active panel's P_PATH (cap 67 + NUL)
        mov     bx, [active]
        lea     di, [bx+P_PATH]
        mov     cx, 67
.cp:
        mov     al, [si]
        or      al, al
        jz      .cpe
        mov     [di], al
        inc     si
        inc     di
        loop    .cp
.cpe:
        mov     byte [di], 0
        ; find the last '\' in P_PATH
        mov     bx, [active]
        lea     di, [bx+P_PATH]
        xor     dx, dx                  ; dx = ptr to last '\', 0 = none
.fb:
        mov     al, [di]
        or      al, al
        jz      .fbe
        cmp     al, '\'
        jne     .fbn
        mov     dx, di
.fbn:
        inc     di
        jmp     .fb
.fbe:
        or      dx, dx
        jz      .relist                 ; no '\' (degenerate) -> just list as-is
        ; basename (dx+1) -> rl_namebuf
        mov     si, dx
        inc     si
        mov     di, rl_namebuf
.bc:
        mov     al, [si]
        mov     [di], al
        inc     si
        inc     di
        or      al, al
        jnz     .bc
        ; split: keep "X:\" at a root, else drop the trailing '\'
        mov     bx, dx                  ; bx -> the last '\'
        cmp     byte [bx-1], ':'        ; char before it ':' -> it's a root "X:\"
        je      .root
        mov     byte [bx], 0            ; drop the trailing '\'
        jmp     .relist
.root:
        mov     byte [bx+1], 0         ; keep "X:\"
.relist:
        mov     bx, [active]
        mov     byte [bx+P_SRC], SRC_DIR
        call    read_dir                ; list the folder for real
        ; find rl_namebuf among the entries -> P_CUR
        mov     bx, [active]
        mov     cx, [bx+P_COUNT]
        jcxz    .ret
        xor     bp, bp                  ; bp = index
.scan:
        mov     bx, [active]
        mov     [ppanel], bx
        mov     ax, bp
        call    entry_ptr               ; si = &entry[bp]
        lea     di, [si+E_NAME]
        mov     si, rl_namebuf
.ce:
        mov     al, [si]
        mov     ah, [di]
        cmp     al, ah
        jne     .nomatch
        or      al, al
        jz      .match
        inc     si
        inc     di
        jmp     .ce
.nomatch:
        inc     bp
        mov     bx, [active]
        cmp     bp, [bx+P_COUNT]
        jb      .scan
        ret                             ; not found -> leave cursor at 0
.match:
        mov     bx, [active]
        mov     [bx+P_CUR], bp
        call    fix_scroll              ; bx = panel -> adjust P_TOP
.ret:
        ret

s_findout   db 'FINDOUT.TXT',0
s_resmore   db '...(more)',0           ; non-selectable status row (<=12 chars)
s_findredir db ' >FINDOUT.TXT',0
