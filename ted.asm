; ted.asm -- tiny test "editor" used only by run_editor.ps1.
; Writes its DOS command tail (PSP:0x80) to TEDOUT.TXT and exits, so the test
; can prove that cc honoured "editor = TED" in cc.ini and passed the file path.
        org     100h
        mov     ah, 3Ch             ; create/truncate TEDOUT.TXT
        xor     cx, cx
        mov     dx, fname
        int     21h
        jc      done
        mov     bx, ax              ; file handle
        mov     ah, 40h             ; write the command tail
        mov     cl, [80h]           ; tail length byte
        xor     ch, ch
        mov     dx, 81h             ; tail text
        int     21h
        mov     ah, 3Eh             ; close (bx still = handle)
        int     21h
done:
        mov     ax, 4C00h
        int     21h
fname   db 'TEDOUT.TXT', 0
