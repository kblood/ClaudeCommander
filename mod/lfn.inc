; mod/lfn.inc  --  FEAT_LFN
; On-demand long-name display for the CURSOR entry only.  Storing a 255-byte
; long name for every directory entry would blow the 64 KB segment, so the
; panels keep 8.3 names and this resolves just the highlighted entry's long
; name via the LFN FindFirst API (INT 21h AX=714Eh).  The long name is drawn on
; the command row when no command is being typed.
;
; If the host has no LFN provider (bare MS-DOS / FreeDOS without DOSLFN, or an
; emulator with LFN off) the call returns CF=1 and nothing is drawn -- the 8.3
; panel still shows.  Activates automatically under Windows 9x DOS, DOSLFN, or
; an LFN-enabled emulator.
;
; Called from draw_cmdline (cmdlen==0 path) with es=VIDEO and di at the cursor
; position on CMD_ROW, just past the "path>" prompt.

lfn_draw_cursor:
        mov     [lfn_di], di
        mov     bx, [active]
        mov     cx, [bx+P_COUNT]
        jcxz    .ret
        call    cur_entry_ptr           ; si = cursor entry
        cmp     byte [si+E_NAME], '.'   ; skip "." / ".." parent entries
        je      .ret
        call    build_entry_path        ; targpath = full 8.3 path of cursor
        push    es                      ; 714Eh fills es:di -> our segment
        push    ds
        pop     es
        mov     ax, 714Eh               ; LFN FindFirst
        mov     cx, 0016h               ; allow hidden/system/directory matches
        xor     si, si                  ; SI=0: DOS-style date/time in buffer
        mov     dx, targpath            ; ds:dx = search spec (the 8.3 path)
        mov     di, copybuf             ; 318-byte WIN32_FIND_DATA (reused buf)
        int     21h
        pop     es                      ; restore es = VIDEO
        jc      .ret                    ; no LFN provider / not found
        mov     bx, ax                  ; bx = search handle
        mov     ax, 71A1h               ; LFN FindClose (frees the handle)
        int     21h
        ; draw the long name (cFileName at offset 0x2C) after the prompt
        mov     di, [lfn_di]
        mov     ah, A_CMD
        mov     al, ' '
        stosw                           ; one-space gap after "path>"
        mov     si, copybuf+44          ; +0x2C = long name ASCIIZ
.draw:  mov     al, [si]
        or      al, al
        jz      .ret
        mov     cx, di
        and     cx, ROW_BYTES-1         ; column byte offset within the row
        cmp     cx, ROW_BYTES-2
        jae     .ret                    ; reached the right edge of the row
        stosw
        inc     si
        jmp     .draw
.ret:
        ret
