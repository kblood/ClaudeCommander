; mod/cols.inc  --  FEAT_COLS
; Cycle the panel's right-hand column between size / date / time. The actual
; rendering is in core format_entry (gated on [col_mode]); this module owns
; the cycle key and the date/time formatters.

; cycle col_mode 0(size) -> 1(date) -> 2(time) -> 0 ; bound to Ctrl-F5.
col_cycle:
        mov     al, [col_mode]
        inc     al
        cmp     al, 3
        jb      .ok
        xor     al, al
.ok:
        mov     [col_mode], al
        ret

; ax = packed DOS date -> numbuf "MM-DD-YY"; returns si=numbuf, cx=8.
fmt_date:
        push    dx
        push    di                  ; di is the caller's rowbuf dest -- preserve
        mov     dx, ax
        mov     di, numbuf
        mov     ax, dx              ; month = (date>>5)&0Fh
        shr     ax, 5
        and     ax, 0Fh
        call    put2
        mov     byte [di], '-'
        inc     di
        mov     ax, dx              ; day = date & 1Fh
        and     ax, 1Fh
        call    put2
        mov     byte [di], '-'
        inc     di
        mov     ax, dx              ; year = ((date>>9)&7Fh) since 1980
        shr     ax, 9
        and     ax, 7Fh
        add     ax, 80              ; -> yy = (80 + years) mod 100
.ymod:
        cmp     ax, 100
        jb      .yok
        sub     ax, 100
        jmp     .ymod
.yok:
        call    put2
        mov     byte [di], 0        ; NUL-terminate (the row copy stops on NUL)
        mov     si, numbuf
        mov     cx, 8
        pop     di
        pop     dx
        ret

; ax = packed DOS time -> numbuf "HH:MM"; returns si=numbuf, cx=5.
fmt_time:
        push    dx
        push    di                  ; di is the caller's rowbuf dest -- preserve
        mov     dx, ax
        mov     di, numbuf
        mov     ax, dx              ; hour = (time>>11)&1Fh
        shr     ax, 11
        and     ax, 1Fh
        call    put2
        mov     byte [di], ':'
        inc     di
        mov     ax, dx              ; min = (time>>5)&3Fh
        shr     ax, 5
        and     ax, 3Fh
        call    put2
        mov     byte [di], 0        ; NUL-terminate
        mov     si, numbuf
        mov     cx, 5
        pop     di
        pop     dx
        ret

; ax = 0..99 -> two ASCII digits at [di], di += 2. Clobbers ax; preserves dx.
put2:
        push    dx
        aam                         ; ah = al/10, al = al%10
        add     ax, 3030h
        mov     dl, ah
        mov     [di], dl            ; tens
        mov     [di+1], al          ; units
        add     di, 2
        pop     dx
        ret
