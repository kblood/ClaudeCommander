; @feature LFN
; @title   LFN panel view (P_VIEW=2): long name + ext + size columns
; @cost    ~340
;
; mod/lfnview.inc  --  FEAT_LFN extension
; Adds P_VIEW=2: a single-column panel body view that queries WIN32_FIND_DATA
; via INT 21h AX=714Eh (LFN FindFirst) for every visible row and shows the long
; filename, a 4-char extension field, and a 7-char right-justified size field.
; Falls back to the 8.3 E_NAME when the LFN provider is absent (CF=1).
;
; Column layout ([pcw] = panel content width, 38 or 39):
;   [long name  pcw-13 chars]  [sp]  [4-char ext]  [sp]  [7-char size]
;    rowbuf[0..pcw-14]               rowbuf[pcw-12..pcw-9]  rowbuf[pcw-7..pcw-1]
;   The two single-space gaps are already spaces from clear_rowbuf.
;
; fix_scroll_lfn delegates to fix_scroll_full (single-column, same scroll logic).
; build_entry_path uses [active]; the active panel's LFN names are always correct.
;
; Registered as P_VIEW=2 in view_tab (mod/views.inc %ifdef FEAT_LFN block).
; Included from cc.asm inside %ifdef FEAT_LFN after mod/lfn.inc.

%ifdef FEAT_LFN

LFN_EXTW  equ 4          ; extension column width (chars, without dot)
LFN_SIZEW equ 7          ; size column width (chars, right-justified)
; total overhead: 1 gap + LFN_EXTW + 1 gap + LFN_SIZEW = 13
; name_width = pcw - 13

; ---------------------------------------------------------------------------
; Scroll for LFN view is identical to the full single-column view.
; ---------------------------------------------------------------------------
fix_scroll_lfn:
        jmp     fix_scroll_full

; ---------------------------------------------------------------------------
; Renderer for P_VIEW=2.  Entered from view_render with bx=panel,
; [ppanel] set, [pcx]/[pcw] = geometry.
; ---------------------------------------------------------------------------
draw_panel_lfn:
        mov     [ppanel], bx
        xor     bp, bp              ; bp = visible row index
.row:
        cmp     bp, VIS_ROWS
        jae     .done
        call    clear_rowbuf        ; pre-fill [pcw] spaces
        mov     bx, [ppanel]
        mov     ax, [bx+P_TOP]
        add     ax, bp
        cmp     ax, [bx+P_COUNT]
        jae     .blank
        push    ax
        call    entry_ptr           ; ax=index -> si = entry ptr
        push    si
        call    lfnv_format         ; si=entry -> rowbuf
        pop     si
        pop     ax
        call    pick_attr           ; ax=index -> al = attribute
        mov     [rattr], al
        jmp     .emit
.blank:
        mov     byte [rattr], A_NORM
.emit:
        push    bp
        mov     ax, FIRST_ROW
        add     ax, bp
        movzx   bx, byte [pcx]
        call    rc_to_off           ; ax=row,bx=col -> di
        mov     si, rowbuf
        movzx   cx, byte [pcw]
        mov     ah, [rattr]
        call    putbuf
        pop     bp
        inc     bp
        jmp     .row
.done:
        call    draw_info
        ret

; ---------------------------------------------------------------------------
; lfnv_format: si=entry -> fill rowbuf with LFN view columns.
; Uses build_entry_path (which uses [active]) to build the path, so LFN
; lookup is correct for the active panel; inactive panels fall back gracefully.
; Clobbers: ax, bx, cx, dx, di, si.  Does NOT modify bp (outer loop counter).
; ---------------------------------------------------------------------------
lfnv_format:

        ; --- 1. Build targpath via build_entry_path ---
        ; (build_entry_path uses [active]; caller uses [ppanel] but active is
        ;  always correct for the interactive panel and safe for inactive too.)
        push    si                  ; save entry ptr
        call    build_entry_path    ; si=entry -> targpath = panel-path + 8.3 name
        pop     si                  ; si = entry ptr

        ; --- 2. LFN FindFirst (INT 21h AX=714Eh) -> WIN32_FIND_DATA @ copybuf ---
        push    si                  ; save entry ptr across interrupt
        push    es
        push    ds
        pop     es                  ; es = ds: fill copybuf in our own segment
        xor     si, si              ; SI=0: request DOS date/time format
        mov     ax, 714Eh
        mov     cx, 0016h           ; match hidden/system/directory entries
        mov     dx, targpath        ; ds:dx = search spec (8.3 path)
        mov     di, copybuf         ; es:di = output buffer (WIN32_FIND_DATA)
        int     21h
        pop     es                  ; restore es
        pop     si                  ; si = entry ptr
        jc      .no_lfn             ; CF=1: no LFN provider or not found

        ; Close search handle (ax = handle from 714Eh)
        push    si
        mov     bx, ax              ; handle -> bx for 71A1h
        mov     ax, 71A1h
        int     21h
        pop     si                  ; si = entry ptr
        mov     dx, copybuf+44      ; dx -> cFileName (long name ASCIIZ)
        jmp     .have_name

