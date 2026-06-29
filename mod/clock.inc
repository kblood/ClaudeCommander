; @feature CLOCK
; @title   live HH:MM:SS clock on the command row
; @needs   WIDGETS
; @cost    95
;
; mod/clock.inc  --  FEAT_CLOCK
; Draws HH:MM:SS at the right end of a configurable screen row.
; Position is governed by clock_pos (set via cc.ini "clock ="):
;   0 = cmdrow  (row 23, cols 71-78) -- default
;   1 = topright (MENUBAR_ROW row 0, cols 71-78; clock paints over menubar bg)
;   2 = off     (clock hidden; clock_tick is a no-op)
; Hooked from render_all (after mb_bar_draw so topright paints on top).
; No .bss; ~tiny. Reads the time via INT 21h AH=2Ch.

A_CLK       equ 00Fh            ; bright white on black (cmdrow)
A_CLK_TR    equ 03Fh            ; bright white on cyan  (topright / menubar row)

; Top-right target row. With the menu bar it is the bar row (0); without it
; (e.g. the CCPOP pop-up build, where MENUBAR_ROW is undefined) fall back to the
; top frame row. Both resolve to 0 today, but this keeps every FEAT mix building.
%ifdef FEAT_MENUBAR
CLK_TR_ROW  equ MENUBAR_ROW
%else
CLK_TR_ROW  equ TOP_ROW
%endif

; Idle refresh: called from get_key's poll loop. Redraws the clock only when
; the second actually changes, so it ticks ~once a second between keystrokes
; without the cost of redrawing every poll. clk_last seeds to an impossible
; second so the first idle poll always paints.
clock_tick:
        cmp     byte [clock_pos], 2
        je      .ret                ; early-out if clock is off
        push    ax
        push    dx
        mov     ah, 2Ch
        int     21h                 ; dh = seconds
        cmp     dh, [clk_last]
        je      .done
        mov     [clk_last], dh
        call    draw_clock
.done:
        pop     dx
        pop     ax
.ret:
        ret

draw_clock:
        cmp     byte [clock_pos], 2
        je      .off                ; early-out if clock is off
        push    es
        push    ax
        push    cx
        push    dx
        push    di
        mov     ah, 2Ch
        int     21h             ; ch=hour cl=min dh=sec
        mov     ax, [vseg]
        mov     es, ax
        cmp     byte [clock_pos], 1
        je      .topright
        ; cmdrow (default)
        mov     di, CMD_ROW*ROW_BYTES + 71*2
        mov     byte [clk_attr], A_CLK
        jmp     .draw
.topright:
        mov     di, CLK_TR_ROW*ROW_BYTES + 71*2
        mov     byte [clk_attr], A_CLK_TR
.draw:
        mov     al, ch          ; hour
        call    clk_2dig
        mov     al, ':'
        mov     ah, [clk_attr]
        stosw
        mov     al, cl          ; minute
        call    clk_2dig
        mov     al, ':'
        mov     ah, [clk_attr]
        stosw
        mov     al, dh          ; second
        call    clk_2dig
        pop     di
        pop     dx
        pop     cx
        pop     ax
        pop     es
.off:
        ret

; al = 0..99 -> two ASCII digits at es:di using [clk_attr], di advanced.
; Clobbers ax only.
clk_2dig:
        aam                     ; ah = al/10, al = al%10
        add     ax, 3030h       ; both nibbles -> ASCII
        push    ax
        mov     al, ah          ; tens
        mov     ah, [clk_attr]
        stosw
        pop     ax              ; al = units
        mov     ah, [clk_attr]
        stosw
        ret

clock_pos   db 0                ; 0=cmdrow, 1=topright, 2=off
clk_attr    db A_CLK            ; attribute used by clk_2dig (set by draw_clock)
clk_last    db 0FFh             ; last second drawn (0FFh = force first paint)
