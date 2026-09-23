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
; Errorlevel 0 = OK, 1 = an entry failed or was refused.  X/XA vet names
; first: leading '/' '\' dropped, a '..' component or ':' refused.  They never
; overwrite: outputs are created with INT 21h/5Bh and a clash becomes
; NAME~1..NAME~9 (extension kept); if all are taken the entry fails.
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
        jnc     .chktrunc
        mov     dx, s_e_read
        mov     ah, 9
        int     21h
        call    close_pak
        mov     ax, 4C01h
        int     21h

.chktrunc:
        cmp     byte [truncated], 0
        je      .dispatch
        ; directory longer than MAX_ENT: say so (stderr for the L listing,
        ; so cc's "<size> <name>" parse never sees it; stdout otherwise)
        mov     bx, 1
        cmp     byte [lmode], 0
        je      .wh
        mov     bx, 2
.wh:
        mov     ah, 40h
        mov     cx, S_W_TRUNC_LEN
        mov     dx, s_w_trunc
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
        mov     al, [failed]        ; errorlevel 1 if any entry failed/skipped
        mov     ah, 4Ch
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
        mov     byte [truncated], 1     ; the rest is not loaded -> warn
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
        shr     ax, 6                   ; short read -> only whole entries
        mov     [pak_count], ax
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
        mov     cx, 56                  ; name[56] need not be NUL-terminated
.cp:
        mov     al, [si]
        or      al, al
        jz      .cpe
        mov     [di], al
        inc     si
        inc     di
        loop    .cp
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
        jae     .noent
        shl     ax, 6
        add     ax, entry_table
        mov     [cur_entry], ax

        ; e_name = the entry's name[56] (need not be NUL-terminated), then
        ; vet it: no '..' component, no ':', leading separators dropped
        mov     si, ax
        mov     di, e_name
        mov     cx, 56
.cpb:
        mov     al, [si]
        or      al, al
        jz      .cpbe
        mov     [di], al
        inc     si
        inc     di
        loop    .cpb
.cpbe:
        mov     byte [di], 0
        call    safe_name               ; si -> vetted name, CF=1 unsafe
        jnc     .safe
        mov     si, s_e_unsafe
        jmp     fail_msg
.safe:
        push    si

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
        pop     si                      ; vetted name (NUL-terminated, <=56)
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
        jnc     .ret
        mov     si, s_e_extract
        jmp     fail_msg
.ret:
        ret
.noent:
        mov     byte [failed], 1        ; no such entry
        ret

; print "CCPAK: <reason at si><e_name>\r\n", mark the run failed
fail_msg:
        call    puts0
        mov     si, e_name
        call    puts0
        mov     si, s_crlf
        call    puts0
        mov     byte [failed], 1
        ret

; write ASCIIZ ds:si to stdout
puts0:
        mov     dx, si
.l:     cmp     byte [si], 0
        je      .w
        inc     si
        jmp     .l
.w:     mov     cx, si
        sub     cx, dx
        mov     ah, 40h
        mov     bx, 1
        int     21h
        ret

; Vet the entry name in e_name for use as a path under destdir.  Leading
; '/' '\' are dropped (absolute -> relative); a ':' anywhere (drive) or a
; component made only of dots and at least 2 long ('..', '...') -- with '/'
; and '\' both separators -- rejects it, as does an empty name.
;   -> si = start of the usable name inside e_name, CF=1 if unsafe
; (Same rules as czip.asm's safe_name.)
safe_name:
        mov     si, e_name
.lead:
        mov     al, [si]
        cmp     al, '/'
        je      .l1
        cmp     al, '\'
        jne     .body
.l1:
        inc     si
        jmp     .lead
.body:
        push    si
        cmp     byte [si], 0
        je      .bad
        mov     bx, si                  ; bx = start of the current component
.sc:
        mov     al, [si]
        or      al, al
        jz      .endc
        cmp     al, ':'
        je      .bad
        cmp     al, '/'
        je      .endc
        cmp     al, '\'
        je      .endc
        inc     si
        jmp     .sc
.endc:                                  ; component = [bx..si)
        mov     cx, si
        sub     cx, bx
        cmp     cx, 2
        jb      .nextc
        mov     di, bx
.dots:
        cmp     byte [di], '.'
        jne     .nextc
        inc     di
        cmp     di, si
        jb      .dots
        jmp     .bad                    ; all dots -> parent-dir escape
.nextc:
        cmp     byte [si], 0
        je      .ok
        inc     si
        mov     bx, si
        jmp     .sc
.ok:
        pop     si
        clc
        ret
.bad:
        pop     si
        stc
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

        ; create output file (never overwrites: a clash -> NAME~n)
        call    create_new
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
        jz      .fail_close     ; premature EOF = truncated PAK

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
        mov     ah, 41h         ; drop the partial output
        mov     dx, [ext_fname_p]
        int     21h
.fail:  stc
        ret

;──────────────────────────────────────────────────────────────────────────────
; create_new -- create outpath as a NEW file: INT 21h/5Bh never truncates an
; existing one.  On a clash (or a device name like CON) retry NAME~1..NAME~9:
; the final component's base cut to 6 chars + '~' + digit, its extension kept
; (the scheme of CCRAR's create_out).  CF=0 -> ax = handle, outpath = the
; name used; CF=1 -> nothing created.  (Same routine as czip.asm's.)
;──────────────────────────────────────────────────────────────────────────────
create_new:
        mov     si, outpath
        mov     bx, si              ; bx -> start of the final component
        xor     dx, dx              ; dx -> its last '.' (0 = none)
.scan:
        lodsb
        or      al, al
        jz      .scanned
        cmp     al, '\'
        je      .sep
        cmp     al, '/'
        je      .sep
        cmp     al, ':'
        je      .sep
        cmp     al, '.'
        jne     .scan
        lea     dx, [si-1]
        jmp     .scan
.sep:
        mov     bx, si
        xor     dx, dx
        jmp     .scan
.scanned:
        dec     si                  ; si -> the NUL
        or      dx, dx
        jnz     .hasdot
        mov     dx, si              ; no extension: the base runs to the end
.hasdot:
        mov     ax, dx
        sub     ax, bx              ; base length, cut to 6
        cmp     ax, 6
        jbe     .b6
        mov     ax, 6
.b6:
        add     ax, bx
        mov     [cn_tail], ax       ; "~n" + extension go here on a clash
        mov     si, dx              ; keep '.' + up to 3 extension chars
        mov     di, cn_ext
        mov     cx, 4
.ex:
        lodsb
        or      al, al
        jz      .exd
        stosb
        loop    .ex
.exd:
        mov     byte [di], 0
        mov     byte [cn_try], '0'
.try:
        mov     ah, 5Bh
        xor     cx, cx
        mov     dx, outpath
        int     21h
        jc      .next
        mov     bx, ax
        push    ax
        mov     ax, 4400h           ; IOCTL: is this handle a character device?
        int     21h
        pop     ax
        test    dl, 80h             ; (also clears CF)
        jz      .ret
        mov     ah, 3Eh             ; a device, not a file: close, rename
        int     21h
.next:
        inc     byte [cn_try]
        cmp     byte [cn_try], '9'
        ja      .fail
        mov     di, [cn_tail]
        mov     al, '~'
        stosb
        mov     al, [cn_try]
        stosb
        mov     si, cn_ext
.ce:
        lodsb
        stosb
        or      al, al
        jnz     .ce
        jmp     .try
.fail:
        stc
.ret:
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
        mov     byte [lmode], 1
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
s_w_trunc:
        db      'CCPAK: warning: directory has more than 512 entries; only the first 512 are available', 0Dh, 0Ah
S_W_TRUNC_LEN equ $ - s_w_trunc
s_e_unsafe:
        db      'CCPAK: unsafe name skipped: ', 0
s_e_extract:
        db      'CCPAK: extract failed: ', 0
s_crlf:
        db      0Dh, 0Ah, 0

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

lmode:          resb    1       ; 1 = L (only steers where warnings go)
xmode:          resb    1       ; 1 = X (extract one)
xallmode:       resb    1       ; 1 = XA (extract all)
destdir:        resb    128     ; X/XA destination directory
xindex:         resw    1       ; X target index (0-based, matches L order)
tok1:           resb    128     ; parse_args scratch token

iter_i:         resw    1       ; do_list loop counter
cur_entry:      resw    1       ; extract_one: entry_table pointer for the target
linebuf:        resb    80      ; emit_one line buffer (10 + 1 + 56 + CRLF)
outpath:        resb    200     ; extract_one/make_dirs scratch path (<128+1+56+1)
e_name:         resb    58      ; NUL-terminated copy of the entry's name[56]
failed:         resb    1       ; any entry failed/skipped -> errorlevel 1
truncated:      resb    1       ; directory had more than MAX_ENT entries
cn_try:         resb    1       ; create_new: current '~' digit
cn_ext:         resb    6       ; create_new: saved ".EXT" + NUL
cn_tail:        resw    1       ; create_new: where "~n.EXT" is written

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