.no_lfn:
        ; Fallback: use 8.3 name (E_NAME is at offset 0 in entry, so dx = si)
        mov     dx, si

        ; --- 3. Name field: rowbuf[0 .. pcw-14]  (pcw-13 chars) ---
.have_name:
        ; si = entry ptr, dx = name ASCIIZ source
        movzx   cx, byte [pcw]
        sub     cx, 13              ; cx = name_width = pcw - 13
        mov     di, rowbuf
        mov     bx, dx              ; bx = walking source ptr
.nl:    jcxz    .ndone
        mov     al, [bx]
        or      al, al
        jz      .ndone
        mov     [di], al
        inc     bx
        inc     di
        dec     cx
        jmp     .nl
.ndone:
        ; si = entry ptr, dx = name start (preserved)

        ; --- 4. Ext field: 4 chars at rowbuf[pcw-12]  (dirs -> blank) ---
        ; Space at rowbuf[pcw-13] already set by clear_rowbuf.
        test    byte [si+E_ATTR], 10h
        jnz     .ext_done           ; directory: ext field stays blank
        ; Find last '.' in dx string; cx = ptr to char after it, or 0 if none
        xor     cx, cx
        mov     bx, dx
.dscan: mov     al, [bx]
        or      al, al
        jz      .dfound
        cmp     al, '.'
        jne     .dnext
        lea     cx, [bx+1]          ; remember position just after this dot
.dnext: inc     bx
        jmp     .dscan
.dfound:
        or      cx, cx
        jz      .ext_done           ; no extension dot in name
        ; Write up to 4 ext chars to rowbuf at pcw-12
        movzx   di, byte [pcw]
        sub     di, 12
        add     di, rowbuf
        mov     bx, cx              ; bx = first ext char
        mov     cx, 4
.ecp:   jcxz    .ext_done
        mov     al, [bx]
        or      al, al
        jz      .ext_done
        mov     [di], al
        inc     bx
        inc     di
        dec     cx
        jmp     .ecp
.ext_done:

        ; --- 5. Size field: 7 chars right-justified at rowbuf[pcw-7] ---
        ; Space at rowbuf[pcw-8] already set by clear_rowbuf.
        ; ".." -> "<UP>", dir -> "<DIR>", file -> fmt_size
        mov     al, [si+E_NAME]
        cmp     al, '.'
        jne     .sz_chkdir
        cmp     byte [si+E_NAME+1], '.'
        jne     .sz_chkdir
        mov     bx, str_up
        jmp     .sz_label
.sz_chkdir:
        test    byte [si+E_ATTR], 10h
        jz      .sz_num
        mov     bx, str_dir
        ; fall through to .sz_label

.sz_label:
        ; Right-justify bx string in LFN_SIZEW=7 chars
        push    bx                  ; save label ptr
        mov     si, bx
        call    strlen              ; ax = len, si preserved (= label ptr)
        movzx   di, byte [pcw]
        sub     di, LFN_SIZEW
        add     di, rowbuf          ; di -> size field base
        mov     cx, LFN_SIZEW
        sub     cx, ax              ; cx = leading spaces before label
        add     di, cx
        pop     si                  ; si = label string
.sl_lp: mov     al, [si]
        or      al, al
        jz      .sz_done
        mov     [di], al
        inc     di
        inc     si
        jmp     .sl_lp

.sz_num:
        ; File: right-justify fmt_size output in LFN_SIZEW=7 chars
        mov     ax, [si+E_SIZE]
        mov     dx, [si+E_SIZE+2]
        push    si                  ; save entry ptr (fmt_size clobbers si)
        call    fmt_size            ; dx:ax -> si=numbuf_start, cx=length
        movzx   di, byte [pcw]
        sub     di, LFN_SIZEW
        add     di, rowbuf
        mov     bx, LFN_SIZEW
        sub     bx, cx              ; leading spaces count
        add     di, bx
.nc:    mov     al, [si]
        or      al, al
        jz      .nc_done
        mov     [di], al
        inc     di
        inc     si
        jmp     .nc
.nc_done:
        pop     si                  ; restore entry ptr

.sz_done:
        ret

%endif  ; FEAT_LFN
