; mod/clock.inc  --  FEAT_CLOCK
; Draws HH:MM:SS at the right end of the command row (row 23, cols 71-78).
; Hooked from render_all (after draw_cmdline), so it redraws on every frame.
; No .bss; ~tiny. Reads the time via INT 21h AH=2Ch.

A_CLK   equ 00Fh                ; bright white on black (command row bg)

draw_clock:
        push    es
        push    ax
        push    cx
        push    dx
        push    di
        mov     ah, 2Ch
        int     21h             ; ch=hour cl=min dh=sec
        mov     ax, VIDEO
        mov     es, ax
        mov     di, CMD_ROW*ROW_BYTES + 71*2
        mov     al, ch          ; hour
        call    clk_2dig
        mov     al, ':'
        mov     ah, A_CLK
        stosw
        mov     al, cl          ; minute
        call    clk_2dig
        mov     al, ':'
        mov     ah, A_CLK
        stosw
        mov     al, dh          ; second
        call    clk_2dig
        pop     di
        pop     dx
        pop     cx
        pop     ax
        pop     es
        ret

; al = 0..99 -> two ASCII digits (white-on-black) at es:di, di advanced.
; Clobbers ax only.
clk_2dig:
        aam                     ; ah = al/10, al = al%10
        add     ax, 3030h       ; both nibbles -> ASCII
        push    ax
        mov     al, ah          ; tens
        mov     ah, A_CLK
        stosw
        pop     ax              ; al = units
        mov     ah, A_CLK
        stosw
        ret
