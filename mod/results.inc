; @feature RESULTS
; @title   Alt-F7 find / Alt-F8 grep -> in-panel results list (Enter jumps)
; @needs   FIND
; @cost    4200
; @note    Now IN the default STD set. Its path heap was trimmed to 3 KB and the
;          F3 pager cap (VIEW_MAX) to 8 KB so it fits alongside FEAT_VFS under the
;          63 KB wall (resident 63,030 B). It coexists with the zip browser --
;          both are just non-SRC_DIR panel sources.
;
; mod/results.inc  --  FEAT_RESULTS
; Turns Alt-F7 (find) and Alt-F8 (grep, when FEAT_GREP is built) from screen
; takeovers into an in-cc panel. CCFIND/CCGREP output is redirected to a temp
; file, parsed into the inactive panel as a third panel SOURCE (P_SRC =
; SRC_RESULT), and Enter on a row acts on it:
;   * find row      -> jump the panel to that file's folder, cursor on it.
;   * grep file row -> open the F3 built-in viewer on the file at the first match.
; Grep lists ONE row per matching FILE (not per match line): CCGREP groups its
; matches per file, so consecutive output lines for the same path are collapsed
; into a single entry that records the first match's line number.
; The full path of each row lives in res_heap; the entry carries the basename
; (E_NAME, used for the jump and the viewer header), a near offset to the path
; (E_RES_OFF = E_TIME), and a line number (E_RES_LINE = E_DATE) which is 0 for a
; find row and >0 for a grep file row -- that is the find-vs-grep discriminator.
;
; All entry points are reached only when the active/target panel is a results
; panel (key_find/key_grep build it; key_enter/go_parent/read_dir fork on
; P_SRC==SRC_RESULT), so the E_SIZE/E_TIME/E_DATE alias reuse is fenced.

; results_show: called by key_find after CCFIND wrote FINDOUT.TXT.
results_show:
        mov     byte [rl_grep], 0
        mov     word [rl_fname], s_findout
        jmp     results_show_common
%ifdef FEAT_GREP
; results_show_grep: called by key_grep after CCGREP wrote GREPOUT.TXT.
results_show_grep:
        mov     byte [rl_grep], 1
        mov     word [rl_fname], s_grepout
        ; fall through
%endif
results_show_common:
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
        call    results_load            ; bx = panel -> fill entries from the temp file
        mov     bx, [rl_panel]
        ; cursor on the first real match (entry 1), not the ".." leave row, unless
        ; there were no matches (count 1 = just "..") -> stay on "..".
        cmp     word [bx+P_COUNT], 1
        jbe     .nocur
        mov     word [bx+P_CUR], 1
.nocur:
        mov     [active], bx            ; focus the results
        ret

; Enter on the ".." row (or Esc on a results panel): leave the virtual results
; list and re-list the real searched folder. go_parent reads [active] itself.
results_leave:
        jmp     go_parent

; ===========================================================================
;  DRIVES VIEW -- Alt-F1/F2 show every available drive in a panel, reusing the
;  SRC_RESULT virtual panel: each existing drive is a row that opens its root on
;  Enter, and ".." / Esc leaves back to the folder you were in (P_PATH is kept).
;  Existence is probed with IOCTL 4409h, which does NOT touch the media, so an
;  empty floppy still lists without a "drive not ready" prompt.
; ===========================================================================
; bx = the panel to fill with the drive list (and focus).
drives_show:
        mov     [active], bx
        mov     byte [bx+P_SRC], SRC_RESULT
        call    drives_load
        mov     bx, [active]
        cmp     word [bx+P_COUNT], 1
        jbe     .nc
        mov     word [bx+P_CUR], 1      ; start on the first drive, not ".."
.nc:
        ret

