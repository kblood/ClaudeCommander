; @feature FREE
; @title   panel footer: file count / free space / tagged size
; @needs   WIDGETS
; @cost    385
;
; mod/free.inc  --  FEAT_FREE
; File-count + free-space footer drawn into each panel's bottom frame border.
; Hooked from render_all AFTER draw_frames (so it overwrites the plain border
; line with " <n> Files  <kb>K free ", centered in each panel's bottom edge).
; Scratch buffer footbuf lives in cc.asm's .bss block (gated on FEAT_FREE).

draw_foot:
        push    es
        push    bp
        mov     ax, [vseg]
        mov     es, ax
        mov     bx, panelL
        mov     cx, L_CONX
        mov     dx, L_CONW
        call    foot_one
        mov     bx, panelR
        mov     cx, R_CONX
        mov     dx, R_CONW
        call    foot_one
        pop     bp
        pop     es
        ret

; Draw one panel's footer.  bx=panel ptr, cx=content x, dx=content width.
; es=VIDEO on entry.
foot_one:
        push    cx                  ; save content x
        push    dx                  ; save content width
        ; ---- build the footer text into footbuf ----
        mov     di, footbuf
        mov     byte [di], ' '      ; leading pad against the frame line
        inc     di
        ; When files are tagged, the total SIZE of the selection is more useful
        ; than free space, so show "<n> selected  <bytes> bytes" instead.
        push    bx
        call    foot_tagged         ; ax = count of E_ATTR bit-0x40 entries
        pop     bx
        or      ax, ax
        jnz     .selected
        ; ---- default: "<count> Files  <free>K free" ----
        mov     ax, [bx+P_COUNT]
        xor     dx, dx
        push    bx
        call    foot_num
        mov     si, txt_files
        call    foot_str
        pop     bx
        call    foot_freekb         ; dx:ax = free KB on this panel's drive
        call    foot_num
        mov     si, txt_kfree
        call    foot_str            ; ends with a trailing pad space
        jmp     .center
.selected:
        ; ---- "<n> selected  <bytes> bytes" ----
        xor     dx, dx              ; ax still = tagged count
        push    bx
        call    foot_num
        mov     si, txt_seld
        call    foot_str
        pop     bx
        push    bx
        call    foot_taggedsize     ; dx:ax = summed E_SIZE of tagged entries
        call    foot_num
        mov     si, txt_bytes
        call    foot_str            ; ends with a trailing pad space
        pop     bx
.center:
        ; ---- center it in the bottom border ----
        mov     ax, di
        sub     ax, footbuf         ; ax = length
        pop     dx                  ; content width
        pop     cx                  ; content x
        mov     bx, dx
        sub     bx, 2               ; max drawable = width-2 (keep the corners)
        cmp     ax, bx
        jbe     .lenok
        mov     ax, bx
.lenok:
        mov     bp, ax              ; bp = chars to draw
        mov     ax, dx
        sub     ax, bp              ; width - len
        shr     ax, 1               ; /2 -> left offset
        add     ax, cx              ; + content x = start column
        shl     ax, 1               ; col*2
        mov     di, BOT_ROW*ROW_BYTES
        add     di, ax
        mov     si, footbuf
        mov     ah, A_FRAME
        mov     cx, bp
.wr:
        lodsb
        mov     [es:di], al
        mov     [es:di+1], ah
        add     di, 2
        loop    .wr
        ret

; dx:ax = unsigned value -> append decimal digits at [di], di advanced.
foot_num:
        call    u32toa              ; si=first digit, cx=len, di preserved
.cp:
        lodsb
        mov     [di], al
        inc     di
        loop    .cp
        ret

; si = ASCIIZ -> append (without the NUL) at [di], di advanced.
foot_str:
        lodsb
        or      al, al
        jz      .done
        mov     [di], al
        inc     di
        jmp     foot_str
.done:
        ret

; bx = panel ptr -> dx:ax = free space in KB on that panel's drive.
; Uses INT 21h AH=36h.  KB/cluster = (sec/clu * bytes/sec) >> 10, then
; * available clusters.  Stays within 32 bits for any normal DOS volume.
foot_freekb:
        push    bx
        push    si
        mov     al, [bx+P_PATH]     ; drive letter from the path
        and     al, 0DFh            ; uppercase
        sub     al, 'A'-1           ; 'A' -> 1
        mov     dl, al
        mov     ah, 36h
        int     21h                 ; ax=sec/clu bx=avail cx=bytes/sec dx=clu/drv
        cmp     ax, 0FFFFh          ; invalid drive?
        je      .zero
        push    bx                  ; save available clusters
        mul     cx                  ; dx:ax = sec/clu * bytes/sec (bytes/cluster)
        mov     cx, 10              ; >>10 -> KB per cluster
.sh:
        shr     dx, 1
        rcr     ax, 1
        loop    .sh
        pop     cx                  ; available clusters
        mul     cx                  ; dx:ax = KB/clu * avail = free KB
        jmp     .ret
.zero:
        xor     ax, ax
        xor     dx, dx
.ret:
        pop     si
        pop     bx
        ret

; bx = panel ptr -> dx:ax = summed E_SIZE (bytes) of all tagged entries.
foot_taggedsize:
        push    bx
        push    cx
        push    si
        mov     cx, [bx+P_COUNT]
        xor     ax, ax
        xor     dx, dx
        jcxz    .d
        lea     si, [bx+P_ENTRIES]
.l:
        test    byte [si+E_ATTR], 40h
        jz      .n
        add     ax, [si+E_SIZE]
        adc     dx, [si+E_SIZE+2]
.n:
        add     si, ENTSIZE
        loop    .l
.d:
        pop     si
        pop     cx
        pop     bx
        ret

; bx = panel ptr -> ax = number of tagged entries (E_ATTR bit 0x40).
foot_tagged:
        push    bx
        push    cx
        push    si
        mov     cx, [bx+P_COUNT]
        xor     ax, ax
        jcxz    .d
        lea     si, [bx+P_ENTRIES]
.l:
        test    byte [si+E_ATTR], 40h
        jz      .n
        inc     ax
.n:
        add     si, ENTSIZE
        loop    .l
.d:
        pop     si
        pop     cx
        pop     bx
        ret

txt_files   db ' Files  ',0
txt_seld    db ' selected  ',0
txt_bytes   db ' bytes ',0
txt_kfree   db 'K free ',0
