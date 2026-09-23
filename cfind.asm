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
PATHMAX equ 259                 ; longest directory path that is queued

start:
        cld
        mov     sp, stacktop
        call    parse_tail          ; -> pattern, startdir (default ".")
        call    probe_lfn           ; detect LFN support
        ; seed the queue with the start directory
        mov     word [qhead], qbuf
        mov     word [qtail], qbuf
        mov     byte [qskip], 0
        mov     si, startdir
        call    enqueue
.next:
        call    dequeue             ; curpath = next dir; CF=1 -> queue empty
        jc      .done
        call    scan_dir
        jmp     .next
.done:
        ; dirs dropped (queue full / path too long)? Say so on STDERR only:
        ; cc parses every stdout line of FINDOUT.TXT as a found path.
        cmp     byte [qskip], 0
        je      .x
        mov     ah, 40h
        mov     bx, 2               ; stderr
        mov     cx, s_skip_len
        mov     dx, s_skip
        int     21h
.x:
        mov     ax, 4C00h
        int     21h

; ----------------------------------------------------------------------------
; parse PSP tail: first token -> pattern, second token -> startdir ("." if none)
parse_tail:
        movzx   cx, byte [80h]
        cmp     cx, 127             ; tail can't exceed 127 bytes (PSP:81h-FFh);
        jbe     .tl                 ; clamp so no token outgrows its 128-byte buffer
        mov     cx, 127
.tl:
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
        cmp     al, 0Dh             ; CR ends the tail
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
; enqueue(si=ASCIIZ): append to the directory queue.  When the tail would run
; off the end, the already-dequeued head space is reclaimed by sliding the
; pending entries down to qbuf.  A path that still doesn't fit (or is longer
; than PATHMAX, so it could not be extended safely) is dropped and flagged in
; qskip.
enqueue:
        push    si
        mov     di, si
.len:
        cmp     byte [di], 0
        je      .have
        inc     di
        jmp     .len
.have:
        sub     di, si              ; di = string length
        cmp     di, PATHMAX
        ja      .drop
        mov     ax, [qtail]
        add     ax, di
        inc     ax                  ; room for NUL
        cmp     ax, qbuf+QMAX
        jbe     .fits
        push    di                  ; compact: [qhead,qtail) -> qbuf
        mov     si, [qhead]
        mov     cx, [qtail]
        sub     cx, si
        mov     di, qbuf
        rep     movsb               ; dest < src, forward copy is safe
        mov     word [qhead], qbuf
        mov     [qtail], di
        pop     ax
        add     ax, di
        inc     ax
        cmp     ax, qbuf+QMAX
        ja      .drop
.fits:
        pop     si
        mov     di, [qtail]
.cp:
        mov     al, [si]
        mov     [di], al
        inc     si
        inc     di
        or      al, al
        jnz     .cp
        mov     [qtail], di
        ret
.drop:
        pop     si
        mov     byte [qskip], 1
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
; DOS semantics: a trailing "." / ".*" in the pattern also matches a name
; with no extension, so "*.*" finds README and MAKEFILE.
wildmatch:
        push    bp
        mov     bp, di              ; bp = start of text (for the no-dot test)
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
        je      .yes
        cmp     byte [si], '.'      ; pattern left = "." + stars only, and
        jne     .no                 ; the name has no dot -> extensionless hit
.nodot:
        cmp     byte [bp], 0
        je      .dotend
        cmp     byte [bp], '.'
        je      .no
        inc     bp
        jmp     .nodot
.dotend:
        inc     si
.dstar:
        cmp     byte [si], '*'
        jne     .dchk
        inc     si
        jmp     .dstar
.dchk:
        cmp     byte [si], 0
        jne     .no
.yes:
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
        stc                         ; pre-DOS 7 leaves CF unchanged on AH=71h
        int     21h
        jc      .no
        cmp     ax, 7100h           ; ...and returns AX=7100h: not supported
        je      .no
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
s_skip      db 'CCFIND: some directories skipped (queue full / path too long)',13,10
s_skip_len  equ $-s_skip

section .bss
align 2
pattern     resb 128            ; >= the whole 127-byte PSP tail: copies can't overrun
startdir    resb 128
curpath     resb 300            ; queued paths are <= PATHMAX (259) chars
tmppath     resb 528            ; curpath(259) + "\" + LFN name (<=260) + NUL
srchbuf     resb 300            ; curpath + "\*.*"
linebuf     resb 528            ; curpath(259) + "\" + LFN name (<=260) + CRLF
qskip       resb 1              ; 1 = a directory was dropped from the queue
dta         resb 64
lfn_avail   resb 1              ; 1 if INT 21h/714Eh is supported, else 0
lfn_handle  resw 1              ; handle returned by 714Eh
wfd         resb 318            ; WIN32_FIND_DATA; long name at offset +44
qhead       resw 1
qtail       resw 1
qbuf        resb QMAX
stackspace  resb 1024
stacktop:
