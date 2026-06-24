; @feature VIEWS
; @title   panel body view modes (brief 3-column; Ctrl-F10)
; @cost    415
;
; mod/views.inc  --  FEAT_VIEWS
; Panel BODY view modes, as a small REGISTRY of body widgets. The panel body is
; a swappable widget selected by P_VIEW; each view registers one row in view_tab
; giving its renderer, its scroll-keep-visible routine, and two nav step sizes.
; The core list/nav code (draw_panel, fix_scroll, key_pgup/pgdn/left/right) holds
; NO per-view logic -- it dispatches through the table. Adding a view (the coming
; tree-view, or any future one) = add a row here + its two routines; core never
; changes. Up/Down stay +/-1 in every view (no table entry needed).
;
;   view_tab row (VDSIZE bytes):
;     VD_RENDER  dw  renderer(bx=panel)      -- draw the body
;     VD_SCROLL  dw  fixscroll(bx=panel)     -- keep the cursor visible
;     VD_PAGE    dw  entries moved by PgUp/PgDn
;     VD_HSTEP   dw  entries moved by Left/Right
;
; Toggle: Ctrl-F10 (key_view_toggle) cycles through the registered views.
; Default view is full / P_VIEW=0 (set in init_panel_cwd).

VD_RENDER   equ 0
VD_SCROLL   equ 2
VD_PAGE     equ 4
VD_HSTEP    equ 6
VDSIZE      equ 8
VIEW_COUNT  equ 2              ; full(0), brief(1)   [tree(2) registers later]

BRIEF_COLS  equ 3              ; columns in the brief view
BRIEF_PITCH equ 13             ; column-to-column step; cells tile (no gutter gap)

; --- the registry -----------------------------------------------------------
view_tab:
        ; P_VIEW=0 : full single-column list
        dw      draw_panel_full, fix_scroll_full, VIS_ROWS-1, VIS_ROWS-1
        ; P_VIEW=1 : brief 3-column names-only
        dw      draw_panel_brief, fix_scroll_brief, VIS_ROWS*BRIEF_COLS, VIS_ROWS

; --- dispatch helpers --------------------------------------------------------
; bx = panel, cl = VD_* field -> ax = that descriptor word (value or fn ptr).
; Preserves bx; clobbers ax.
view_word:
        push    bx
        mov     al, [bx+P_VIEW]
        mov     ah, VDSIZE
        mul     ah                  ; ax = P_VIEW * VDSIZE
        movzx   bx, cl
        add     bx, ax              ; + field offset
        mov     ax, [view_tab+bx]
        pop     bx
        ret

; bx = panel : tail-call the active view's renderer (entered from draw_panel).
view_render:
        mov     cl, VD_RENDER
        call    view_word
        jmp     ax

; bx = panel : tail-call the active view's scroll routine (from fix_scroll).
view_fixscroll:
        mov     cl, VD_SCROLL
        call    view_word
        jmp     ax

; --- table-driven Left/Right -------------------------------------------------
; Left/Right move by VD_HSTEP entries (full view: a page; brief: one column).
key_left:
        mov     bx, [active]
        mov     cl, VD_HSTEP
        call    view_word           ; ax = horizontal step
        mov     cx, ax
        mov     ax, [bx+P_CUR]
        sub     ax, cx
        jns     .ok
        xor     ax, ax
.ok:
        mov     [bx+P_CUR], ax
        call    fix_scroll
        ret

key_right:
        mov     bx, [active]
        mov     cx, [bx+P_COUNT]
        jcxz    .done
        mov     cl, VD_HSTEP
        call    view_word           ; ax = horizontal step
        mov     dx, ax
        mov     ax, [bx+P_CUR]
        add     ax, dx
        mov     cx, [bx+P_COUNT]
        cmp     ax, cx
        jb      .ok
        mov     ax, cx
        dec     ax
.ok:
        mov     [bx+P_CUR], ax
        call    fix_scroll
.done:
        ret

; --- Ctrl-F10: cycle the active panel through the registered views ----------
key_view_toggle:
        mov     bx, [active]
        mov     al, [bx+P_VIEW]
        inc     al
        cmp     al, VIEW_COUNT
        jb      .set
        xor     al, al
.set:
        mov     [bx+P_VIEW], al
        call    fix_scroll          ; let the new view re-snap P_TOP
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