; bx = panel -> fill entries with a ".." row + one row per existing drive. Each
; drive row carries the dir bit (renders "<DIR>") and a heap "X:\" path; Enter
; runs the find-style jump (E_RES_LINE = 0) which lists that drive's root.
drives_load:
        mov     [ppanel], bx
        mov     word [bx+P_COUNT], 0
        mov     word [bx+P_TOP], 0
        mov     word [bx+P_CUR], 0
        ; ".." leave row
        xor     ax, ax
        call    entry_ptr               ; si = &entry[0]  (preserves bx)
        mov     word [si+E_NAME], '..'
        mov     byte [si+E_NAME+2], 0
        mov     byte [si+E_ATTR], 10h
        mov     word [si+E_RES_LINE], 0
        inc     word [bx+P_COUNT]
        mov     di, res_heap            ; pack the "X:\" paths here
        mov     byte [drv_cur], 1       ; 1 = A:
.next:
        cmp     byte [drv_cur], 26
        ja      .done
        mov     bl, [drv_cur]
        mov     ax, 4409h               ; IOCTL: block device remote? (no media I/O)
        int     21h
        jc      .skip                   ; CF=1 -> invalid / absent drive
        mov     bx, [ppanel]
        mov     ax, [bx+P_COUNT]
        cmp     ax, MAX_FILES-1
        jae     .done
        call    entry_ptr               ; si = &entry[count]; di preserved
        mov     al, [drv_cur]
        add     al, 'A'-1
        mov     [si+E_NAME], al
        mov     byte [si+E_NAME+1], ':'
        mov     byte [si+E_NAME+2], 0
        mov     byte [si+E_ATTR], 10h   ; "<DIR>" -- openable like a folder
        mov     [si+E_RES_OFF], di      ; -> "X:\" path in the heap
        mov     word [si+E_RES_LINE], 0 ; line 0 -> Enter does the find-style jump
        mov     al, [drv_cur]
        add     al, 'A'-1
        mov     [di], al                ; "X"
        inc     di
        mov     byte [di], ':'
        inc     di
        mov     byte [di], '\'
        inc     di
        mov     byte [di], 0
        inc     di
        mov     bx, [ppanel]
        inc     word [bx+P_COUNT]
.skip:
        inc     byte [drv_cur]
        jmp     .next
.done:
        ret

; results_load: bx = the results panel. Parse [rl_fname] (find: "<path>\r\n";
; grep: "<path>:<line>:<text>\r\n") into entries + res_heap. Truncates with a
; single status row when entries or heap fill.
results_load:
        mov     [ppanel], bx
        mov     word [bx+P_COUNT], 0
        mov     word [bx+P_TOP], 0
        mov     word [bx+P_CUR], 0
        ; entry[0] = ".." synthetic row. Enter on it (or Esc) leaves the results
        ; panel back to the searched folder -- exactly like the zip browser's "..".
        ; It carries the dir bit (renders "<UP>") so results_enter can tell it
        ; from a match row (which carries 20h) without a name compare.
        mov     ax, 0
        call    entry_ptr               ; si = &entry[0]  (preserves bx = ppanel)
        mov     word [si+E_NAME], '..'
        mov     byte [si+E_NAME+2], 0
        mov     byte [si+E_ATTR], 10h   ; dir bit -> "<UP>", and the leave marker
        mov     word [si+E_RES_TEXT], 0 ; not a grep row
        inc     word [bx+P_COUNT]
        mov     dx, [rl_fname]
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
        mov     word [rl_lastpath], 0   ; no file emitted yet (grep dedup)
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
%ifdef FEAT_GREP
        cmp     byte [rl_grep], 0
        jne     .grep
%endif
        ; ---- find row: the whole line is a full path --------------------------
.find:
        mov     [rl_path], di
.fcopy:
        mov     ax, si
        sub     ax, viewbuf
        cmp     ax, [rl_end]
        jae     .feol
        mov     al, [si]
        cmp     al, 0Dh
        je      .feol
        cmp     al, 0Ah
        je      .feol
        call    heap_putc
        jc      .trunc
        inc     si
        jmp     .fcopy
