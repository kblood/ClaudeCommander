; mod/views.inc  --  FEAT_VIEWS
; Panel BODY view modes. The panel body is treated as a swappable "body widget"
; selected by P_VIEW (0 = full list, 1 = brief 3-column names-only). The contract
; a body view implements is two things: a RENDERER (draw_panel dispatches here for
; brief) and NAVIGATION (the page/column step + scroll-to-keep-cursor-visible).
; Up/Down stay +/-1 in every view; only the page/column steps and the scroll
; window differ, so the core nav handlers query view_pagestep / view_winspan and
; defer cursor-visibility to fix_scroll (which trampolines to fix_scroll_brief).
;
; This is the keystone the future tree-view reuses: another P_VIEW value with its
; own renderer + nav step, behind this same draw+nav seam -- the core list code
; never special-cases a view beyond the P_VIEW dispatch points.
;
; Toggle: Ctrl-F10 (key_view_toggle). Default view is full (set in init_panel_cwd).

BRIEF_COLS  equ 3              ; columns in the brief view
BRIEF_PITCH equ 13             ; column-to-column step; cells tile (no gutter gap)

; bx = panel -> ax = entries the Page keys move. Full view keeps the classic
; one-row overlap; brief view pages a whole 3-column screen. (Clobbers ax only.)
view_pagestep:
        mov     ax, VIS_ROWS-1
        cmp     byte [bx+P_VIEW], 1
        jne     .ret
        mov     ax, VIS_ROWS*BRIEF_COLS
.ret:
        ret

; ---------------------------------------------------------------------------
; Brief-view scroll: P_TOP is kept a multiple of VIS_ROWS so every column is a
; clean block of VIS_ROWS entries, and the cursor's column is held within the
; 3 visible columns [topcol .. topcol+2].  bx = panel.
fix_scroll_brief:
        push    ax
        push    cx
        push    dx
        push    si
        ; curcol = P_CUR / VIS_ROWS
        mov     ax, [bx+P_CUR]
        xor     dx, dx
        mov     cx, VIS_ROWS
        div     cx                  ; ax = curcol
        mov     si, ax              ; si = curcol
        ; topcol = P_TOP / VIS_ROWS
        mov     ax, [bx+P_TOP]
        xor     dx, dx
        mov     cx, VIS_ROWS
        div     cx                  ; ax = topcol
        cmp     si, ax
        jae     .chkhi
        mov     ax, si              ; curcol < topcol -> topcol = curcol
        jmp     .settop
.chkhi:
        mov     dx, ax
        add     dx, BRIEF_COLS-1    ; topcol + 2
        cmp     si, dx
        jbe     .settop
        mov     ax, si
        sub     ax, BRIEF_COLS-1    ; curcol > topcol+2 -> topcol = curcol-2
.settop:
        mov     cx, VIS_ROWS
        mul     cx                  ; ax = topcol * VIS_ROWS
        mov     [bx+P_TOP], ax
        pop     si
        pop     dx
        pop     cx
        pop     ax
        ret

; ---------------------------------------------------------------------------
; Left/Right become view-aware: a column move in brief, a page move in full.
key_left:
        mov     bx, [active]
        cmp     byte [bx+P_VIEW], 1
        jne     key_pgup            ; full view: Left = page up
        mov     ax, [bx+P_CUR]
        sub     ax, VIS_ROWS        ; brief: one column left
        jns     .ok
        xor     ax, ax
.ok:
        mov     [bx+P_CUR], ax
        call    fix_scroll
        ret

key_right:
        mov     bx, [active]
        cmp     byte [bx+P_VIEW], 1
        jne     key_pgdn            ; full view: Right = page down
        mov     cx, [bx+P_COUNT]
        jcxz    .done
        mov     ax, [bx+P_CUR]
        add     ax, VIS_ROWS        ; brief: one column right
        cmp     ax, cx
        jb      .ok
        mov     ax, cx
        dec     ax
.ok:
        mov     [bx+P_CUR], ax
        call    fix_scroll
