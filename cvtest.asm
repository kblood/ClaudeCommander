; ============================================================================
;  CCVTEST.COM  --  a trivial [view] helper used only to validate cc's F3
;  viewer dispatch.  It writes its single filename argument into VIEWED.TXT in
;  the current directory, so a test can assert that F3 ran the mapped viewer
;  with the right path.  Not shipped as a user tool.
;
;  Assemble:  nasm -f bin cvtest.asm -o ccvtest.com
; ============================================================================
        org     100h
start:
        cld
        ; the command tail: length at 80h, chars from 81h (terminated by CR)
        mov     si, 81h
        movzx   cx, byte [80h]
        ; skip leading spaces
.skip:
        jcxz    .write
        cmp     byte [si], ' '
        jne     .write
        inc     si
        dec     cx
        jmp     .skip
.write:
        ; copy the rest (up to CR) into argbuf
        mov     di, argbuf
.cp:
        jcxz    .done
        mov     al, [si]
        cmp     al, 0Dh
        je      .done
        mov     [di], al
        inc     si
        inc     di
        dec     cx
        jmp     .cp
.done:
        mov     [arglen], di
        ; create VIEWED.TXT and write argbuf
        mov     ah, 3Ch
        xor     cx, cx
        mov     dx, fname
        int     21h
        jc      .exit
        mov     bx, ax
        mov     cx, [arglen]
        sub     cx, argbuf
        mov     dx, argbuf
        mov     ah, 40h
        int     21h
        mov     ah, 3Eh
        int     21h
.exit:
        mov     ax, 4C00h
        int     21h

fname   db 'VIEWED.TXT',0
arglen  dw 0
argbuf  times 128 db 0