.feol:
        mov     byte [di], 0            ; NUL-terminate the path
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
        call    results_set_name        ; E_NAME = basename(rl_path)
        mov     byte [si+E_ATTR], 20h        ; archive bit -> renders as a file
        mov     word [si+E_SIZE], 0          ; E_RES_TEXT=0 -> find row; size 0
        mov     word [si+E_SIZE+2], 0
        mov     ax, [rl_path]
        mov     [si+E_RES_OFF], ax           ; (= E_TIME) path ptr
        mov     word [si+E_RES_LINE], 0      ; (= E_DATE) no line for find
        mov     bx, [ppanel]
        inc     word [bx+P_COUNT]
        pop     di
        pop     si
        jmp     .line
%ifdef FEAT_GREP
        ; ---- grep row: "<path>:<line>:<text>" --------------------------------
.grep:
        mov     [rl_path], di
        xor     bx, bx                  ; colon counter (the drive ':' is #1)
.gpath:
        mov     ax, si
        sub     ax, viewbuf
        cmp     ax, [rl_end]
        jae     .gmal                   ; EOL before a 2nd colon -> malformed
        mov     al, [si]
        cmp     al, 0Dh
        je      .gmal
        cmp     al, 0Ah
        je      .gmal
        cmp     al, ':'
        jne     .gpstore
        inc     bx
        cmp     bx, 2
        jb      .gpstore                ; first colon = drive -> keep it in the path
        inc     si                      ; second colon = path/line separator: consume
        jmp     .gpend
.gpstore:
        call    heap_putc
        jc      .trunc
        inc     si
        jmp     .gpath
.gmal:
        ; no 2nd colon: treat the whole line as a find-style path row
        mov     byte [di], 0
        inc     di
        mov     ax, di
        dec     ax
        cmp     ax, [rl_path]
        je      .line
        push    si
        push    di
        mov     bx, [ppanel]
        mov     ax, [bx+P_COUNT]
        call    entry_ptr
        call    results_set_name
        mov     byte [si+E_ATTR], 20h
        mov     word [si+E_SIZE], 0     ; E_RES_TEXT=0 -> behaves as a find row
        mov     word [si+E_SIZE+2], 0
        mov     ax, [rl_path]
        mov     [si+E_RES_OFF], ax
        mov     word [si+E_RES_LINE], 0
        mov     bx, [ppanel]
        inc     word [bx+P_COUNT]
        pop     di
        pop     si
        jmp     .line                   ; si at CR/LF/EOL -> .line handles it
.gpend:
        mov     byte [di], 0            ; NUL-terminate path
        inc     di
        ; parse the decimal line number into cx
        xor     cx, cx
.gnum:
        mov     ax, si
        sub     ax, viewbuf
        cmp     ax, [rl_end]
        jae     .gnumdone
        mov     al, [si]
        cmp     al, '0'
        jb      .gnumdone
        cmp     al, '9'
        ja      .gnumdone
        push    ax
        mov     ax, cx
        mov     dx, 10
        mul     dx                      ; ax = cx*10 (overflow into dx ignored)
        mov     cx, ax
        pop     ax
        sub     al, '0'
        mov     ah, 0
        add     cx, ax
        inc     si
        jmp     .gnum
.gnumdone:
        mov     [rl_line], cx
        ; skip the rest of the line (the matched text) to EOL. We list one row per
        ; FILE, not per match -- the text is shown later by opening the file in the
        ; viewer at this line -- so it is not stored in the heap.
.gtskip:
        mov     ax, si
        sub     ax, viewbuf
        cmp     ax, [rl_end]
        jae     .gemit
        mov     al, [si]
        cmp     al, 0Dh
        je      .gemit
        cmp     al, 0Ah
        je      .gemit
        inc     si
        jmp     .gtskip
.gemit:
        ; dedup: CCGREP emits all matches for a file consecutively, so if this
        ; path equals the one we last emitted it's the same file -> drop it (the
        ; first match's line is already recorded) and reclaim its heap bytes.
        mov     bx, [rl_lastpath]
        or      bx, bx
        jz      .gnew
        mov     bp, [rl_path]
.gcmp:
        mov     al, [bp]
        cmp     al, [bx]
        jne     .gnew
        or      al, al
        jz      .gdup
        inc     bp
        inc     bx
        jmp     .gcmp
.gdup:
        mov     di, [rl_path]           ; roll the heap cursor back over the dup path
        jmp     .line
.gnew:
        mov     ax, [rl_path]
        mov     [rl_lastpath], ax       ; remember this file for the next dedup
        mov     bx, [ppanel]
        mov     ax, [bx+P_COUNT]
        cmp     ax, MAX_FILES-1
        jae     .trunc
        push    si
        push    di
        call    entry_ptr               ; si = &entry[count]
        call    results_set_name        ; E_NAME = basename(rl_path)
        mov     byte [si+E_ATTR], 20h
        mov     ax, [rl_line]
        mov     word [si+E_SIZE], ax         ; show the first match's line in the size col
        mov     word [si+E_SIZE+2], 0
        mov     ax, [rl_path]
        mov     [si+E_RES_OFF], ax           ; (= E_TIME) path ptr
        mov     ax, [rl_line]
        mov     [si+E_RES_LINE], ax          ; (= E_DATE) line>0 -> grep file row -> viewer
        mov     bx, [ppanel]
        inc     word [bx+P_COUNT]
        pop     di
        pop     si
        jmp     .line                   ; si at CR/LF/EOL -> .line handles it
%endif
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
        mov     word [si+E_RES_TEXT], 0      ; not a grep row (status renders E_NAME)
        mov     word [si+E_RES_OFF], 0FFFFh
        mov     bx, [ppanel]
        inc     word [bx+P_COUNT]
.done:
        ret

; store AL into res_heap at di with a bound check. CF=1 (di unchanged) if full.
; Preserves bx (callers use it for the colon counter / panel ptr).
heap_putc:
        push    ax
        mov     ax, di
        sub     ax, res_heap
        cmp     ax, RESHEAP_MAX-4       ; reserve room for two NUL terminators
        pop     ax
        jae     .full
        mov     [di], al
        inc     di
        clc
        ret
.full:
        stc
        ret

; si = entry ptr; copy basename of [rl_path] into E_NAME (<=12 chars). si preserved.
results_set_name:
        push    si
        mov     bp, [rl_path]
        mov     dx, bp                  ; dx = start of basename
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
        pop     si
        ret

; results_view_at_line: si = grep entry. Open the F3 built-in viewer on the
; file (E_RES_OFF), scrolled to E_RES_LINE. Find rows have E_RES_LINE=0 -> top.
; The built-in pager (view_open_builtin) is core, so this needs no FEAT_VIEW.
results_view_at_line:
        mov     ax, [si+E_RES_LINE]
        mov     [view_start_line], ax
        mov     si, [si+E_RES_OFF]      ; full path in res_heap
        mov     di, targpath
.cp:
        mov     al, [si]
        mov     [di], al
        inc     si
        inc     di
        or      al, al
        jnz     .cp
        mov     byte [view_hex], 0
        jmp     view_open_builtin

; results_enter: Enter on the active results panel. Inert on the status row. A
; grep row opens the viewer at its line (when FEAT_VIEW is built); a find row
; turns the panel into a real listing of the file's folder, cursor on the file.
results_enter:
        mov     bx, [active]
        call    cur_entry_ptr           ; si = entry, ppanel = bx
        test    byte [si+E_ATTR], E_ATTR_STATUS
        jnz     .ret
        cmp     byte [si+E_NAME], '.'   ; the synthetic ".." row -> leave results
        jne     .notup                  ; (matched by name so drive rows, which
        cmp     byte [si+E_NAME+1], '.' ;  also carry the dir bit, are not caught)
        je      results_leave
.notup:
        cmp     word [si+E_RES_LINE], 0 ; line 0 = find/drive row -> folder/root jump;
        je      .findjump               ; line > 0 = grep file row -> open viewer
        jmp     results_view_at_line
.findjump:
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
%ifdef FEAT_GREP
s_grepout   db 'GREPOUT.TXT',0
%endif
s_resmore   db '...(more)',0           ; non-selectable status row (<=12 chars)
s_findredir db ' >FINDOUT.TXT',0
