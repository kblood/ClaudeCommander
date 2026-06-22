; ============================================================================
;  CCGREP.COM  --  Claude Commander's external text searcher (Layer 3 helper)
;
;  Usage:  CCGREP <text> [startdir] [filemask]
;          CCGREP error C:\LOGS              -> "error" in every file under LOGS
;          CCGREP TODO . *.ASM               -> "TODO" in *.ASM in this tree
;          CCGREP include C:\SRC *.H > HITS  -> redirect matches to a file
;
;  Walks the directory tree breadth-first (a queue of pending dirs, one DTA, no
;  recursion).  For every FILE whose name matches <filemask> (default *.*) it
;  reads up to 32 KB of the file and prints each line that contains <text>
;  (case-insensitive) as  full\path:line  to stdout, so callers can redirect.
;  Files larger than 32 KB are searched in their first 32 KB only.
;
;  Assemble:  nasm -f bin cgrep.asm -o ccgrep.com
; ============================================================================
        org     100h

QMAX     equ 16384              ; directory-queue byte budget
FBUFMAX  equ 32768              ; bytes of each file searched
MAXLINE  equ 200                ; longest printed line

start:
        cld
        mov     sp, stacktop
        call    parse_tail          ; -> needle, startdir, filemask
        call    measure_needle      ; -> nlen
        cmp     word [nlen], 0
        je      .done               ; empty needle: nothing to do
        mov     word [qhead], qbuf
        mov     word [qtail], qbuf
        mov     si, startdir
        call    enqueue
.next:
        call    dequeue             ; curpath = next dir; CF=1 -> empty
        jc      .done
        call    scan_dir
        jmp     .next
.done:
        mov     ax, 4C00h
        int     21h

; ----------------------------------------------------------------------------
; parse PSP tail: token1 -> needle, token2 -> startdir ("."), token3 -> mask ("*.*")
parse_tail:
        movzx   cx, byte [80h]
        mov     si, 81h
        mov     di, needle
        call    .skipsp
        call    .copytok
        mov     di, startdir
        call    .skipsp
        call    .copytok
        mov     di, filemask
        call    .skipsp
        call    .copytok
        cmp     byte [startdir], 0
        jne     .ckmask
        mov     word [startdir], '.'
        mov     byte [startdir+1], 0
.ckmask:
        cmp     byte [filemask], 0
        jne     .ret
        mov     si, s_star
        mov     di, filemask
        call    catz_di
        mov     byte [di], 0
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

measure_needle:
        mov     si, needle
        xor     cx, cx
.l:     cmp     byte [si], 0
        je      .d
        inc     si
        inc     cx
        jmp     .l
.d:     mov     [nlen], cx
        ret

; ----------------------------------------------------------------------------
; scan_dir: list [curpath]; grep matching files; enqueue subdirectories.
scan_dir:
        mov     dx, dta
        mov     ah, 1Ah
        int     21h
        call    build_search        ; srchbuf = curpath + "\*.*"
        mov     ah, 4Eh
        mov     cx, 10h
        mov     dx, srchbuf
        int     21h
        jc      .ret
.loop:
        mov     bx, dta
        cmp     byte [bx+30], '.'
        je      .next
        test    byte [bx+21], 10h
        jnz     .dir
        ; file: name matches the mask?
        mov     si, filemask
        lea     di, [bx+30]
        call    wildmatch
        jnc     .next
        call    grep_file
        jmp     .next
.dir:
        call    enqueue_child
.next:
        mov     ah, 4Fh
        int     21h
        jnc     .loop
.ret:
        ret

; build srchbuf = curpath + "\*.*"
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

; ----------------------------------------------------------------------------
; grep_file: open curpath\<dta name>, read <=FBUFMAX, print matching lines.
grep_file:
        ; fpath = curpath + "\" + name
        mov     si, curpath
        mov     di, fpath
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
        ; open read-only
        mov     ax, 3D00h
        mov     dx, fpath
        int     21h
        jc      .ret
        mov     [fh], ax
        ; read up to FBUFMAX
        mov     bx, ax
        mov     ah, 3Fh
        mov     cx, FBUFMAX
        mov     dx, fbuf
        int     21h
        jc      .close
        mov     [flen], ax
        ; close before scanning (we have the data)
        mov     bx, [fh]
        mov     ah, 3Eh
        int     21h
        call    scan_buffer
        ret
