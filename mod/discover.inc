; @feature DISCOVER
; @title   startup CC*.COM discovery -> gate tool keys/menu items on presence
; @cost    420
; @optin   changes tool behaviour (a missing tool's key/menu item becomes a
;          silent no-op instead of "Bad command"); select it explicitly.
;
; mod/discover.inc  --  FEAT_DISCOVER
; At startup (after cc.ini, before the panels are read) scan for the external
; helper .COMs cc knows about and record which are present in a bitmap. A tool's
; key binding and Tools-menu item are then gated on its bit: present -> the key
; fires / the item acts; absent -> it is a silent no-op (no COMMAND.COM "Bad
; command or file name" takeover). This is the "give you the features it found"
; behaviour from the architecture doc.
;
; Discovery mirrors the directories COMMAND.COM actually searches for the EXEC,
; so "present" == "launchable": the current directory, every entry on PATH, and
; cc's own program directory (from argv0). Scanning fewer places could falsely
; disable a tool that would in fact run -- which is why FEAT_DISCOVER is opt-in
; rather than forced into STD.

; discover_tools: fill present_tools. Called once at startup.
discover_tools:
        push    es
        mov     ah, 1Ah                 ; point the DTA at our scratch DTA
        mov     dx, dta_buf
        int     21h
        mov     word [present_tools], 0
        ; 1) current directory
        mov     dx, s_ccmask
        call    scan_spec
        ; 2) every directory on PATH
        call    scan_path_dirs
        ; 3) cc's own program directory (argv0)
        call    get_progdir             ; -> progdir_buf (trailing '\'); CF=1 if none
        jc      .done
        mov     si, progdir_buf
        mov     di, disc_spec
        call    disc_catz
        mov     si, s_ccmask
        call    disc_catz
        mov     byte [di], 0
        mov     dx, disc_spec
        call    scan_spec
.done:
        pop     es
        ret

; scan_spec: ds:dx = ASCIIZ FindFirst spec. OR each matching file's tool bit into
; present_tools. Uses the DTA set by discover_tools. es is preserved (FindFirst/
; FindNext and match_tool do not touch it).
scan_spec:
        mov     cx, 0                   ; normal files only
        mov     ah, 4Eh
        int     21h
        jc      .done
.loop:
        call    match_tool
        mov     ah, 4Fh                 ; FindNext
        int     21h
        jnc     .loop
.done:
        ret

; match_tool: compare the DTA filename (dta_buf+30, uppercase ASCIIZ from DOS)
; against the known-tool table; OR the bit on a match. Clobbers ax/bx/si/di.
match_tool:
        mov     bx, tooltab
.row:
        cmp     byte [bx], 0
        je      .done                   ; sentinel
        mov     si, bx
        mov     di, dta_buf+30
.cmp:
        mov     al, [si]
        mov     ah, [di]
        cmp     al, ah
        jne     .next
        or      al, al
        jz      .match
        inc     si
        inc     di
        jmp     .cmp
.next:
        mov     si, bx                  ; advance bx past name NUL + the bit word
.adv:
        inc     si
        cmp     byte [si-1], 0
        jne     .adv
        add     si, 2
        mov     bx, si
        jmp     .row
.match:
        inc     si                      ; si was at the name's NUL -> bit word
        mov     ax, [si]
        or      [present_tools], ax
.done:
        ret

; scan_path_dirs: walk the PATH env value, split on ';', scan each directory.
; The env-walk position is kept in [disc_pp] across scan_spec (which clobbers
; si/di). es = environment segment throughout.
scan_path_dirs:
        push    es
        mov     ax, [2Ch]
        mov     es, ax
        xor     di, di
.find:
        cmp     byte [es:di], 0
        je      .none                   ; end of env, no PATH
        mov     dx, di
        mov     si, s_pathvar
.c:
        mov     bl, [si]
        or      bl, bl
        jz      .gotpath                ; matched "PATH="
        mov     al, [es:di]
        and     al, 0DFh                ; case-insensitive
        mov     ah, bl
        and     ah, 0DFh
        cmp     al, ah
        jne     .nm
        inc     si
        inc     di
        jmp     .c
.nm:
        mov     di, dx                  ; skip this env string
.skip:
        cmp     byte [es:di], 0
        je      .skipped
        inc     di
        jmp     .skip
.skipped:
        inc     di
        jmp     .find
.gotpath:
        mov     [disc_pp], di           ; es:di -> PATH value
.entry:
        mov     di, [disc_pp]
        cmp     byte [es:di], 0
        je      .none
        mov     bx, disc_spec
.copy:
        mov     al, [es:di]
        or      al, al
        jz      .copied
        cmp     al, ';'
        je      .copied
        mov     [bx], al
        inc     bx
        inc     di
        jmp     .copy
.copied:
        mov     [disc_pp], di           ; stopped at ';' or NUL
        cmp     bx, disc_spec
        je      .semi                   ; empty entry -> no scan
        mov     al, [bx-1]              ; add '\' unless already separated
        cmp     al, '\'
        je      .nosep
        cmp     al, ':'
        je      .nosep
        mov     byte [bx], '\'
        inc     bx
.nosep:
        mov     si, s_ccmask
        mov     di, bx
        call    disc_catz
        mov     byte [di], 0
        mov     dx, disc_spec
        call    scan_spec               ; es preserved
.semi:
        mov     di, [disc_pp]
        cmp     byte [es:di], ';'
        jne     .none                   ; NUL -> done
        inc     di
        mov     [disc_pp], di
        jmp     .entry
.none:
        pop     es
        ret

; get_progdir: copy cc's program directory (with trailing '\') into progdir_buf.
; The full program path (argv0) follows the environment's double-NUL + a word
; count (DOS 3.0+). CF=1 if unavailable (old DOS or no '\' in the path).
get_progdir:
        push    es
        mov     ax, [2Ch]
        mov     es, ax
        xor     di, di
.skip:
        cmp     byte [es:di], 0
        je      .end
.s2:
        inc     di
        cmp     byte [es:di], 0
        jne     .s2
        inc     di                      ; past this string's NUL
        jmp     .skip
.end:
        inc     di                      ; past the terminating empty-string NUL
        add     di, 2                   ; skip the string-count word
        cmp     byte [es:di], 0
        je      .none                   ; no argv0 (old DOS)
        mov     si, progdir_buf
        xor     cx, cx                  ; chars copied
        xor     bx, bx                  ; position just after the last '\'
.cp:
        mov     al, [es:di]
        mov     [si], al
        or      al, al
        jz      .cpe
        inc     si
        inc     di
        inc     cx
        cmp     al, '\'
        jne     .cp
        mov     bx, cx                  ; remember "after this backslash"
        jmp     .cp
.cpe:
        or      bx, bx
        jz      .none                   ; no '\' -> cannot form a directory
        mov     byte [progdir_buf+bx], 0
        pop     es
        clc
        ret
.none:
        pop     es
        stc
        ret

; copy ASCIIZ ds:si -> [di] without the NUL; di advanced.
disc_catz:
        mov     al, [si]
        or      al, al
        jz      .d
        mov     [di], al
        inc     si
        inc     di
        jmp     disc_catz
.d:     ret

; known external tools: ASCIIZ name (DOS-uppercase) + word bit. Sentinel = 0.
tooltab:
        db 'CCFIND.COM',0
        dw TOOLBIT_FIND
        db 'CCGREP.COM',0
        dw TOOLBIT_GREP
        db 'CCSUM.COM',0
        dw TOOLBIT_SUM
        db 'CCDIFF.COM',0
        dw TOOLBIT_DIFF
        db 'CCSPLIT.COM',0
        dw TOOLBIT_SPLIT
        db 'CCREN.COM',0
        dw TOOLBIT_REN
        db 0
s_ccmask    db 'CC*.COM',0
s_pathvar   db 'PATH=',0