.done:
        ret

; ---------------------------------------------------------------------------
; Ctrl-F10: flip the active panel between full and brief, then re-snap scroll.
key_view_toggle:
        mov     bx, [active]
        mov     al, [bx+P_VIEW]
        xor     al, 1
        mov     [bx+P_VIEW], al
        call    fix_scroll          ; brief snaps P_TOP to a column block
        ret

; ---------------------------------------------------------------------------
; Brief renderer: 3 columns of names only, filled column-major from P_TOP
; (col0 = TOP..TOP+20, col1 = TOP+21..TOP+41, col2 = TOP+42..TOP+62). Cells
; tile across the full body width (cols 0,1 = PITCH wide, col 2 takes the
; remainder), so every row is fully repainted -- no separate clear pass and
; no stale glyphs between columns. Entered from draw_panel with [ppanel]=bx,
; [pcx]/[pcw] = this panel's geometry.
draw_panel_brief:
        mov     [ppanel], bx
        xor     bp, bp              ; bp = slot 0..(VIS_ROWS*BRIEF_COLS - 1)
.slot:
        cmp     bp, VIS_ROWS*BRIEF_COLS
        jae     .done
        ; col = slot / VIS_ROWS ; row = slot % VIS_ROWS
        mov     ax, bp
        xor     dx, dx
        mov     cx, VIS_ROWS
        div     cx
        mov     [brief_col], ax
        mov     [brief_row], dx
        ; cell width: cols 0,1 = PITCH; last col gets pcw - 2*PITCH
        movzx   cx, byte [pcw]
        cmp     ax, BRIEF_COLS-1
        jb      .havew
        sub     cx, (BRIEF_COLS-1)*BRIEF_PITCH
.havew:
        mov     [brief_cw], cx
        ; entry index = TOP + slot
        mov     bx, [ppanel]
        mov     ax, [bx+P_TOP]
        add     ax, bp
        cmp     ax, [bx+P_COUNT]
        jae     .blank
        push    ax                  ; entry index (for pick_attr)
        call    entry_ptr           ; ax=index -> si
        mov     cx, [brief_cw]
        call    brief_name          ; si,cx -> rowbuf = name padded to cx
        pop     ax
        call    pick_attr           ; ax=index -> al = attribute
        mov     [rattr], al
        jmp     .emit
.blank:
        mov     cx, [brief_cw]
        call    brief_pad           ; rowbuf = cx spaces
        mov     byte [rattr], A_NORM
.emit:
        ; di = (FIRST_ROW+row)*ROW_BYTES + (pcx + col*PITCH)*2
        mov     ax, [brief_row]
        add     ax, FIRST_ROW
        mov     cx, ROW_BYTES
        mul     cx                  ; row*ROW_BYTES (fits 16 bits)
        mov     di, ax
        mov     ax, [brief_col]
        mov     cx, BRIEF_PITCH
        mul     cx                  ; col*pitch
        movzx   bx, byte [pcx]
        add     ax, bx              ; + content x
        shl     ax, 1               ; *2 -> byte offset
        add     di, ax
        mov     si, rowbuf
        mov     cx, [brief_cw]
        mov     ah, [rattr]
        call    putbuf
        inc     bp
        jmp     .slot
.done:
        call    draw_info
        ret

; si = entry ptr, cx = field width -> rowbuf = name, space-padded to cx (no NUL).
; Clobbers ax, cx, di, si (preserves bp, which the caller loops on).
brief_name:
        push    cx
        push    si
        mov     di, rowbuf
        mov     al, ' '
        rep     stosb               ; cx spaces
        pop     si
        pop     cx
        lea     si, [si+E_NAME]
        mov     di, rowbuf
.cp:
        mov     al, [si]
        or      al, al
        jz      .d
        movsb                       ; copy a name char, advance si/di
        loop    .cp
.d:
        ret

; cx = field width -> rowbuf = cx spaces. Clobbers ax, di.
brief_pad:
        mov     di, rowbuf
        mov     al, ' '
        rep     stosb
        ret