.close:
        mov     bx, [fh]
        mov     ah, 3Eh
        int     21h
.ret:
        ret

; scan fbuf[0..flen) for needle; print each matching line once.
scan_buffer:
        mov     si, fbuf            ; si = current scan position
        mov     bx, fbuf
        add     bx, [flen]          ; bx = end pointer
.scan:
        mov     ax, si
        add     ax, [nlen]
        cmp     ax, bx
        ja      .ret                ; not enough left for a match
        mov     di, si
        call    match_at            ; CF=1 if needle at si
        jnc     .adv
        ; found: print enclosing line, then jump past its end
        push    bx                  ; print_line clobbers bx (end ptr)
        call    print_line          ; uses si; returns di = line-end ptr
        pop     bx
        mov     si, di
        cmp     si, bx
        jb      .scan
        ret
.adv:
        inc     si
        jmp     .scan
.ret:
        ret

; match_at: di -> candidate in fbuf; CF=1 if needle matches (case-insensitive).
match_at:
        push    si
        push    di
        mov     si, needle
.m:     mov     al, [si]
        or      al, al
        jz      .yes
        mov     ah, [di]
        cmp     al, ah
        je      .eq
        or      al, 20h             ; fold to lower
        or      ah, 20h
        cmp     al, ah
        jne     .no
        cmp     al, 'a'             ; ensure both were letters
        jb      .no
        cmp     al, 'z'
        ja      .no
.eq:    inc     si
        inc     di
        jmp     .m
.yes:   pop     di
        pop     si
        stc
        ret
.no:    pop     di
        pop     si
        clc
        ret

; print_line: si points inside fbuf at a match. Find the line [ls,le), print
;   fpath:line CRLF.  Returns di = le (pointer to the line's terminator/end).
;   Clobbers ax/bx/cx/si/di.
print_line:
        ; find line start ls -> di walks back to char after prev LF (or fbuf)
        mov     di, si
.back:
        cmp     di, fbuf
        jbe     .havels
        dec     di
        cmp     byte [di], 0Ah
        jne     .back
        inc     di                  ; step past the LF
.havels:
        push    di                  ; save ls
        ; find line end le -> di walks forward to LF or buffer end
        mov     bx, fbuf
        add     bx, [flen]          ; bx = buffer end
        mov     di, si
.fwd:
        cmp     di, bx
        jae     .havele
        cmp     byte [di], 0Ah
        je      .havele
        inc     di
        jmp     .fwd
.havele:
        mov     [le_save], di       ; remember le for the return value
        ; build output: fpath + ':' + line(ls..le, strip CR) into linebuf
        mov     di, linebuf
        mov     si, fpath
        call    catz_di
        mov     byte [di], ':'
        inc     di
        pop     si                  ; si = ls
        mov     bx, [le_save]       ; bx = le
        xor     cx, cx              ; printed-length guard
.cp:
        cmp     si, bx
        jae     .endline
        cmp     cx, MAXLINE
        jae     .endline
        mov     al, [si]
        cmp     al, 0Dh             ; skip CR
        je      .skip
        cmp     al, 9               ; tabs -> space for tidy output
        jne     .store
        mov     al, ' '
.store:
        mov     [di], al
        inc     di
        inc     cx
.skip:
        inc     si
        jmp     .cp
.endline:
        mov     word [di], 0A0Dh    ; CRLF
        add     di, 2
        mov     cx, di
        sub     cx, linebuf
        mov     ah, 40h
        mov     bx, 1               ; stdout
        mov     dx, linebuf
        int     21h
        mov     di, [le_save]       ; return di = le
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

; copy ASCIIZ ds:si -> [di] without the NUL; di advanced.
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
        sub     si, [qtail]
        mov     ax, di
        add     ax, si
        inc     ax
        cmp     ax, qbuf+QMAX
        pop     di
        pop     si
        ja      .ret
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

; ============================================================================
s_star      db '*.*',0

section .bss
align 2
needle      resb 80
nlen        resw 1
startdir    resb 80
filemask    resb 16
curpath     resb 80
tmppath     resb 128
fpath       resb 144
srchbuf     resb 96
linebuf     resb 280
fh          resw 1
flen        resw 1
le_save     resw 1
dta         resb 64
qhead       resw 1
qtail       resw 1
qbuf        resb QMAX
fbuf        resb FBUFMAX
stackspace  resb 1024
stacktop:
