; ============================================================================
;  CCTOUCH.COM  --  Claude Commander's external timestamp tool (Layer 3)
;
;  Usage:  CCTOUCH <file>                     set date+time to NOW
;          CCTOUCH <file> YYYY-MM-DD          set that date, time 00:00:00
;          CCTOUCH <file> YYYY-MM-DD HH:MM    set date and time (sec = 00)
;          CCTOUCH <file> YYYY-MM-DD HH:MM:SS set date and full time
;
;  Stamps a file's modification date/time the classic DOS way: open the file,
;  INT 21h/5701h to write the SFT date/time, close.  Read-only files are
;  handled by clearing the read-only bit for the operation and restoring the
;  original attributes afterwards.  Prints "<name>  YYYY-MM-DD HH:MM:SS" on
;  success so the result is visible / pipeable.
;
;  Like the other Layer-3 helpers this is a tiny standalone .COM (no table,
;  no libc) so it costs nothing against cc.asm's 64 KB resident segment.
;
;  Assemble:  nasm -f bin ctouch.asm -o cctouch.com
; ============================================================================
        org     100h

start:
        cld
        mov     sp, stacktop
        call    parse_args
        cmp     byte [fname], 0
        je      .usage

        ; --- decide the timestamp fields (NOW, or explicit from the tail) ---
        cmp     byte [darg], 0
        jne     .explicit
        ; NOW: INT 21h 2Ah -> CX=year DH=month DL=day ; 2Ch -> CH=hr CL=min DH=sec
        mov     ah, 2Ah
        int     21h
        mov     [year], cx
        mov     [mon], dh
        mov     [day], dl
        mov     ah, 2Ch
        int     21h
        mov     [hr], ch
        mov     [minu], cl
        mov     [sec], dh
        jmp     .pack
.explicit:
        mov     si, darg
        call    parse_num               ; year
        mov     [year], ax
        call    skip_sep
        call    parse_num               ; month
        mov     [mon], al
        call    skip_sep
        call    parse_num               ; day
        mov     [day], al
        mov     byte [hr], 0
        mov     byte [minu], 0
        mov     byte [sec], 0
        cmp     byte [targ], 0
        je      .pack
        mov     si, targ
        call    parse_num               ; hour
        mov     [hr], al
        call    skip_sep
        call    parse_num               ; minute
        mov     [minu], al
        call    skip_sep
        call    parse_num               ; second
        mov     [sec], al
.pack:
        ; date word = ((year-1980)<<9) | (month<<5) | day
        mov     ax, [year]
        sub     ax, 1980
        mov     cl, 9
        shl     ax, cl
        movzx   bx, byte [mon]
        mov     cl, 5
        shl     bx, cl
        or      ax, bx
        movzx   bx, byte [day]
        or      ax, bx
        mov     [fdate], ax
        ; time word = (hour<<11) | (min<<5) | (sec>>1)
        movzx   ax, byte [hr]
        mov     cl, 11
        shl     ax, cl
        movzx   bx, byte [minu]
        mov     cl, 5
        shl     bx, cl
        or      ax, bx
        movzx   bx, byte [sec]
        shr     bx, 1
        or      ax, bx
        mov     [ftime], ax

        ; --- read attributes so a read-only file can still be touched ---
        mov     byte [haveattr], 0
        mov     ax, 4300h
        mov     dx, fname
        int     21h
        jc      .open
        mov     [origattr], cx
        mov     byte [haveattr], 1
        test    cl, 1                   ; read-only bit?
        jz      .open
        and     cl, 0FEh                ; clear it for the duration
        mov     ax, 4301h
        mov     dx, fname
        int     21h
.open:
        mov     ax, 3D02h               ; open read/write
        mov     dx, fname
        int     21h
        jnc     .haveh
        mov     ax, 3D00h               ; fall back to read-only open
        mov     dx, fname
        int     21h
        jc      .err
.haveh:
        mov     [fh], ax
        mov     ax, 5701h               ; set file date/time
        mov     bx, [fh]
        mov     cx, [ftime]
        mov     dx, [fdate]
        int     21h
        pushf                           ; preserve 5701h's CF across close
        mov     bx, [fh]
        mov     ah, 3Eh
        int     21h
        popf
        jc      .setfail
        call    restore_attr
        call    print_ok
        mov     ax, 4C00h
        int     21h
.setfail:
        call    restore_attr
        mov     dx, s_setfail
        call    puts
        mov     ax, 4C01h
        int     21h
.err:
        call    restore_attr
        mov     dx, s_err
        call    puts
        mov     ax, 4C01h
        int     21h
.usage:
        mov     dx, s_usage
        call    puts
        mov     ax, 4C01h
        int     21h

