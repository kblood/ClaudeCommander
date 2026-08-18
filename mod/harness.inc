; @core (always compiled in; not a selectable feature)
;
; mod/harness.inc  --  extracted from cc.asm (M1 module split, byte-identical)
; Plain implicit-text code only; no section/equ/macro (see plan/m1_split.md).

; ============================================================================
;  SNAPSHOT: copy the 4000-byte B800 text page to CCSNAP.BIN (for PNG render)
; ============================================================================
%ifdef FEAT_SNAP
snap_vram:
        push    ds
        push    es
        mov     ax, cs              ; our segment (COM: cs=ds=ss=es)
        mov     es, ax
        mov     di, snapbuf
        mov     ax, [vseg]
        mov     ds, ax
        xor     si, si
        mov     cx, 2000            ; 4000 bytes = 2000 words
        rep     movsw
        pop     es
        pop     ds
        mov     ah, 3Ch
        xor     cx, cx
        mov     dx, snapname
        int     21h
        jc      .ret
        mov     bx, ax
        mov     ah, 40h
        mov     cx, 4000
        mov     dx, snapbuf
        int     21h
        mov     ah, 3Eh
        int     21h
.ret:
        ret
%endif

; ============================================================================
;  SELF-TEST (diagnostic): write panel counts + first names to dump
; ============================================================================
selftest:
        mov     bx, panelL
        mov     al, 'L'
        call    dbg_panel_line
        mov     bx, panelR
        mov     al, 'R'
        call    dbg_panel_line
%ifdef FEAT_LFN_FULL
;  FILETIME -> DOS packed words (known vectors, no LFN API required)
;  1985-05-17 02:04:06 -> T 0x1083 (4227) D 0x0AB1 (2737)
        mov     ax, 111
        mov     bx, 222
        call    dbg_lft
        mov     word [ft2d_t1], 0x2F00
        mov     word [ft2d_t1+2], 0x70E2
        mov     word [ft2d_t1+4], 0xEE39
        mov     word [ft2d_t1+6], 0x01AE
        lea     si, [ft2d_t1]
        call    ft2dos
        call    dbg_lft
;  2026-01-02 03:04:05 -> T 0x1882 (6274) D 0x5C22 (23586)
        mov     word [ft2d_t1], 0x0080
        mov     word [ft2d_t1+2], 0x7440
        mov     word [ft2d_t1+4], 0x7B94
        mov     word [ft2d_t1+6], 0x01DC
        lea     si, [ft2d_t1]
        call    ft2dos
        call    dbg_lft
%endif
        ret

%ifdef FEAT_LFN_FULL
; ---------------------------------------------------------------------------
;  dbg_lft: AX = DOS time word, BX = DOS date word
;    -> "LFT T=NNN D=NNNNN" (decimal) to the dump
;  T and D are PARKed at entry - every helper below clobbers AX.
;  DI is the output cursor; u32toa preserves DI (push/pop), so it is safe
;  to interleave. copy_nulstr walks SI->DI and stops at the NUL.
; ---------------------------------------------------------------------------
dbg_lft_pre: db 'LFT T=', 0
dbg_lft_mid: db ' D=', 0
;  copy_nulstr: SI = NUL string -> append to linebuf at DI, DI advanced.
;  Clobbers AL/AX CX; SI and DI both advance/are preserved-for-next-call.
copy_nulstr:
        mov     al, [si]
        or      al, al
        jz      .cn_done
        mov     [di], al
        inc     di
        inc     si
        jmp     copy_nulstr
.cn_done: ret
dbg_lft:
        mov     [dbg_lft_d], bx     ; park D
        mov     [dbg_lft_d2], ax    ; park T
        lea     di, [linebuf]
        lea     si, [dbg_lft_pre]
        call    copy_nulstr
        mov     ax, [dbg_lft_d2]   ; T
        xor     dx, dx
        call    u32toa             ; SI -> first digit in numbuf (DI preserved)
        call    copy_nulstr
        lea     si, [dbg_lft_mid]
        call    copy_nulstr
        mov     ax, [dbg_lft_d]    ; D
        xor     dx, dx
        call    u32toa
        call    copy_nulstr
        mov     byte [di], 0Dh
        inc     di
        mov     byte [di], 0Ah
        inc     di
        mov     cx, di
        sub     cx, linebuf
        mov     dx, linebuf
        mov     bx, [dumph]
        mov     ah, 40h
        int     21h
        ret

%endif
; bx=panel, al=tag -> "<tag> count=NNN name=XXXX\r\n" to dump
dbg_panel_line:
        mov     di, linebuf
        mov     [di], al
        inc     di
        mov     byte [di], ' '
        inc     di
        mov     si, dbg_cnt
        mov     al, [si]
        mov     [di], al
        inc     di
.c1:    mov al,[si]; or al,al; jz .c1e
        mov [di],al; inc di; inc si; jmp .c1
.c1e:
        push    bx
        mov     ax, [bx+P_COUNT]
        xor     dx, dx
        call    u32toa              ; si=numbuf, ends with NUL
.n1:    mov al,[si]; or al,al; jz .n1e
        mov [di],al; inc di; inc si; jmp .n1
.n1e:
        pop     bx
        mov     byte [di], ' '
        inc     di
        mov     cx, [bx+P_COUNT]
        jcxz    .noname
        mov     [ppanel], bx
        xor     ax, ax
        call    entry_ptr           ; si = entry0
        lea     si, [si+E_NAME]
.nm:    mov al,[si]; or al,al; jz .nme
        mov [di],al; inc di; inc si; jmp .nm
.nme:
.noname:
        mov     word [di], 0A0Dh
        add     di, 2
        mov     cx, di
        sub     cx, linebuf
        mov     dx, linebuf
        mov     bx, [dumph]
        mov     ah, 40h
        int     21h
        ret
