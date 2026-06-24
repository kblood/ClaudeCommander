; @feature MASK
; @title   tag/untag files by *.mask (Ctrl-F7/F8)
; @cost    210
;
; mod/mask.inc  --  FEAT_MASK
; Select / deselect a group of files by wildcard (Norton "Gray +/-").  Bound to
; Ctrl-F7 (select) and Ctrl-F8 (deselect): prompt for a pattern like "*.TXT",
; then tag (or untag) every matching FILE in the active panel via the existing
; E_ATTR bit-0x40 tag flag.  Directories are never matched.

key_mask_sel:
        mov     byte [mask_set], 1
        jmp     mask_common
key_mask_unsel:
        mov     byte [mask_set], 0
mask_common:
        mov     si, s_mask
        call    dlg_input               ; -> dlgbuf (ASCIIZ), CF=1 if cancelled
        jc      .ret
        cmp     byte [dlgbuf], 0        ; empty pattern -> nothing
        je      .ret
        mov     ax, [active]
        mov     [ppanel], ax            ; entry_ptr reads [ppanel]
        mov     bx, ax
        mov     cx, [bx+P_COUNT]
        jcxz    .ret
        xor     bp, bp                  ; entry index
.scan:
        cmp     bp, cx
        jae     .ret
        push    cx
        push    bp
        mov     ax, bp
        call    entry_ptr               ; -> si = entry ptr (name at si)
        test    byte [si+E_ATTR], 10h
        jnz     .next                   ; skip directories
        mov     di, si                  ; di = text (the name)
        push    si
        mov     si, dlgbuf              ; si = pattern
        call    wildmatch               ; CF=1 if match
        pop     si
        jnc     .next
        cmp     byte [mask_set], 0
        je      .clr
        or      byte [si+E_ATTR], 40h   ; tag
        jmp     .next
.clr:
        and     byte [si+E_ATTR], 0BFh  ; untag
.next:
        pop     bp
        pop     cx
        inc     bp
        jmp     .scan
.ret:
        ret

; ----------------------------------------------------------------------------
; wildmatch: si = pattern (ASCIIZ), di = text (ASCIIZ).  Case-insensitive,
; supports '*' and '?'.  Returns CF=1 on match, CF=0 otherwise.  Iterative
; single-star backtracking (no recursion).  Clobbers ax/bx/cx/dx/si/di.
; ----------------------------------------------------------------------------
wildmatch:
        push    bp
        xor     bx, bx                  ; bx = star+1 pattern ptr (0 = no star yet)
.wl:
        mov     ah, [di]                ; *s
        or      ah, ah
        jz      .send                   ; text exhausted
        mov     al, [si]                ; *p
        cmp     al, '?'
        je      .m1
        mov     cl, al
        and     cl, 0DFh                ; rough uppercase
        mov     ch, ah
        and     ch, 0DFh
        cmp     cl, ch
        je      .m1
        cmp     al, '*'
        je      .star
        or      bx, bx                  ; mismatch: backtrack to last star?
        jz      .no
        mov     si, bx                  ; p = star+1
        inc     dx                      ; ss++
        mov     di, dx                  ; s = ss
        jmp     .wl
.m1:
        inc     si
        inc     di
        jmp     .wl
.star:
        inc     si                      ; skip '*'
        mov     bx, si                  ; remember pattern after star
        mov     dx, di                  ; remember text position
        jmp     .wl
.send:
        cmp     byte [si], '*'          ; skip trailing stars
        jne     .chk
        inc     si
        jmp     .send
.chk:
        cmp     byte [si], 0            ; matched iff pattern also exhausted
        jne     .no
        pop     bp
        stc
        ret
.no:
        pop     bp
        clc
        ret

s_mask      db 'Tag files matching (e.g. *.TXT):',0
