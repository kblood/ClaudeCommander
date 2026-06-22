; mod/mouse.inc  --  extracted from cc.asm (M1 module split, byte-identical)
; Plain implicit-text code only; no section/equ/macro (see plan/m1_split.md).

; ============================================================================
;  MOUSE SUPPORT (INT 33h)
;    left click  : activate panel + move cursor to the clicked entry
;    dbl click   : open (Enter)         right click : tag/untag the entry
;    click F-bar : invoke that F-key
; ============================================================================
mouse_hide:
        cmp     byte [mouse_ok], 0
        je      .r
        push    ax
        mov     ax, 2
        int     33h
        pop     ax
.r:     ret

mouse_show:
        cmp     byte [mouse_ok], 0
        je      .r
        push    ax
        mov     ax, 1
        int     33h
        pop     ax
.r:     ret

; poll mouse; CF=1 with ax=synthetic key if a click was acted on, else CF=0
mouse_poll:
        push    bx
        push    cx
        push    dx
        mov     ax, 3
        int     33h                 ; bx=buttons cx=x dx=y (virtual 8px cells)
        mov     [m_x], cx
        mov     [m_y], dx
        ; ---- left button edge ----
        mov     al, bl
        and     al, 1
        mov     ah, [m_lb]
        mov     [m_lb], al
        or      al, al
        jz      .right
        or      ah, ah
        jnz     .right              ; was already down -> not an edge
        mov     al, [mouse_mode]
        cmp     al, MM_OFF
        je      .none               ; clicks ignored (e.g. file viewer)
        cmp     al, MM_CONFIRM
        je      .cfm
        cmp     al, MM_OWRITE
        je      .owr
        call    mouse_left          ; browser: -> ax = synthetic key
        jmp     .event
.cfm:
        call    mouse_confirm       ; confirm dialog: -> al = 'Y'/'N' or 0
        jmp     .event
.owr:
        call    mouse_overwrite     ; overwrite dialog: -> al = O/S/A/Esc or 0
        jmp     .event
.right:
        mov     al, bl
        and     al, 2
        mov     ah, [m_rb]
        mov     [m_rb], al
        or      al, al
        jz      .none
        or      ah, ah
        jnz     .none
        cmp     byte [mouse_mode], MM_BROWSER
        jne     .none               ; right-click only tags in the browser
        call    mouse_right         ; -> ax = synthetic key
        jmp     .event
.none:
        pop     dx
        pop     cx
        pop     bx
        clc
        ret
.event:
        pop     dx
        pop     cx
        pop     bx
        stc
        ret

; resolve [m_x]/[m_y] to row/col; if it lands on a panel entry, set bx=panel
; and ax=entry index, return CF=1. Otherwise CF=0.
mouse_hit:
        mov     ax, [m_y]
        shr     ax, 3
        mov     [m_row], ax
        mov     ax, [m_x]
        shr     ax, 3
        mov     [m_col], ax
        cmp     word [m_row], FIRST_ROW
        jb      .miss
        mov     ax, [m_row]
        sub     ax, FIRST_ROW
        cmp     ax, VIS_ROWS
        jae     .miss
        mov     [m_vis], ax
        mov     ax, [m_col]
        cmp     ax, L_CONX
        jb      .miss
        cmp     ax, L_CONX+L_CONW
        jb      .leftp
        cmp     ax, R_CONX
        jb      .miss               ; on the divider
        cmp     ax, R_CONX+R_CONW
        jb      .rightp
.miss:
        clc
        ret
.leftp:
        mov     bx, panelL
        jmp     .sel
.rightp:
        mov     bx, panelR
.sel:
        mov     ax, [bx+P_TOP]
        add     ax, [m_vis]
        cmp     ax, [bx+P_COUNT]
        jae     .miss               ; clicked past the last entry
        stc
        ret

mouse_left:
        call    mouse_hit           ; computes m_row/m_col; CF=1 -> bx,ax
        jc      .onrow
        ; not on a row: maybe the function-key bar
        cmp     word [m_row], FKEY_ROW
        je      .fbar
        xor     ax, ax
        ret
.onrow:
        mov     [active], bx
        mov     [bx+P_CUR], ax
        call    fix_scroll          ; bx=panel (clobbers ax)
        call    get_tick            ; -> ax = tick
        mov     cx, ax
        mov     dx, [bx+P_CUR]
        cmp     bx, [m_lastpan]
        jne     .new
        cmp     dx, [m_lastidx]
        jne     .new
        mov     ax, cx
        sub     ax, [m_lasttick]
        cmp     ax, 9               ; ~0.5s double-click window
        ja      .new
        mov     word [m_lastpan], 0FFFFh
        mov     ax, 000Dh           ; Enter
        ret
.new:
        mov     [m_lasttick], cx
        mov     [m_lastpan], bx
        mov     [m_lastidx], dx
        xor     ax, ax              ; no-op key -> just re-render
        ret
.fbar:
        call    fbar_to_key
        ret

mouse_right:
        call    mouse_hit           ; CF=1 -> bx=panel, ax=index
        jnc     .noop
        mov     [active], bx
        mov     [bx+P_CUR], ax
        call    fix_scroll
        mov     [ppanel], bx
        mov     ax, [bx+P_CUR]
        call    entry_ptr           ; si = entry[ax]
        mov     al, [si+E_NAME]
        cmp     al, '.'
        je      .noop               ; never tag '.'/'..'
        xor     byte [si+E_ATTR], 40h
.noop:
        xor     ax, ax
        ret

; confirm-dialog click: hit-test [m_x]/[m_y] vs the Yes/No buttons
; -> al='Y' or 'N' (ah=0) if a button was hit, else ax=0
mouse_confirm:
        mov     ax, [m_y]
        shr     ax, 3
        cmp     ax, BTN_ROW
        jne     .noop
        mov     ax, [m_x]
        shr     ax, 3               ; col
        cmp     ax, YES_C0
        jb      .chkno
        cmp     ax, YES_C1
        ja      .chkno
        mov     ax, 'Y'
        ret
.chkno:
        cmp     ax, NO_C0
        jb      .noop
        cmp     ax, NO_C1
        ja      .noop
        mov     ax, 'N'
        ret
.noop:
        xor     ax, ax
        ret

; click hit-test for the overwrite dialog -> al = 'O'/'S'/'A'/Esc or 0
mouse_overwrite:
        mov     ax, [m_y]
        shr     ax, 3
        cmp     ax, BTN_ROW
        jne     .noop
        mov     ax, [m_x]
        shr     ax, 3               ; col
        cmp     ax, OWR_C0
        jb      .noop
        cmp     ax, OWR_C1
        ja      .chkskp
        mov     ax, 'O'
        ret
.chkskp:
        cmp     ax, SKP_C0
        jb      .noop
        cmp     ax, SKP_C1
        ja      .chkall
        mov     ax, 'S'
        ret
.chkall:
        cmp     ax, OAL_C0
        jb      .noop
        cmp     ax, OAL_C1
        ja      .chkcan
        mov     ax, 'A'
        ret
.chkcan:
        cmp     ax, CAN_C0
        jb      .noop
        cmp     ax, CAN_C1
        ja      .noop
        mov     ax, 1Bh             ; Cancel -> Esc
        ret
.noop:
        xor     ax, ax
        ret