; ----------------------------------------------------------------------------
; restore_attr: put back the original attributes if we read them.
restore_attr:
        cmp     byte [haveattr], 0
        je      .r
        mov     ax, 4301h
        mov     cx, [origattr]
        mov     dx, fname
        int     21h
.r:     ret

; ----------------------------------------------------------------------------
; parse_num: si -> ASCII digits; returns AX = value; si advanced past digits.
parse_num:
        xor     ax, ax
.l:     mov     cl, [si]
        cmp     cl, '0'
        jb      .done
        cmp     cl, '9'
        ja      .done
        mov     dx, 10
        mul     dx                      ; dx:ax = ax*10 (value stays < 65536)
        sub     cl, '0'
        mov     ch, 0
        add     ax, cx
        inc     si
        jmp     .l
.done:  ret

; skip_sep: advance si past a single non-digit separator (e.g. '-' or ':').
skip_sep:
        mov     al, [si]
        or      al, al
        jz      .d
        cmp     al, '0'
        jb      .skip
        cmp     al, '9'
        jbe     .d                      ; a digit: leave it for parse_num
.skip:  inc     si
.d:     ret

; ----------------------------------------------------------------------------
; parse_args: split the command tail into fname, darg, targ (each NUL-term'd,
; empty if absent).
parse_args:
        movzx   cx, byte [80h]
        mov     si, 81h
        mov     di, fname
        call    .tok
        mov     di, darg
        call    .tok
        mov     di, targ
        call    .tok
        ret
.tok:
.sk:    jcxz    .term
        cmp     byte [si], ' '
        jne     .cp
        inc     si
        dec     cx
        jmp     .sk
.cp:    jcxz    .term
        mov     al, [si]
        cmp     al, ' '
        je      .term
        cmp     al, 0Dh
        je      .term0
        mov     [di], al
        inc     di
        inc     si
        dec     cx
        jmp     .cp
.term:  mov     byte [di], 0
        ret
.term0: mov     byte [di], 0            ; CR ends the whole tail
        xor     cx, cx
        ret

; ----------------------------------------------------------------------------
; print_ok: "<name>  YYYY-MM-DD HH:MM:SS" CRLF
print_ok:
        mov     di, linebuf
        mov     si, fname
.nm:    mov     al, [si]
        or      al, al
        jz      .sp
        stosb
        inc     si
        jmp     .nm
.sp:    mov     al, ' '
        stosb
        stosb
        mov     ax, [year]
        call    put_u4
        mov     al, '-'
        stosb
        mov     al, [mon]
        call    put_u2
        mov     al, '-'
        stosb
        mov     al, [day]
        call    put_u2
        mov     al, ' '
        stosb
        mov     al, [hr]
        call    put_u2
        mov     al, ':'
        stosb
        mov     al, [minu]
        call    put_u2
        mov     al, ':'
        stosb
        mov     al, [sec]
        call    put_u2
        mov     ax, 0A0Dh
        stosw
        mov     cx, di
        sub     cx, linebuf
        mov     dx, linebuf
        mov     bx, 1
        mov     ah, 40h
        int     21h
        ret

; put_u4: AX (0..9999) -> 4 decimal digits at [di].
put_u4:
        mov     cx, 1000
        call    .dg
        mov     cx, 100
        call    .dg
        mov     cx, 10
        call    .dg
        mov     cx, 1
        call    .dg
        ret
.dg:    xor     dx, dx
        div     cx                      ; ax = quotient digit, dx = remainder
        add     al, '0'
        stosb
        mov     ax, dx
        ret

; put_u2: AL (0..99) -> 2 decimal digits at [di].
put_u2:
        aam                             ; ah = al/10, al = al%10
        add     ax, 3030h
        push    ax
        mov     al, ah
        stosb
        pop     ax
        stosb
        ret

; ----------------------------------------------------------------------------
puts:
        mov     di, dx
.len:   cmp     byte [di], 0
        je      .w
        inc     di
        jmp     .len
.w:     mov     cx, di
        sub     cx, dx
        mov     bx, 1
        mov     ah, 40h
        int     21h
        ret

; ============================================================================
s_usage   db 'Usage: CCTOUCH <file> [YYYY-MM-DD [HH:MM[:SS]]]',13,10
          db '  (no date/time = set to current date and time)',13,10,0
s_err     db 'CCTOUCH: cannot open file',13,10,0
s_setfail db 'CCTOUCH: cannot set date/time',13,10,0

section .bss
align 2
fname     resb 128
darg      resb 16
targ      resb 16
year      resw 1
mon       resb 1
day       resb 1
hr        resb 1
minu      resb 1
sec       resb 1
fdate     resw 1
ftime     resw 1
fh        resw 1
origattr  resw 1
haveattr  resb 1
linebuf   resb 96
stackspace resb 1024
stacktop:
