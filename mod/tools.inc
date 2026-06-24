; mod/tools.inc  --  FEAT_TOOLS
; A "Tools" pull-down (added to the menu bar) that runs the external helper
; .COMs on the cursor / panel files so they feel built in. Each item just
; assembles a command line and reuses run_command -- which EXECs the helper
; visibly and waits for a key before returning, exactly like F4 (CCEDIT),
; Alt-F7 (CCFIND) and Alt-F8 (CCGREP). The heavy lifting stays in the Layer-3
; binaries (CCSUM/CCDIFF/CCSPLIT/CCREN); cc only builds the command, so the
; resident core barely grows. (The "Hex dump" item is the one truly built-in
; action -- it calls key_hexview, which opens the F3 pager straight into hex.)
;
; All string-building uses the core bp_copy_name (copies ASCIIZ incl. NUL and
; leaves di AT the NUL, so the next copy or space simply overwrites it).

; CF=0 with targpath = active cursor's full path; CF=1 if empty / a directory.
tools_cur_path:
        mov     bx, [active]
        mov     cx, [bx+P_COUNT]
        jcxz    .no
        call    cur_entry_ptr
        test    byte [si+E_ATTR], 10h
        jnz     .no
        call    build_entry_path        ; -> targpath
        clc
        ret
.no:
        stc
        ret

; di = one past the command in cmdbuf -> set cmdlen and EXEC. run_command ends
; in ret, so this tail-call returns to the Tools handler's caller.
tools_exec:
        mov     ax, di
        sub     ax, cmdbuf
        mov     [cmdlen], ax
        jmp     run_command

; Tools / Checksum:  CCSUM <cursor>
key_tools_sum:
        call    tools_cur_path
        jc      .ret
        mov     di, cmdbuf
        mov     si, s_t_sum
        call    bp_copy_name
        mov     si, targpath
        call    bp_copy_name
        jmp     tools_exec
.ret:
        ret

; Tools / Compare:  CCDIFF <active cursor> <other-panel cursor>
key_tools_cmp:
        call    tools_cur_path          ; targpath = left file
        jc      .ret
        call    other_panel_ptr         ; bx = the other panel
        mov     cx, [bx+P_COUNT]
        jcxz    .ret
        call    cur_entry_ptr           ; si = other cursor (bx unchanged)
        test    byte [si+E_ATTR], 10h
        jnz     .ret
        call    build_other_path        ; targpath2 = right file
        mov     di, cmdbuf
        mov     si, s_t_diff
        call    bp_copy_name
        mov     si, targpath
        call    bp_copy_name
        mov     byte [di], ' '
        inc     di
        mov     si, targpath2
        call    bp_copy_name
        jmp     tools_exec
.ret:
        ret

; Tools / Split:  prompt for piece size, then  CCSPLIT <cursor> <size>
key_tools_split:
        call    tools_cur_path
        jc      .ret
        mov     si, s_t_splitp
        call    dlg_input               ; -> dlgbuf, CF=1 if cancelled
        jc      .ret
        cmp     byte [dlgbuf], 0
        je      .ret
        mov     di, cmdbuf
        mov     si, s_t_split
        call    bp_copy_name
        mov     si, targpath
        call    bp_copy_name
        mov     byte [di], ' '
        inc     di
        mov     si, dlgbuf
        call    bp_copy_name
        jmp     tools_exec
.ret:
        ret

; Tools / Rename:  prompt source + destination masks, then CCREN <src> <dst>
key_tools_ren:
        mov     si, s_t_renp1
        call    dlg_input
        jc      .ret
        cmp     byte [dlgbuf], 0
        je      .ret
        mov     si, dlgbuf               ; stash source mask in targpath
        mov     di, targpath
        call    bp_copy_name
        mov     si, s_t_renp2
        call    dlg_input
        jc      .ret
        cmp     byte [dlgbuf], 0
        je      .ret
        mov     di, cmdbuf
        mov     si, s_t_ren
        call    bp_copy_name
        mov     si, targpath
        call    bp_copy_name
        mov     byte [di], ' '
        inc     di
        mov     si, dlgbuf
        call    bp_copy_name
        jmp     tools_exec
.ret:
        ret

s_t_sum     db 'CCSUM ', 0
s_t_diff    db 'CCDIFF ', 0
s_t_split   db 'CCSPLIT ', 0
s_t_ren     db 'CCREN ', 0
s_t_splitp  db 'Split into pieces of N bytes (e.g. 360K):', 0
s_t_renp1   db 'Wildcard rename - source mask (e.g. *.TXT):', 0
s_t_renp2   db 'Destination mask (e.g. *.BAK):', 0
