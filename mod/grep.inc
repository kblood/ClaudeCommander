; @feature GREP
; @title   Alt-F8 search file contents (CCGREP)
; @cost    125
;
; mod/grep.inc  --  FEAT_GREP
; Alt-F8 searches file *contents* across the active panel's directory tree.
; Prompts for a word, then launches the external CCGREP.COM (which walks the
; tree, reads each file and prints "path:line" for every matching line) via the
; run_command EXEC path -- keeping cc small while the heavy scan lives in a
; separate Layer-3 binary, exactly like Alt-F7 / CCFIND.

key_grep:
        mov     si, s_grepprompt
        call    dlg_input               ; -> dlgbuf, CF=1 if cancelled
        jc      .ret
        cmp     byte [dlgbuf], 0
        je      .ret
        ; cmdbuf = "CCGREP " + word + " " + panelpath + " *.*"
        mov     di, cmdbuf
        mov     si, s_greppfx
        call    grep_catz
        mov     si, dlgbuf
        call    grep_catz
        mov     byte [di], ' '
        inc     di
        mov     bx, [active]
        lea     si, [bx+P_PATH]
        call    grep_catz
        mov     si, s_grepmask
        call    grep_catz
%ifdef FEAT_RESULTS
        mov     si, s_grepredir         ; ' >GREPOUT.TXT' (results.inc parses it)
        call    grep_catz
%endif
        mov     ax, di
        sub     ax, cmdbuf
        mov     [cmdlen], ax
%ifdef FEAT_RESULTS
        call    run_helper              ; silent EXEC; matches -> GREPOUT.TXT
        mov     word [cmdlen], 0
        call    results_show_grep       ; load them into the other panel + focus it
%else
        call    run_command
%endif
.ret:
        ret

; append ASCIIZ ds:si at [di] (no terminator); di advanced.
grep_catz:
        mov     al, [si]
        or      al, al
        jz      .d
        mov     [di], al
        inc     si
        inc     di
        jmp     grep_catz
.d:     ret

s_greppfx       db 'CCGREP ',0
s_grepmask      db ' *.*',0
s_grepprompt    db 'Search file contents for (a word):',0
%ifdef FEAT_RESULTS
s_grepredir     db ' >GREPOUT.TXT',0
%endif
