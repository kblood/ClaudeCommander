; cpak.asm -- CCPAK.COM  Quake PAK archive plugin for Claude Commander (cc)
;
; Usage:  CCPAK <file.pak>            human listing (size / name)
;         CCPAK L  <file.pak>         machine listing for cc: "<size> <name>"
;         CCPAK X  <file.pak> <n> <d> extract file #n (L order) to dir <d>
;         CCPAK XA <file.pak> <d>     extract every file to dir <d>
;
; PAK format (id Software / Quake):
;   Header 12 B: "PACK" (4) | uint32 dirofs | uint32 dirlen
;   Each directory entry (64 B): char name[56] | uint32 filepos | uint32 filelen
;   Path separator is '/'.  Example entry: "progs/player.mdl"
;
; This is a Layer-3 helper: cc's [open] map (pak=CCPAK) makes it browsable
; exactly like the ZIP plugin -- Enter to browse, F5 to extract, Alt-F9 all.
; F3 on a member inside the archive runs "<viewhelper> <container> <index>"
; (mod/vfs.inc's vfs_view) -- e.g. CCMDL <file.pak> <index> for a .mdl member.
;
; Build: nasm -f bin cpak.asm -o CCPAK.COM

        cpu     386
        org     100h

;──────────────────────────────────────────────────────────────────────────────
; Tunables
;──────────────────────────────────────────────────────────────────────────────

MAX_ENT     equ     512     ; max directory entries to load (512 x 64 = 32 KB)
IO_BUF_SZ   equ     4096    ; I/O buffer for extraction

; PAK entry field offsets (within each 64-byte record)
E_NAME      equ     0       ; char[56]: null-padded path like "progs/player.mdl"
E_FPOS      equ     56      ; uint32: byte offset of file data within the .pak
E_FLEN      equ     60      ; uint32: byte length of file data

;──────────────────────────────────────────────────────────────────────────────
; Entry point
;──────────────────────────────────────────────────────────────────────────────

start:
        cld
        mov     sp, stk_top

        ; zero-initialise the entire BSS region
        mov     di, bss_start
        mov     cx, (stk_top - bss_start)
        xor     al, al
        rep     stosb

        ; set sentinels: file handles start at -1 (not open)
        mov     word [pak_fh],  0FFFFh
        mov     word [out_fh],  0FFFFh

        call    parse_args
        cmp     byte [pak_path], 0
        jne     .have_arg
        mov     dx, s_usage
        mov     ah, 9
        int     21h
        mov     ax, 4C01h
        int     21h

.have_arg:
        call    open_pak
        jnc     .do_read
        mov     dx, s_e_open
        mov     ah, 9
        int     21h
        mov     ax, 4C01h
        int     21h

.do_read:
        call    read_dir
        jnc     .dispatch
        mov     dx, s_e_read
        mov     ah, 9
        int     21h
        call    close_pak
        mov     ax, 4C01h
        int     21h

.dispatch:
        cmp     byte [xmode], 0
        jne     .do_x
        cmp     byte [xallmode], 0
        jne     .do_xa
        call    do_list
        jmp     .fin
.do_x:
        call    extract_one
        jmp     .fin
.do_xa:
        call    extract_all
.fin:
        call    close_pak
        mov     ax, 4C00h
        int     21h

;──────────────────────────────────────────────────────────────────────────────
; open_pak -- open file, verify "PACK", store dirofs/dirlen
; Returns CF=1 on error
;──────────────────────────────────────────────────────────────────────────────
open_pak:
        mov     ax, 3D00h
        mov     dx, pak_path
        int     21h
        jc      .fail
        mov     [pak_fh], ax

        mov     bx, ax
        mov     ah, 3Fh
        mov     cx, 12
        mov     dx, pak_hdr
        int     21h
        jc      .closefail
        cmp     ax, 12
        jne     .closefail

        ; check "PACK" magic
        cmp     byte [pak_hdr+0], 'P'
        jne     .closefail
        cmp     byte [pak_hdr+1], 'A'
        jne     .closefail
        cmp     byte [pak_hdr+2], 'C'
        jne     .closefail
        cmp     byte [pak_hdr+3], 'K'
        jne     .closefail

        mov     eax, [pak_hdr+4]        ; dirofs
        mov     [pak_dirofs], eax
        mov     eax, [pak_hdr+8]        ; dirlen
        mov     [pak_dirlen], eax
        clc
        ret

.closefail:
        mov     bx, [pak_fh]
        mov     ah, 3Eh
        int     21h
        mov     word [pak_fh], 0FFFFh
.fail:  stc
        ret

;──────────────────────────────────────────────────────────────────────────────
; close_pak
;──────────────────────────────────────────────────────────────────────────────
close_pak:
        mov     bx, [pak_fh]
        cmp     bx, 0FFFFh
        je      .skip
        mov     ah, 3Eh
        int     21h
        mov     word [pak_fh], 0FFFFh
.skip:  ret

;──────────────────────────────────────────────────────────────────────────────
; read_dir -- seek to dirofs, read entries into entry_table, set pak_count
; Returns CF=1 on error
;──────────────────────────────────────────────────────────────────────────────
read_dir:
        mov     eax, [pak_dirlen]
        shr     eax, 6                  ; count = dirlen / 64
        cmp     eax, MAX_ENT
        jbe     .ok
        mov     eax, MAX_ENT
.ok:    mov     [pak_count], ax         ; word store (max 512)
        or      ax, ax
        jz      .empty

        ; seek to directory (32-bit offset)
        mov     bx, [pak_fh]
        mov     ax, 4200h
        mov     cx, word [pak_dirofs+2]
        mov     dx, word [pak_dirofs]
        int     21h
        jc      .fail

        ; read entries: count*64 bytes (max 32768, fits in CX)
        mov     cx, [pak_count]
        shl     cx, 6
        mov     bx, [pak_fh]
        mov     ah, 3Fh
        mov     dx, entry_table
        int     21h
        jc      .fail
.empty: clc
        ret
.fail:  stc
        ret

;──────────────────────────────────────────────────────────────────────────────
; do_list -- L mode: emit "<size> <name>\r\n" for every entry, in table order
;──────────────────────────────────────────────────────────────────────────────
do_list:
        mov     word [iter_i], 0
.lp:
        mov     ax, [iter_i]
        cmp     ax, [pak_count]
        jae     .done
        shl     ax, 6
        add     ax, entry_table
        mov     si, ax
        call    emit_one
        inc     word [iter_i]
        jmp     .lp
.done:
        ret

; si -> 64-byte directory record. Write "<E_FLEN decimal> <name>\r\n" to stdout.
emit_one:
        mov     eax, [si + E_FLEN]
        mov     di, linebuf
        call    putnum32
        mov     byte [di], ' '
        inc     di
        lea     si, [si + E_NAME]
.cp:
        mov     al, [si]
        or      al, al
        jz      .cpe
        mov     [di], al
        inc     si
        inc     di
        jmp     .cp
.cpe:
        mov     word [di], 0A0Dh        ; CR LF
        add     di, 2
        mov     cx, di
        sub     cx, linebuf
        mov     ah, 40h
        mov     bx, 1
        mov     dx, linebuf
        int     21h
        ret

;──────────────────────────────────────────────────────────────────────────────
; extract_one -- X mode: extract entry_table[xindex] into destdir, preserving
; sub-folders ('/'->'\', intermediate dirs created via make_dirs).
;──────────────────────────────────────────────────────────────────────────────
extract_one:
        mov     ax, [xindex]
        cmp     ax, [pak_count]
        jae     .ret
        shl     ax, 6
        add     ax, entry_table
        mov     [cur_entry], ax

        ; outpath = destdir + '\' (if needed) + name, '/' mapped to '\'
        mov     si, destdir
        mov     di, outpath
.cpd:
        mov     al, [si]
        or      al, al
        jz      .cpde
        mov     [di], al
        inc     si
        inc     di
        jmp     .cpd
.cpde:
        cmp     byte [di-1], '\'
        je      .nosep
        cmp     byte [di-1], '/'
        je      .nosep
        mov     byte [di], '\'
        inc     di
.nosep:
        mov     si, [cur_entry]
        add     si, E_NAME
.cpn:
        mov     al, [si]
        or      al, al
        jz      .cpne
        cmp     al, '/'
        jne     .cpn1
        mov     al, '\'
.cpn1:
        mov     [di], al
        inc     si
        inc     di
        jmp     .cpn
.cpne:
        mov     byte [di], 0
        call    make_dirs
        mov     si, [cur_entry]
        mov     dx, outpath
        call    do_extract
.ret:
        ret

;──────────────────────────────────────────────────────────────────────────────
; extract_all -- XA mode: extract_one for every index in table order.
;──────────────────────────────────────────────────────────────────────────────
extract_all:
        mov     word [xindex], 0
.lp:
        mov     ax, [xindex]
        cmp     ax, [pak_count]
        jae     .done
        call    extract_one
        inc     word [xindex]
        jmp     .lp
.done:
        ret

;──────────────────────────────────────────────────────────────────────────────
; make_dirs -- create every intermediate directory along outpath (errors
; ignored: "already exists" / invalid root). The final component (the file)
; has no trailing separator, so it is never mkdir'd. (Mirrors czip.asm.)
;──────────────────────────────────────────────────────────────────────────────
make_dirs:
        mov     si, outpath
.md:
        mov     al, [si]
        or      al, al
        jz      .done
        cmp     al, '\'
        jne     .adv
        mov     byte [si], 0
        push    si
        mov     ah, 39h             ; mkdir (errors ignored)
        mov     dx, outpath
        int     21h
        pop     si
        mov     byte [si], '\'
.adv:
        inc     si
        jmp     .md
.done:
        ret

;──────────────────────────────────────────────────────────────────────────────
; do_extract -- copy entry (SI -> record) to file at DX (NUL-terminated path)
; Returns CF=0 OK, CF=1 error
;──────────────────────────────────────────────────────────────────────────────
do_extract:
        mov     [ext_fname_p], dx       ; save output path
        mov     eax, [si + E_FPOS]
        mov     [ext_fpos], eax
        mov     eax, [si + E_FLEN]
        mov     [ext_flen], eax

        ; seek PAK to filepos (32-bit)
        mov     bx, [pak_fh]
        mov     ax, 4200h
        mov     cx, word [ext_fpos+2]
        mov     dx, word [ext_fpos]
        int     21h
        jc      .fail

        ; create output file
        mov     ah, 3Ch
        xor     cx, cx
        mov     dx, [ext_fname_p]
        int     21h
        jc      .fail
        mov     [out_fh], ax

        ; copy ext_flen bytes in IO_BUF_SZ chunks
        mov     eax, [ext_flen]
        mov     [bytes_rem], eax

.loop:  mov     eax, [bytes_rem]
        or      eax, eax
        jz      .done

        ; chunk = min(bytes_rem, IO_BUF_SZ)
        cmp     eax, IO_BUF_SZ
        jbe     .use_eax
        mov     ax, IO_BUF_SZ
        jmp     .do_read
.use_eax:
        ; eax <= IO_BUF_SZ (4096), so AX = EAX is safe
.do_read:
        mov     cx, ax
        mov     bx, [pak_fh]
        mov     ah, 3Fh
        mov     dx, io_buf
        int     21h
        jc      .fail_close
        or      ax, ax
        jz      .done           ; premature EOF, accept what we got

        mov     cx, ax
        mov     bx, [out_fh]
        mov     ah, 40h
        mov     dx, io_buf
        int     21h
        jc      .fail_close
        cmp     ax, cx
        jne     .fail_close     ; short write = disk full

        movzx   eax, cx
        sub     [bytes_rem], eax
        jmp     .loop

.done:  mov     bx, [out_fh]
        mov     ah, 3Eh
        int     21h
        mov     word [out_fh], 0FFFFh
        clc
        ret

.fail_close:
        mov     bx, [out_fh]
        mov     ah, 3Eh
        int     21h
        mov     word [out_fh], 0FFFFh
.fail:  stc
        ret

;──────────────────────────────────────────────────────────────────────────────
; putnum32 -- append the decimal representation of EAX at [di]; di advanced.
;──────────────────────────────────────────────────────────────────────────────
putnum32:
        push    eax
        push    ebx
        push    ecx
        push    edx
        xor     cx, cx                  ; digit count
        mov     ebx, 10
.dv:
        xor     edx, edx
        div     ebx                     ; eax /= 10, edx = remainder
        push    dx
        inc     cx
        or      eax, eax
        jnz     .dv
.pp:
        pop     dx
        add     dl, '0'
        mov     [di], dl
        inc     di
        loop    .pp
        pop     edx
        pop     ecx
        pop     ebx
        pop     eax
        ret

;──────────────────────────────────────────────────────────────────────────────
; parse_args -- tokenise the PSP tail: mode token L / X / XA selects machine
; listing / extract-one / extract-all, else the first token is pak_path
; (bare-filename direct usage, same output as L). Mirrors cd64.asm/CCD64.
;──────────────────────────────────────────────────────────────────────────────
parse_args:
        mov     si, 81h
.term:
        mov     al, [si]
        or      al, al
        jz      .t0
        cmp     al, 0Dh
        je      .t0
        inc     si
        jmp     .term
.t0:
        mov     byte [si], 0
        mov     si, 81h
        call    skip_sp
        mov     di, tok1
        call    read_tok
        cmp     byte [tok1], 0
        je      .none
        mov     al, [tok1]
        and     al, 0DFh
        mov     ah, [tok1+1]
        or      ah, ah
        jnz     .twochar
        cmp     al, 'L'
        je      .islist
        cmp     al, 'X'
        je      .isextract
        jmp     .firstfile
.twochar:
        cmp     byte [tok1+2], 0
        jne     .firstfile
        and     ah, 0DFh
        cmp     al, 'X'
        jne     .firstfile
        cmp     ah, 'A'
        jne     .firstfile
        mov     byte [xallmode], 1
        call    skip_sp
        mov     di, pak_path
        call    read_tok
        call    skip_sp
        mov     di, destdir
        call    read_tok
        ret
.islist:
        call    skip_sp
        mov     di, pak_path
        call    read_tok
        ret
.isextract:
        mov     byte [xmode], 1
        call    skip_sp
        mov     di, pak_path
        call    read_tok
        call    skip_sp
        call    read_dec
        mov     [xindex], ax
        call    skip_sp
        mov     di, destdir
        call    read_tok
        ret
.firstfile:
        mov     si, tok1
        mov     di, pak_path
.cp:
        mov     al, [si]
        mov     [di], al
        or      al, al
        jz      .d
        inc     si
        inc     di
        jmp     .cp
.d:
        ret
.none:
        mov     byte [pak_path], 0
        ret

read_dec:
        xor     ax, ax
        xor     ch, ch
.d:
        mov     cl, [si]
        cmp     cl, '0'
        jb      .e
        cmp     cl, '9'
        ja      .e
        sub     cl, '0'
        mov     bx, 10
        push    dx
        mul     bx
        pop     dx
        add     ax, cx
        inc     si
        jmp     .d
.e:
        ret

skip_sp:
        cmp     byte [si], ' '
        jne     .d
        inc     si
        jmp     skip_sp
.d:     ret

read_tok:
        mov     al, [si]
        or      al, al
        jz      .d
        cmp     al, ' '
        je      .d
        mov     [di], al
        inc     si
        inc     di
        jmp     read_tok
.d:     mov     byte [di], 0
        ret

;──────────────────────────────────────────────────────────────────────────────
; Read-only data
;──────────────────────────────────────────────────────────────────────────────

s_usage:
        db      'Usage: CCPAK <file.pak>', 0Dh, 0Ah, '$'
s_e_open:
        db      'CCPAK: cannot open or not a valid PAK (missing PACK header)', 0Dh, 0Ah, '$'
s_e_read:
        db      'CCPAK: error reading PAK directory', 0Dh, 0Ah, '$'

;──────────────────────────────────────────────────────────────────────────────
; BSS (labels only; all zeroed by startup rep stosb)
;──────────────────────────────────────────────────────────────────────────────

section .bss

bss_start:

pak_path:       resb    128     ; command-line path to the .pak file
pak_fh:         resw    1       ; PAK file handle (0FFFFh = not open)
pak_hdr:        resb    12      ; raw 12-byte header read buffer
pak_dirofs:     resd    1       ; uint32: directory offset
pak_dirlen:     resd    1       ; uint32: directory length in bytes
pak_count:      resw    1       ; number of entries loaded

lmode:          resb    1       ; unused (kept for symmetry with CD64/CT64)
xmode:          resb    1       ; 1 = X (extract one)
xallmode:       resb    1       ; 1 = XA (extract all)
destdir:        resb    128     ; X/XA destination directory
xindex:         resw    1       ; X target index (0-based, matches L order)
tok1:           resb    128     ; parse_args scratch token

iter_i:         resw    1       ; do_list loop counter
cur_entry:      resw    1       ; extract_one: entry_table pointer for the target
linebuf:        resb    80      ; emit_one line buffer
outpath:        resb    200     ; extract_one/make_dirs scratch path

; do_extract state
ext_fname_p:    resw    1       ; pointer to output filename
ext_fpos:       resd    1
ext_flen:       resd    1
bytes_rem:      resd    1
out_fh:         resw    1       ; output file handle (0FFFFh = not open)

io_buf:         resb    IO_BUF_SZ   ; I/O buffer for extraction (4 KB)

; PAK directory table -- largest block, placed last (512 x 64 = 32 768 bytes)
entry_table:    resb    MAX_ENT * 64

; 1 KB stack, grows down from stk_top
                resb    1024
stk_top:
