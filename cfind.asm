; ============================================================================
;  CCFIND.COM  --  Claude Commander's external file finder (Layer 3 helper)
;
;  Usage:  CCFIND <pattern> [startdir]
;          CCFIND *.TXT C:\          -> every *.TXT under C:\ (full paths)
;          CCFIND readme*            -> search the current directory tree
;
;  Walks the directory tree breadth-first using a queue of pending directories
;  (one DTA, no recursion), printing the full path of every FILE whose name
;  matches <pattern> (case-insensitive, * and ?).  Prints to stdout so callers
;  can redirect:  CCFIND *.BAK C:\ > HITS.TXT
;
;  Assemble:  nasm -f bin cfind.asm -o ccfind.com
; ============================================================================
        org     100h

QMAX    equ 16384               ; directory-queue byte budget

start:
        cld
        mov     sp, stacktop
        call    parse_tail          ; -> pattern, startdir (default ".")
        call    probe_lfn           ; detect LFN support
        ; seed the queue with the start directory
        mov     word [qhead], qbuf
        mov     word [qtail], qbuf
        mov     si, startdir
        call    enqueue
.next:
        call    dequeue             ; curpath = next dir; CF=1 -> queue empty
        jc      .done
        call    scan_dir
        jmp     .next
.done:
        mov     ax, 4C00h
        int     21h

; ----------------------------------------------------------------------------
; parse PSP tail: first token -> pattern, second token -> startdir ("." if none)
parse_tail:
        movzx   cx, byte [80h]
        mov     si, 81h
        mov     di, pattern
        call    .skipsp
        call    .copytok            ; -> pattern
        mov     di, startdir
        call    .skipsp
        call    .copytok            ; -> startdir (may be empty)
        cmp     byte [startdir], 0
        jne     .ret
        mov     word [startdir], '.' ; default = current dir (".",0 via low byte)
        mov     byte [startdir+1], 0
.ret:
        ret
.skipsp:
        jcxz    .sd
        cmp     byte [si], ' '
        jne     .sd
        inc     si
        dec     cx
        jmp     .skipsp
.sd:    ret
.copytok:
        jcxz    .cd
        mov     al, [si]
        cmp     al, ' '
        je      .cd
        mov     [di], al
        inc     di
        inc     si
        dec     cx
        jmp     .copytok
.cd:    mov     byte [di], 0
        ret

; ----------------------------------------------------------------------------
; scan_dir: list [curpath], print matching files, enqueue subdirectories.
scan_dir:
        cmp     byte [lfn_avail], 1
        je      scan_dir_lfn
        mov     dx, dta
        mov     ah, 1Ah
        int     21h                 ; set DTA
        call    build_search        ; srchbuf = curpath + "\*.*"
        mov     ah, 4Eh
        mov     cx, 10h             ; include directories
        mov     dx, srchbuf
        int     21h
        jc      .ret
.loop:
        mov     bx, dta
        cmp     byte [bx+30], '.'   ; skip "." and ".."
        je      .next
        test    byte [bx+21], 10h
        jnz     .dir
        ; file: matches the pattern?
        mov     si, pattern
        lea     di, [bx+30]
        call    wildmatch
        jnc     .next
        call    print_match
        jmp     .next
.dir:
        call    enqueue_child
.next:
        mov     ah, 4Fh             ; FindNext (uses DTA)
        int     21h
        jnc     .loop
.ret:
        ret

; build srchbuf = curpath + "\*.*"  (no double slash on a root path)
build_search:
        mov     si, curpath
        mov     di, srchbuf
        call    catz_di
        cmp     byte [di-1], '\'
        je      .star
        mov     byte [di], '\'
        inc     di
.star:
        mov     si, s_star
        call    catz_di
        mov     byte [di], 0
        ret

; print curpath + "\" + DTA-name + CRLF to stdout
print_match:
        mov     si, curpath
        mov     di, linebuf
        call    catz_di
        cmp     byte [di-1], '\'
        je      .nm
        mov     byte [di], '\'
        inc     di
.nm:
        mov     bx, dta
        lea     si, [bx+30]
        call    catz_di
        mov     word [di], 0A0Dh    ; CRLF
        add     di, 2
        mov     cx, di
        sub     cx, linebuf
        mov     ah, 40h
        mov     bx, 1               ; stdout
        mov     dx, linebuf
        int     21h
        ret

; enqueue curpath + "\" + DTA-name
enqueue_child:
        mov     si, curpath
        mov     di, tmppath
        call    catz_di
        cmp     byte [di-1], '\'
        je      .nm
        mov     byte [di], '\'
        inc     di
.nm:
        mov     bx, dta
        lea     si, [bx+30]
        call    catz_di
        mov     byte [di], 0
        mov     si, tmppath
        call    enqueue
        ret

; copy ASCIIZ ds:si -> [di] without the NUL; di advanced. (al clobbered)
catz_di:
        mov     al, [si]
        or      al, al
        jz      .d
        mov     [di], al
        inc     si
        inc     di
        jmp     catz_di
.d:     ret

; ----------------------------------------------------------------------------
; enqueue(si=ASCIIZ): append to the directory queue (drops on overflow).
enqueue:
        mov     di, [qtail]
        push    si
        push    di
.len:
        cmp     byte [si], 0
        je      .have
        inc     si
        jmp     .len
.have:
        sub     si, [qtail]         ; si = string length
        mov     ax, di
        add     ax, si
        inc     ax                  ; room for NUL
        cmp     ax, qbuf+QMAX
        pop     di
        pop     si
        ja      .ret                ; overflow -> silently drop
.cp:
        mov     al, [si]
        mov     [di], al
        inc     si
        inc     di
        or      al, al
        jnz     .cp
        mov     [qtail], di
.ret:
        ret

; dequeue -> curpath = next dir; CF=1 if queue empty.
dequeue:
        mov     si, [qhead]
        cmp     si, [qtail]
        jae     .empty
        mov     di, curpath
.cp:
        mov     al, [si]
        mov     [di], al
        inc     si
        inc     di
        or      al, al
        jnz     .cp
        mov     [qhead], si
        clc
        ret
.empty:
        stc
        ret

; ----------------------------------------------------------------------------
; wildmatch: si = pattern (ASCIIZ), di = text (ASCIIZ).  CF=1 on match.
; Case-insensitive, '*' and '?', iterative single-star backtracking.
wildmatch:
        push    bp
        xor     bx, bx
.wl:
        mov     ah, [di]
        or      ah, ah
        jz      .send
        mov     al, [si]
        cmp     al, '?'
        je      .m1
        mov     cl, al
        and     cl, 0DFh
        mov     ch, ah
        and     ch, 0DFh
        cmp     cl, ch
        je      .m1
        cmp     al, '*'
        je      .star
        or      bx, bx
        jz      .no
        mov     si, bx
        inc     dx
        mov     di, dx
        jmp     .wl
.m1:
        inc     si
        inc     di
        jmp     .wl
.star:
        inc     si
        mov     bx, si
        mov     dx, di
        jmp     .wl
.send:
        cmp     byte [si], '*'
        jne     .chk
        inc     si
        jmp     .send
.chk:
        cmp     byte [si], 0
        jne     .no
        pop     bp
        stc
        ret
.no:
        pop     bp
        clc
        ret

; ----------------------------------------------------------------------------
; probe_lfn: call INT 21h/714Eh on "."; set lfn_avail=1 if CF=0, else 0.
probe_lfn:
        push    ds
        pop     es
        mov     ax, 714Eh
        mov     cx, 10h
        xor     bx, bx
        mov     dx, s_dot
        mov     di, wfd
        int     21h
        jc      .no
        mov     byte [lfn_avail], 1
        mov     bx, ax              ; handle from 714Eh
        mov     ax, 71A1h
        int     21h
        ret
.no:
        mov     byte [lfn_avail], 0
        ret

; scan_dir_lfn: enumerate curpath using LFN FindFirst/FindNext (714Eh/714Fh).
; Prints the long filename (WIN32_FIND_DATA+44) for matched files.
scan_dir_lfn:
        call    build_search        ; srchbuf = curpath + "\*.*"
        push    ds
        pop     es
        mov     ax, 714Eh
        mov     cx, 10h             ; include directories
        xor     bx, bx
        mov     dx, srchbuf
        mov     di, wfd
        int     21h
        jc      .ret
        mov     [lfn_handle], ax
.loop:
        cmp     byte [wfd+44], '.'  ; skip "." and ".."
        je      .next
        test    byte [wfd], 10h     ; dwFileAttributes bit 4 = directory
        jnz     .dir
        ; file: wildmatch against the long name
        mov     si, pattern
        mov     di, wfd+44
        call    wildmatch
        jnc     .next
        ; print: curpath + "\" + long name + CRLF
        mov     si, curpath
        mov     di, linebuf
        call    catz_di
        cmp     byte [di-1], '\'
        je      .pnm
        mov     byte [di], '\'
        inc     di
.pnm:
        mov     si, wfd+44
        call    catz_di
        mov     word [di], 0A0Dh
        add     di, 2
        mov     cx, di
        sub     cx, linebuf
        mov     ah, 40h
        mov     bx, 1               ; stdout
        mov     dx, linebuf
        int     21h
        jmp     .next
.dir:
        ; enqueue: curpath + "\" + long directory name
        mov     si, curpath
        mov     di, tmppath
        call    catz_di
        cmp     byte [di-1], '\'
        je      .enm
        mov     byte [di], '\'
        inc     di
.enm:
        mov     si, wfd+44
        call    catz_di
        mov     byte [di], 0
        mov     si, tmppath
        call    enqueue
.next:
        push    ds
        pop     es
        mov     ax, 714Fh
        mov     bx, [lfn_handle]
        mov     di, wfd
        int     21h
        jnc     .loop
        mov     ax, 71A1h
        mov     bx, [lfn_handle]
        int     21h
.ret:
        ret

; ============================================================================
s_star      db '*.*',0
s_dot       db '.',0

section .bss
align 2
pattern     resb 16
startdir    resb 80
curpath     resb 300            ; enlarged: LFN directory names up to ~255 chars
tmppath     resb 400            ; enlarged: curpath + "\" + LFN child name
srchbuf     resb 300            ; enlarged for LFN paths
linebuf     resb 400            ; enlarged: curpath + "\" + LFN (260) + CRLF
dta         resb 64
lfn_avail   resb 1              ; 1 if INT 21h/714Eh is supported, else 0
lfn_handle  resw 1              ; handle returned by 714Eh
wfd         resb 318            ; WIN32_FIND_DATA; long name at offset +44
qhead       resw 1
qtail       resw 1
qbuf        resb QMAX
stackspace  resb 1024
stacktop:
