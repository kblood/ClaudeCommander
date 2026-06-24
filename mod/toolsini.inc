; @feature TOOLS_INI
; @title   cc.ini [tools] registry: drop-in helpers become Tools-menu rows
; @needs   TOOLS INI
; @cost    140
;
; mod/toolsini.inc  --  FEAT_TOOLS_INI
; The opt-in runtime half of the [tools] registry (architecture doc S8.7): a
; user lists "label = program" lines under [tools] in cc.ini and each one shows
; up as a new row on the Tools pull-down -- no rebuild, no code change. That is
; the full "drop a .COM, get a feature" loop for the MENU surface.
;
; ini.inc's parser (tools_add) fills utool_lbl[]/utool_cmd[] at startup. Here we
; splice those user rows onto the END of the static built-in Tools menu into a
; runtime table (tools_menu_rt) that the menu bar's Tools row points at, then
; provide one shared handler (run_user_tool) that EXECs the chosen program with
; the cursor file as its argument -- the same "action" contract the built-in
; CCSUM/CCDIFF/... items use (run_command: visible EXEC, wait-for-key, reload).
;
; Scope note: this is the menu half only. Binding a user tool to a HOTKEY would
; need dynamic keytab registration (scan-code allocation + conflict policy) --
; a separate design decision, deliberately left for a follow-on.

; Build tools_menu_rt = the static mb_tools rows (copied verbatim) followed by
; one {label, run_user_tool} row per cc.ini [tools] entry, 0-terminated. Records
; how many built-in rows lead, so run_user_tool can map a selection index back
; to its utool slot. Runs once at startup, after ini_load.
build_tools_menu:
        mov     si, mb_tools            ; the static built-in template
        mov     di, tools_menu_rt
        xor     cx, cx                  ; built-in row count
.copy:
        mov     ax, [si]                ; label ptr (0 terminates the template)
        or      ax, ax
        jz      .copied
        mov     [di], ax
        mov     ax, [si+2]              ; handler ptr
        mov     [di+2], ax
        add     si, 4
        add     di, 4
        inc     cx
        jmp     .copy
.copied:
        mov     [tools_builtin_n], cx
        mov     cx, [utool_n]
        jcxz    .term
        xor     bx, bx                  ; word index into utool_lbl (i*2)
.urow:
        mov     ax, [utool_lbl+bx]
        mov     [di], ax
        mov     word [di+2], run_user_tool
        add     di, 4
        add     bx, 2
        loop    .urow
.term:
        mov     word [di], 0            ; terminate the runtime menu
        ret

; Handler shared by every cc.ini [tools] row. The menu bar leaves [mb_sel] = the
; picked row's absolute index in tools_menu_rt and [mb_items] = tools_menu_rt;
; subtract the built-in lead count to recover the utool slot, then build and EXEC
; "<program> <cursor-path>" via the same path the built-in Tools items use.
run_user_tool:
        mov     ax, [mb_sel]
        sub     ax, [tools_builtin_n]
        js      .ret                    ; defensive: a built-in row shouldn't land here
        cmp     ax, [utool_n]
        jae     .ret
        shl     ax, 1
        mov     bx, ax
        mov     si, [utool_cmd+bx]      ; the program name (ASCIIZ)
        mov     di, cmdbuf
        call    bp_copy_name            ; copies incl NUL, leaves di AT the NUL
        call    tools_cur_path          ; targpath = cursor file; CF=1 if none/dir
        jc      .exec                   ; no usable cursor -> run the program bare
        mov     byte [di], ' '          ; overwrite the NUL with the separator
        inc     di
        mov     si, targpath
        call    bp_copy_name
.exec:
        jmp     tools_exec              ; sets cmdlen, tail-calls run_command, ret
.ret:
        ret
