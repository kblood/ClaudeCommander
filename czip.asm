; ============================================================================
;  CCZIP.COM  --  Claude Commander's external ZIP lister (Layer 3 helper)
;
;  Usage:  CCZIP <file.zip>        human-readable listing (name/size/method)
;          CCZIP L <file.zip>      machine listing for cc: "<size> <name>" lines
;                                  (one per FILE; directory members are skipped)
;  Parses the End-Of-Central-Directory record and the central directory.
;  Prints to stdout so cc can show or redirect it:  CCZIP L foo.zip > list.txt
;  cc's container-browser (the [open] map) uses the L form to show a ZIP as a
;  navigable folder.
;
;  (Listing only -- DEFLATE decompression is intentionally out of scope for a
;  tiny helper.  Extraction can be added later or delegated to a real unzip.)
;
;  Assemble:  nasm -f bin czip.asm -o cczip.com
; ============================================================================
        org     100h

TAILMAX equ 4096                ; bytes from EOF scanned for the EOCD record
CDMAX   equ 32768               ; central-directory bytes buffered
IBUF_SZ equ 4096                ; INFLATE input refill chunk / STORED copy chunk
OBUF_SZ equ 4096                ; INFLATE output flush chunk

start:
        cld
        mov     sp, stacktop
        ; DOS does not clear .bss for a .COM and we load at the same address
        ; each run, so stale mode flags from a previous invocation survive.
        ; Zero them before dispatch (a real bug under cc's repeated EXECs).
        mov     byte [lmode], 0
        mov     byte [xmode], 0
        mov     byte [xallmode], 0
        mov     byte [amode], 0
        mov     byte [fname], 0
        call    parse_args          ; -> fname (+ lmode if "L" prefix)
        cmp     byte [amode], 0     ; "A" add mode creates a fresh archive
        je      .noadd
        call    do_add
        mov     ax, 4C00h
        int     21h
.noadd:
        cmp     byte [fname], 0
        je      .usage
        mov     ax, 3D00h
        mov     dx, fname
        int     21h
        jc      .noopen
        mov     [fh], ax

        ; --- file size via LSEEK to end ---
        mov     bx, [fh]
        mov     ax, 4202h
        xor     cx, cx
        xor     dx, dx
        int     21h                 ; dx:ax = size
        mov     [fsize_lo], ax
        mov     [fsize_hi], dx

        ; --- compute tail start = size - min(size, TAILMAX) ---
        mov     ax, [fsize_lo]
        mov     dx, [fsize_hi]
        or      dx, dx
        jnz     .bigtail            ; size >= 64K -> tail is full TAILMAX
        cmp     ax, TAILMAX
        jae     .bigtail
        ; small file: read the whole thing from 0
        mov     [taillen], ax
        xor     cx, cx
        xor     dx, dx
        jmp     .seektail
.bigtail:
        mov     word [taillen], TAILMAX
        mov     ax, [fsize_lo]
        mov     dx, [fsize_hi]
        sub     ax, TAILMAX
        sbb     dx, 0
        mov     cx, dx
        mov     dx, ax
.seektail:
        mov     bx, [fh]
        mov     ax, 4200h
        int     21h
        mov     bx, [fh]
        mov     ah, 3Fh
        mov     cx, [taillen]
        mov     dx, tailbuf
        int     21h
        mov     [tailgot], ax

        ; --- scan backward for the EOCD signature 50 4B 05 06 ---
        mov     cx, [tailgot]
        sub     cx, 4
        jbe     .notzip
        mov     si, tailbuf
        add     si, cx              ; last position where a 4-byte sig fits
.scan:
        cmp     byte [si], 050h
        jne     .sdn
        cmp     byte [si+1], 04Bh
        jne     .sdn
        cmp     byte [si+2], 005h
        jne     .sdn
        cmp     byte [si+3], 006h
        je      .foundeocd
.sdn:
        dec     si
        cmp     si, tailbuf
        jae     .scan
        jmp     .notzip
.foundeocd:
        ; si -> EOCD.  count=word[+10], cdofs=dword[+16]
        mov     ax, [si+10]
        mov     [zcount], ax
        mov     ax, [si+16]
        mov     dx, [si+18]
        mov     [cdofs_lo], ax
        mov     [cdofs_hi], dx

        ; --- read the central directory into cdbuf ---
        mov     bx, [fh]
        mov     ax, 4200h
        mov     cx, [cdofs_hi]
        mov     dx, [cdofs_lo]
        int     21h
        mov     bx, [fh]
        mov     ah, 3Fh
        mov     cx, CDMAX
        mov     dx, cdbuf
        int     21h
        mov     [cdgot], ax

        ; extract modes keep the file open (need the member data later)
        cmp     byte [xmode], 0
        jne     .extract
        cmp     byte [xallmode], 0
        jne     .extractall

        mov     ah, 3Eh             ; close the zip
        mov     bx, [fh]
        int     21h

        ; --- walk central-directory headers ---
        mov     si, cdbuf
        mov     bp, [zcount]        ; entries remaining
.walk:
        or      bp, bp
        jz      .done
        ; bounds: need at least 46 bytes of header
        mov     ax, si
        sub     ax, cdbuf
        add     ax, 46
        cmp     ax, [cdgot]
        ja      .done
        ; signature 50 4B 01 02 ?
        cmp     byte [si], 050h
        jne     .done
        cmp     byte [si+1], 04Bh
        jne     .done
        cmp     byte [si+2], 001h
        jne     .done
        cmp     byte [si+3], 002h
        jne     .done
        call    print_entry         ; advances si to next header
        dec     bp
        jmp     .walk
.done:
        mov     ax, 4C00h
        int     21h

.extract:
        call    extract_member
        mov     bx, [fh]            ; close the zip
        mov     ah, 3Eh
        int     21h
        mov     ax, 4C00h
        int     21h

.extractall:
        call    extract_all
        mov     bx, [fh]
        mov     ah, 3Eh
        int     21h
        mov     ax, 4C00h
        int     21h

.usage:
        mov     si, s_usage
        jmp     .die
.noopen:
        mov     si, s_noopen
        jmp     .die
.notzip:
        mov     bx, [fh]            ; close if open
        mov     ah, 3Eh
        int     21h
        mov     si, s_notzip
.die:
        call    puts
        mov     ax, 4C01h
        int     21h

; ----------------------------------------------------------------------------
; print one central-directory entry; si -> header, advanced to the next.
;   method=word[+10] usize=dword[+24] namelen=word[+28]
;   extralen=word[+30] commentlen=word[+32] name@+46
print_entry:
        cmp     byte [lmode], 0
        jne     print_entry_l
        mov     di, linebuf
        ; name (namelen bytes from si+46)
        mov     cx, [si+28]
        push    si
        lea     bx, [si+46]
.nm:
        jcxz    .nmend
        mov     al, [bx]
        mov     [di], al
        inc     bx
        inc     di
        dec     cx
        jmp     .nm
.nmend:
        pop     si
        ; pad to column 40 with spaces (clamped)
        mov     ax, di
        sub     ax, linebuf
        cmp     ax, 40
        jae     .sz
        mov     cx, 40
        sub     cx, ax
.pad:
        mov     byte [di], ' '
        inc     di
        loop    .pad
.sz:
        mov     byte [di], ' '
        inc     di
        ; uncompressed size (dword at +24)
        mov     ax, [si+24]
        mov     dx, [si+26]
        call    putnum_di
        mov     bx, s_bytes
        call    cat_di
        ; method
        mov     ax, [si+10]
        or      ax, ax
        jnz     .defl
        mov     bx, s_stored
        jmp     .pm
.defl:
        cmp     ax, 8
        jne     .other
        mov     bx, s_defl
        jmp     .pm
.other:
        mov     bx, s_other
.pm:
        call    cat_di
        mov     word [di], 0A0Dh
        add     di, 2
        ; write linebuf
        mov     cx, di
        sub     cx, linebuf
        mov     ah, 40h
        mov     bx, 1
        mov     dx, linebuf
        int     21h
        ; advance si to next header: 46 + namelen + extralen + commentlen
        mov     ax, 46
        add     ax, [si+28]
        add     ax, [si+30]
        add     ax, [si+32]
        add     si, ax
        ret

; machine-readable entry for cc: "<usize> <name>\r\n".  Directory members
; (name ending in '/' or '\') are skipped.  si -> header, advanced to next.
print_entry_l:
        mov     cx, [si+28]         ; namelen
        jcxz    .adv                ; no name -> skip
        lea     di, [si+46]         ; -> name
        add     di, cx
        dec     di                  ; -> last name char
        mov     al, [di]
        cmp     al, '/'
        je      .adv                ; directory entry -> skip
        cmp     al, '\'
        je      .adv
        mov     di, linebuf
        mov     ax, [si+24]         ; uncompressed size dword
        mov     dx, [si+26]
        call    putnum_di
        mov     byte [di], ' '
        inc     di
        mov     cx, [si+28]         ; name
        lea     bx, [si+46]
.nm:
        jcxz    .nmend
        mov     al, [bx]
        mov     [di], al
        inc     bx
        inc     di
        dec     cx
        jmp     .nm
.nmend:
        mov     word [di], 0A0Dh    ; CR LF
        add     di, 2
        mov     cx, di
        sub     cx, linebuf
        mov     ah, 40h
        mov     bx, 1
        mov     dx, linebuf
        int     21h
.adv:
        mov     ax, 46
        add     ax, [si+28]
        add     ax, [si+30]
        add     ax, [si+32]
        add     si, ax
        ret

; append ASCIIZ ds:bx at [di] (no NUL); di advanced.
cat_di:
        mov     al, [bx]
        or      al, al
        jz      .d
        mov     [di], al
        inc     bx
        inc     di
        jmp     cat_di
.d:     ret

; append decimal of dx:ax at [di]; di advanced.
putnum_di:
        push    si
        mov     si, numtmp+15
        mov     byte [si], 0
        mov     bx, 10
.dv:
        ; divide dx:ax by 10 -> quotient dx:ax, remainder in cx
        mov     cx, ax              ; save low
        mov     ax, dx
        xor     dx, dx
        div     bx                  ; ax=hi/10, dx=hi%10
        mov     [hiq], ax
        mov     ax, cx
        div     bx                  ; ax=lo/10 (with carry from dx), dx=rem
        mov     cx, dx              ; remainder digit
        mov     dx, [hiq]           ; new high quotient
        dec     si
        add     cl, '0'
        mov     [si], cl
        ; quotient now dx:ax; loop while nonzero
        mov     cx, ax
        or      cx, dx
        jnz     .dv
        ; copy digits from si to di
.cp:
        mov     al, [si]
        or      al, al
        jz      .e
        mov     [di], al
        inc     si
        inc     di
        jmp     .cp
.e:
        pop     si
        ret

; write ASCIIZ ds:si to stdout.
puts:
        mov     di, si
.l:
        cmp     byte [di], 0
        je      .w
        inc     di
        jmp     .l
.w:
        mov     cx, di
        sub     cx, si
        mov     ah, 40h
        mov     bx, 1
        mov     dx, si
        int     21h
        ret

; ----------------------------------------------------------------------------
; Parse the command tail.  Optional leading "L" token selects machine listing;
; the remaining token is the archive filename.
;   CCZIP file.zip       -> fname=file.zip, lmode=0
;   CCZIP L file.zip     -> fname=file.zip, lmode=1
parse_args:
        mov     si, 81h             ; NUL-terminate the tail at its CR
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
        mov     di, tok1            ; first token
        call    read_tok
        ; mode token:  L=list  X=extract-one  XA=extract-all  A=add  else file
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
        cmp     al, 'A'
        je      .isadd
        jmp     .firstfile
.twochar:
        cmp     byte [tok1+2], 0
        jne     .firstfile
        and     ah, 0DFh
        cmp     al, 'X'
        jne     .firstfile
        cmp     ah, 'A'
        jne     .firstfile
        jmp     .isxall
.isxall:
        mov     byte [xallmode], 1
        call    skip_sp
        mov     di, fname
        call    read_tok            ; archive
        call    skip_sp
        mov     di, destdir
        call    read_tok            ; destination directory
        ret
.isadd:
        mov     byte [amode], 1
        call    skip_sp
        mov     di, fname
        call    read_tok            ; archive to create
        call    skip_sp
        cmp     byte [si], '@'      ; "@listfile" -> drop the '@'
        jne     .addtok
        inc     si
.addtok:
        mov     di, addlist
        call    read_tok            ; list-of-files path
        ret
.islist:
        mov     byte [lmode], 1
        call    skip_sp
        mov     di, fname
        call    read_tok
        ret
.isextract:
        mov     byte [xmode], 1
        call    skip_sp
        mov     di, fname
        call    read_tok            ; archive
        call    skip_sp
        call    read_dec            ; member index -> ax
        mov     [xindex], ax
        call    skip_sp
        mov     di, destdir
        call    read_tok            ; destination directory
        ret
.firstfile:
        mov     si, tok1
        mov     di, fname
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
        mov     byte [fname], 0
        ret

skip_sp:
        cmp     byte [si], ' '
        jne     .d
        inc     si
        jmp     skip_sp
.d:     ret

read_tok:                           ; copy [si] until space/NUL -> [di], NUL-term
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

; ============================================================================
s_usage     db 'Usage: CCZIP <file.zip>',0Dh,0Ah,0
s_noopen    db 'CCZIP: cannot open file',0Dh,0Ah,0
s_notzip    db 'CCZIP: not a ZIP (no central directory found)',0Dh,0Ah,0
s_bytes     db ' bytes ',0
s_stored    db '(stored)',0
s_defl      db '(deflated)',0
s_other     db '(method?)',0

; ============================================================================
;  EXTRACTION  --  CCZIP X <zip> <member-index> <destdir>
;  Walks the central directory to the Nth FILE entry (index matches the L
;  listing: directory members skipped), reads its local header for the data
;  offset, and writes the member into <destdir>\<basename>.  STORED = byte
;  copy; DEFLATE = the INFLATE engine below.
; ============================================================================

; read a decimal number at [si] -> ax ; si advanced
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
        mul     bx                  ; dx:ax = ax*10
        pop     dx
        add     ax, cx
        inc     si
        jmp     .d
.e:
        ret

; append ASCIIZ ds:si at [di] (no NUL); si,di advanced.
apz:
        mov     al, [si]
        or      al, al
        jz      .d
        mov     [di], al
        inc     si
        inc     di
        jmp     apz
.d:     ret

extract_member:
        mov     si, cdbuf
        mov     bp, [zcount]
        mov     word [filei], 0
.w:
        or      bp, bp
        jz      .nf
        mov     ax, si
        sub     ax, cdbuf
        add     ax, 46
        cmp     ax, [cdgot]
        ja      .nf
        cmp     byte [si], 050h
        jne     .nf
        cmp     byte [si+1], 04Bh
        jne     .nf
        cmp     byte [si+2], 001h
        jne     .nf
        cmp     byte [si+3], 002h
        jne     .nf
        mov     cx, [si+28]         ; namelen
        jcxz    .adv                ; no name -> skip, do not count
        lea     bx, [si+46]
        add     bx, cx
        dec     bx
        mov     al, [bx]
        cmp     al, '/'
        je      .adv
        cmp     al, '\'
        je      .adv
        mov     ax, [filei]
        cmp     ax, [xindex]
        je      .hit
        inc     word [filei]
.adv:
        mov     ax, 46
        add     ax, [si+28]
        add     ax, [si+30]
        add     ax, [si+32]
        add     si, ax
        dec     bp
        jmp     .w
.hit:
        call    do_extract
.nf:
        ret

; si -> the target central-directory header
do_extract:
        mov     cx, [si+28]         ; namelen
        cmp     cx, 120
        jbe     .nlok
        mov     cx, 120
.nlok:
        lea     bx, [si+46]
        mov     di, e_name
.cpn:
        jcxz    .cpe
        mov     al, [bx]
        mov     [di], al
        inc     bx
        inc     di
        dec     cx
        jmp     .cpn
.cpe:
        mov     byte [di], 0
        mov     ax, [si+10]
        mov     [e_method], ax
        mov     ax, [si+20]
        mov     [e_csize], ax
        mov     ax, [si+22]
        mov     [e_csize+2], ax
        mov     ax, [si+42]
        mov     [e_loff], ax
        mov     ax, [si+44]
        mov     [e_loff+2], ax
        ; basename = after the last '/' or '\'
        mov     si, e_name
        mov     di, e_name
.fb:
        mov     al, [si]
        or      al, al
        jz      .fbe
        cmp     al, '/'
        jne     .fb1
        lea     di, [si+1]
.fb1:
        cmp     al, '\'
        jne     .fb2
        lea     di, [si+1]
.fb2:
        inc     si
        jmp     .fb
.fbe:
        push    di                  ; basename ptr
        mov     si, destdir
        mov     di, outpath
        call    apz
        cmp     byte [di-1], '\'
        je      .nos
        cmp     byte [di-1], '/'
        je      .nos
        mov     byte [di], '\'
        inc     di
.nos:
        pop     si                  ; basename
        call    apz
        mov     byte [di], 0
        ; read 30-byte local header to resolve data offset
        mov     bx, [fh]
        mov     ax, 4200h
        mov     cx, [e_loff+2]
        mov     dx, [e_loff]
        int     21h
        mov     bx, [fh]
        mov     ah, 3Fh
        mov     cx, 30
        mov     dx, lhdr
        int     21h
        ; data = e_loff + 30 + local_namelen[+26] + local_extralen[+28]
        mov     ax, [e_loff]
        mov     dx, [e_loff+2]
        add     ax, 30
        adc     dx, 0
        add     ax, [lhdr+26]
        adc     dx, 0
        add     ax, [lhdr+28]
        adc     dx, 0
        mov     [e_doff], ax
        mov     [e_doff+2], dx
        mov     bx, [fh]
        mov     ax, 4200h
        mov     cx, [e_doff+2]
        mov     dx, [e_doff]
        int     21h
        ; create the output file
        mov     ah, 3Ch
        xor     cx, cx
        mov     dx, outpath
        int     21h
        jc      .ret
        mov     [ofh], ax
        mov     word [obpos], 0
        mov     ax, [e_method]
        or      ax, ax
        jz      .stored
        cmp     ax, 8
        je      .deflated
        jmp     .closeout           ; unsupported method -> empty file
.stored:
        call    copy_stored
        jmp     .closeout
.deflated:
        call    inflate
.closeout:
        call    flush_out
        mov     ah, 3Eh
        mov     bx, [ofh]
        int     21h
.ret:
        ret

; copy e_csize bytes fh -> ofh (STORED member)
copy_stored:
.lp:
        mov     ax, [e_csize]
        mov     dx, [e_csize+2]
        mov     cx, ax
        or      cx, dx
        jz      .done
        mov     cx, IBUF_SZ
        or      dx, dx
        jnz     .full
        cmp     ax, IBUF_SZ
        jae     .full
        mov     cx, ax
.full:
        push    cx
        mov     bx, [fh]
        mov     ah, 3Fh
        mov     dx, iobuf
        int     21h
        pop     cx
        mov     cx, ax
        or      cx, cx
        jz      .done
        push    cx
        mov     bx, [ofh]
        mov     ah, 40h
        mov     dx, iobuf
        int     21h
        pop     cx
        sub     [e_csize], cx
        sbb     word [e_csize+2], 0
        jmp     .lp
.done:
        ret

; extract EVERY file member (XA mode) into destdir
extract_all:
        mov     si, cdbuf
        mov     bp, [zcount]
.w:
        or      bp, bp
        jz      .done
        mov     ax, si
        sub     ax, cdbuf
        add     ax, 46
        cmp     ax, [cdgot]
        ja      .done
        cmp     byte [si], 050h
        jne     .done
        cmp     byte [si+1], 04Bh
        jne     .done
        cmp     byte [si+2], 001h
        jne     .done
        cmp     byte [si+3], 002h
        jne     .done
        mov     cx, [si+28]
        jcxz    .adv
        lea     bx, [si+46]
        add     bx, cx
        dec     bx
        mov     al, [bx]
        cmp     al, '/'
        je      .adv
        cmp     al, '\'
        je      .adv
        push    si
        push    bp
        call    do_extract          ; clobbers si
        pop     bp
        pop     si
.adv:
        mov     ax, 46
        add     ax, [si+28]
        add     ax, [si+30]
        add     ax, [si+32]
        add     si, ax
        dec     bp
        jmp     .w
.done:
        ret

; ----------------------------------------------------------------------------
;  ADD  --  CCZIP A <zip> @<listfile>  : create a fresh STORED zip whose
;  members are the files named (one full path per line) in <listfile>.
; ----------------------------------------------------------------------------

; write cx bytes at ds:dx -> ofh; a_outpos += written
emit:
        push    ax
        push    bx
        mov     bx, [ofh]
        mov     ah, 40h
        int     21h
        add     [a_outpos], ax
        adc     word [a_outpos+2], 0
        pop     bx
        pop     ax
        ret

; CRC-32 (poly 0xEDB88320) of cx bytes at ds:di, folded into [a_crc]
; (caller seeds a_crc = 0xFFFFFFFF and inverts at the end)
crc_block:
        mov     eax, [a_crc]
.byte:
        jcxz    .done
        movzx   ebx, byte [di]
        xor     al, bl
        push    cx
        mov     cx, 8
.bit:
        shr     eax, 1
        jnc     .nb
        xor     eax, 0EDB88320h
.nb:
        loop    .bit
        pop     cx
        inc     di
        dec     cx
        jmp     .byte
.done:
        mov     [a_crc], eax
        ret

do_add:
        mov     ah, 3Ch
        xor     cx, cx
        mov     dx, fname
        int     21h
        jc      .ret
        mov     [ofh], ax
        mov     dword [a_outpos], 0
        mov     word [a_count], 0
        mov     word [a_cdptr], cdbuf
        mov     ax, 3D00h
        mov     dx, addlist
        int     21h
        jc      .finish
        mov     bx, ax
        push    bx
        mov     ah, 3Fh
        mov     cx, TAILMAX-1
        mov     dx, tailbuf
        int     21h
        mov     [lgot], ax
        pop     bx
        mov     ah, 3Eh
        int     21h
        mov     si, tailbuf
        mov     ax, [lgot]
        add     ax, si
        mov     [lend], ax
.nl:
        cmp     si, [lend]
        jae     .finish
        mov     al, [si]
        or      al, al
        jz      .finish
        cmp     al, 0Dh
        je      .sk
        cmp     al, 0Ah
        je      .sk
        cmp     al, ' '
        je      .sk
        mov     di, srcpath
.cp:
        mov     al, [si]
        or      al, al
        jz      .pe
        cmp     al, 0Dh
        je      .pe
        cmp     al, 0Ah
        je      .pe
        mov     [di], al
        inc     si
        inc     di
        jmp     .cp
.pe:
        mov     byte [di], 0
        push    si
        call    add_one_file        ; clobbers si (basename_src)
        pop     si
        jmp     .nl
.sk:
        inc     si
        jmp     .nl
.finish:
        call    write_central_and_eocd
        mov     bx, [ofh]
        mov     ah, 3Eh
        int     21h
.ret:
        ret

; add the file named in srcpath to the open output zip
add_one_file:
        mov     ax, 3D00h
        mov     dx, srcpath
        int     21h
        jc      .ret
        mov     [sfh], ax
        mov     dword [a_crc], 0FFFFFFFFh
        mov     dword [a_size], 0
.p1:
        mov     bx, [sfh]
        mov     ah, 3Fh
        mov     cx, IBUF_SZ
        mov     dx, iobuf
        int     21h
        or      ax, ax
        jz      .p1d
        add     [a_size], ax
        adc     word [a_size+2], 0
        mov     cx, ax
        mov     di, iobuf
        call    crc_block
        jmp     .p1
.p1d:
        mov     eax, [a_crc]
        xor     eax, 0FFFFFFFFh
        mov     [a_crc], eax
        mov     eax, [a_outpos]
        mov     [a_lhoff], eax
        call    basename_src
        call    write_local_header
        mov     bx, [sfh]
        mov     ax, 4200h           ; rewind for the data copy
        xor     cx, cx
        xor     dx, dx
        int     21h
.p2:
        mov     bx, [sfh]
        mov     ah, 3Fh
        mov     cx, IBUF_SZ
        mov     dx, iobuf
        int     21h
        or      ax, ax
        jz      .p2d
        mov     cx, ax
        mov     dx, iobuf
        call    emit
        jmp     .p2
.p2d:
        mov     bx, [sfh]
        mov     ah, 3Eh
        int     21h
        call    append_central
        inc     word [a_count]
.ret:
        ret

; a_baseptr = basename of srcpath; a_namelen = its length
basename_src:
        mov     si, srcpath
        mov     [a_baseptr], si
.fb:
        mov     al, [si]
        or      al, al
        jz      .fe
        cmp     al, '\'
        je      .adv
        cmp     al, '/'
        je      .adv
        cmp     al, ':'
        je      .adv
        jmp     .nx
.adv:
        lea     bx, [si+1]
        mov     [a_baseptr], bx
.nx:
        inc     si
        jmp     .fb
.fe:
        mov     si, [a_baseptr]
        xor     cx, cx
.sl:
        mov     al, [si]
        or      al, al
        jz      .sd
        inc     si
        inc     cx
        jmp     .sl
.sd:
        mov     [a_namelen], cx
        ret

write_local_header:
        mov     di, lhdr
        mov     dword [di], 04034B50h
        mov     word [di+4], 0014h
        mov     word [di+6], 0
        mov     word [di+8], 0
        mov     word [di+10], 0
        mov     word [di+12], 0021h
        mov     eax, [a_crc]
        mov     [di+14], eax
        mov     eax, [a_size]
        mov     [di+18], eax
        mov     [di+22], eax
        mov     ax, [a_namelen]
        mov     [di+26], ax
        mov     word [di+28], 0
        mov     dx, lhdr
        mov     cx, 30
        call    emit
        mov     dx, [a_baseptr]
        mov     cx, [a_namelen]
        call    emit
        ret

append_central:
        mov     di, [a_cdptr]
        mov     dword [di], 02014B50h
        mov     word [di+4], 0014h
        mov     word [di+6], 0014h
        mov     word [di+8], 0
        mov     word [di+10], 0
        mov     word [di+12], 0
        mov     word [di+14], 0021h
        mov     eax, [a_crc]
        mov     [di+16], eax
        mov     eax, [a_size]
        mov     [di+20], eax
        mov     [di+24], eax
        mov     ax, [a_namelen]
        mov     [di+28], ax
        mov     word [di+30], 0
        mov     word [di+32], 0
        mov     word [di+34], 0
        mov     word [di+36], 0
        mov     dword [di+38], 0
        mov     eax, [a_lhoff]
        mov     [di+42], eax
        add     di, 46
        mov     si, [a_baseptr]
        mov     cx, [a_namelen]
.cn:
        jcxz    .cd
        mov     al, [si]
        mov     [di], al
        inc     si
        inc     di
        dec     cx
        jmp     .cn
.cd:
        mov     [a_cdptr], di
        ret

write_central_and_eocd:
        mov     eax, [a_outpos]
        mov     [a_cdstart], eax
        mov     cx, [a_cdptr]
        sub     cx, cdbuf
        mov     [a_cdsize], cx
        mov     dx, cdbuf
        call    emit
        mov     di, lhdr
        mov     dword [di], 06054B50h
        mov     word [di+4], 0
        mov     word [di+6], 0
        mov     ax, [a_count]
        mov     [di+8], ax
        mov     [di+10], ax
        mov     ax, [a_cdsize]
        mov     [di+12], ax
        mov     word [di+14], 0
        mov     eax, [a_cdstart]
        mov     [di+16], eax
        mov     word [di+20], 0
        mov     dx, lhdr
        mov     cx, 22
        call    emit
        ret

; ----------------------------------------------------------------------------
;  INFLATE (RFC 1951) -- streaming, 32 KB circular window (reuses cdbuf).
; ----------------------------------------------------------------------------

; next input byte -> al (0 at EOF); bounded by e_csize via fill_input.
getbyte:
        push    bx
        push    cx
        push    dx
        mov     bx, [ibpos]
        cmp     bx, [ibcnt]
        jb      .got
        call    fill_input
        mov     bx, [ibpos]
        cmp     bx, [ibcnt]
        jb      .got
        xor     al, al
        jmp     .done
.got:
        mov     al, [ibuf+bx]
        inc     word [ibpos]
.done:
        pop     dx
        pop     cx
        pop     bx
        ret

fill_input:
        mov     word [ibpos], 0
        mov     word [ibcnt], 0
        mov     ax, [e_csize]
        mov     dx, [e_csize+2]
        mov     cx, ax
        or      cx, dx
        jz      .ret
        mov     cx, IBUF_SZ
        or      dx, dx
        jnz     .full
        cmp     ax, IBUF_SZ
        jae     .full
        mov     cx, ax
.full:
        push    cx
        mov     bx, [fh]
        mov     ah, 3Fh
        mov     dx, ibuf
        int     21h
        pop     cx
        mov     [ibcnt], ax
        sub     [e_csize], ax
        sbb     word [e_csize+2], 0
.ret:
        ret

; getbits(need in CL, 0..16) -> AX ; preserves all other registers.
getbits:
        push    ebx
        push    ecx
        push    edx
        mov     ch, cl              ; need
.fill:
        mov     al, [bitcnt]
        cmp     al, ch
        jae     .have
        call    getbyte             ; al = byte
        movzx   ebx, al
        mov     cl, [bitcnt]
        shl     ebx, cl
        or      [bitbuf], ebx
        add     byte [bitcnt], 8
        jmp     .fill
.have:
        mov     cl, ch
        mov     eax, [bitbuf]
        mov     edx, [bitbuf]
        shr     edx, cl
        mov     [bitbuf], edx
        sub     [bitcnt], cl
        mov     edx, 1
        shl     edx, cl
        dec     edx
        and     eax, edx            ; mask to need bits
        pop     edx
        pop     ecx
        pop     ebx
        ret

; emit one byte (al): circular window + output buffer.
out_byte:
        push    bx
        mov     bx, [wpos]
        and     bx, 7FFFh
        mov     [win+bx], al
        inc     word [wpos]
        mov     bx, [obpos]
        mov     [obuf+bx], al
        inc     word [obpos]
        cmp     word [obpos], OBUF_SZ
        jb      .ret
        call    flush_out
.ret:
        pop     bx
        ret

flush_out:
        push    ax
        push    bx
        push    cx
        push    dx
        mov     cx, [obpos]
        or      cx, cx
        jz      .ret
        mov     bx, [ofh]
        mov     ah, 40h
        mov     dx, obuf
        int     21h
        mov     word [obpos], 0
.ret:
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; copy a back-reference: cx=length, dx=distance
do_copy:
.cl:
        jcxz    .ret
        mov     bx, [wpos]
        sub     bx, dx
        and     bx, 7FFFh
        mov     al, [win+bx]
        call    out_byte
        dec     cx
        jmp     .cl
.ret:
        ret

; decode one symbol using the huffman pointed to by dc_cnt_p / dc_sym_p -> ax
decode_sym:
        xor     bx, bx              ; code
        xor     dx, dx              ; first
        xor     bp, bp              ; index
        mov     cx, 1               ; len
.lp:
        push    cx
        mov     cl, 1
        call    getbits             ; ax = 1 bit
        pop     cx
        shl     bx, 1
        or      bl, al
        mov     si, [dc_cnt_p]
        mov     di, cx
        add     di, di
        add     si, di
        mov     ax, [si]            ; count[len]
        mov     si, bx
        sub     si, dx              ; code - first
        cmp     si, ax
        jb      .found
        add     bp, ax              ; index += count
        add     dx, ax
        add     dx, dx              ; first = (first+count)<<1
        inc     cx
        cmp     cx, 15
        jbe     .lp
        mov     ax, 0FFFFh
        ret
.found:
        add     bp, si              ; index + (code-first)
        mov     si, [dc_sym_p]
        mov     di, bp
        add     di, di
        add     si, di
        mov     ax, [si]
        ret

; build count[]+symbol[] from word lengths array
;   con_cnt_p, con_sym_p, con_len_p, con_n
construct:
        mov     di, [con_cnt_p]
        mov     cx, 16
        xor     ax, ax
        rep     stosw
        mov     si, [con_len_p]
        mov     cx, [con_n]
        mov     di, [con_cnt_p]
.cl:
        jcxz    .cd
        mov     ax, [si]
        add     ax, ax
        mov     bx, ax
        inc     word [di+bx]
        add     si, 2
        dec     cx
        jmp     .cl
.cd:
        xor     ax, ax
        mov     [offs+2], ax        ; offs[1]=0
        mov     cx, 1
.co:
        cmp     cx, 15
        jae     .coe
        mov     di, cx
        add     di, di
        mov     bx, [con_cnt_p]
        mov     ax, [bx+di]         ; count[len]
        add     ax, [offs+di]       ; offs[len]
        mov     [offs+di+2], ax     ; offs[len+1]
        inc     cx
        jmp     .co
.coe:
        mov     si, [con_len_p]
        xor     dx, dx              ; symbol
.cs:
        cmp     dx, [con_n]
        jae     .ret
        mov     ax, [si]            ; length
        or      ax, ax
        jz      .cn
        mov     di, ax
        add     di, di
        mov     bx, [offs+di]
        add     bx, bx
        mov     di, [con_sym_p]
        mov     [di+bx], dx
        mov     di, ax
        add     di, di
        inc     word [offs+di]
.cn:
        add     si, 2
        inc     dx
        jmp     .cs
.ret:
        ret

build_fixed:
        mov     di, lengths
        mov     cx, 144
        mov     ax, 8
        rep     stosw
        mov     cx, 112
        mov     ax, 9
        rep     stosw
        mov     cx, 24
        mov     ax, 7
        rep     stosw
        mov     cx, 8
        mov     ax, 8
        rep     stosw
        mov     word [con_cnt_p], lc_count
        mov     word [con_sym_p], lc_symbol
        mov     word [con_len_p], lengths
        mov     word [con_n], 288
        call    construct
        mov     di, lengths
        mov     cx, 30
        mov     ax, 5
        rep     stosw
        mov     word [con_cnt_p], dc_count
        mov     word [con_sym_p], dc_symbol
        mov     word [con_len_p], lengths
        mov     word [con_n], 30
        call    construct
        ret

build_dynamic:
        mov     cl, 5
        call    getbits
        add     ax, 257
        mov     [d_nlen], ax
        mov     cl, 5
        call    getbits
        inc     ax
        mov     [d_ndist], ax
        mov     cl, 4
        call    getbits
        add     ax, 4
        mov     [d_ncode], ax
        mov     di, cl_lengths
        mov     cx, 19
        xor     ax, ax
        rep     stosw
        mov     cx, [d_ncode]
        xor     si, si
.rd:
        cmp     si, cx
        jae     .rdone
        mov     cl, 3
        call    getbits
        mov     bl, [order+si]
        movzx   bx, bl
        add     bx, bx
        mov     [cl_lengths+bx], ax
        inc     si
        mov     cx, [d_ncode]
        jmp     .rd
.rdone:
        mov     word [con_cnt_p], clc_count
        mov     word [con_sym_p], clc_symbol
        mov     word [con_len_p], cl_lengths
        mov     word [con_n], 19
        call    construct
        mov     ax, [d_nlen]
        add     ax, [d_ndist]
        mov     [d_total], ax
        xor     si, si              ; lengths index (elements)
.rl:
        mov     ax, [d_total]
        cmp     si, ax
        jae     .rldone
        mov     word [dc_cnt_p], clc_count
        mov     word [dc_sym_p], clc_symbol
        push    si
        call    decode_sym
        pop     si
        cmp     ax, 16
        jb      .lit
        je      .rep16
        cmp     ax, 17
        je      .rep17
        ; symbol 18: repeat 0, 11 + getbits(7)
        mov     cl, 7
        call    getbits
        add     ax, 11
        mov     cx, ax
        xor     ax, ax
        jmp     .fillrep
.rep17:
        mov     cl, 3
        call    getbits
        add     ax, 3
        mov     cx, ax
        xor     ax, ax
        jmp     .fillrep
.rep16:
        mov     cl, 2
        call    getbits
        add     ax, 3
        mov     cx, ax
        mov     bx, si
        dec     bx
        add     bx, bx
        mov     ax, [lengths+bx]    ; previous length
        jmp     .fillrep
.lit:
        mov     bx, si
        add     bx, bx
        mov     [lengths+bx], ax
        inc     si
        jmp     .rl
.fillrep:
        jcxz    .rl
        mov     bx, si
        add     bx, bx
        mov     [lengths+bx], ax
        inc     si
        dec     cx
        mov     dx, [d_total]
        cmp     si, dx
        jae     .rldone
        jmp     .fillrep
.rldone:
        mov     word [con_cnt_p], lc_count
        mov     word [con_sym_p], lc_symbol
        mov     word [con_len_p], lengths
        mov     ax, [d_nlen]
        mov     [con_n], ax
        call    construct
        mov     ax, [d_nlen]
        add     ax, ax
        add     ax, lengths
        mov     [con_len_p], ax
        mov     word [con_cnt_p], dc_count
        mov     word [con_sym_p], dc_symbol
        mov     ax, [d_ndist]
        mov     [con_n], ax
        call    construct
        ret

; decode a sequence of literal/length codes until end-of-block (symbol 256)
inflate_codes:
.lp:
        mov     word [dc_cnt_p], lc_count
        mov     word [dc_sym_p], lc_symbol
        call    decode_sym
        cmp     ax, 256
        je      .ret
        ja      .length
        call    out_byte            ; literal (al)
        jmp     .lp
.length:
        cmp     ax, 285
        ja      .ret                ; malformed -> stop
        sub     ax, 257
        mov     bp, ax
        add     ax, ax
        mov     si, ax
        mov     bx, [lens+si]
        mov     [m_len], bx
        mov     cl, [lext+bp]
        or      cl, cl
        jz      .noxl
        call    getbits
        add     [m_len], ax
.noxl:
        mov     word [dc_cnt_p], dc_count
        mov     word [dc_sym_p], dc_symbol
        call    decode_sym
        cmp     ax, 29
        ja      .ret
        mov     bp, ax
        add     ax, ax
        mov     si, ax
        mov     bx, [dists+si]
        mov     [m_dist], bx
        mov     cl, [dext+bp]
        or      cl, cl
        jz      .noxd
        call    getbits
        add     [m_dist], ax
.noxd:
        mov     cx, [m_len]
        mov     dx, [m_dist]
        call    do_copy
        jmp     .lp
.ret:
        ret

inflate:
        mov     dword [bitbuf], 0
        mov     byte [bitcnt], 0
        mov     word [ibpos], 0
        mov     word [ibcnt], 0
        mov     word [wpos], 0
        mov     word [obpos], 0
.block:
        mov     cl, 1
        call    getbits
        mov     [bfinal], al
        mov     cl, 2
        call    getbits
        cmp     ax, 0
        je      .stored
        cmp     ax, 1
        je      .fixed
        cmp     ax, 2
        je      .dynamic
        ret                         ; reserved BTYPE -> stop
.fixed:
        call    build_fixed
        call    inflate_codes
        jmp     .next
.dynamic:
        call    build_dynamic
        call    inflate_codes
        jmp     .next
.stored:
        mov     byte [bitcnt], 0
        mov     dword [bitbuf], 0   ; discard the sub-byte remainder
        call    getbyte
        mov     bl, al              ; LEN low
        call    getbyte
        mov     bh, al              ; LEN high
        call    getbyte             ; NLEN low (ignored)
        call    getbyte             ; NLEN high (ignored)
        mov     cx, bx
.scopy:
        jcxz    .next
        call    getbyte
        call    out_byte
        dec     cx
        jmp     .scopy
.next:
        cmp     byte [bfinal], 0
        je      .block
        ret

; --- constant tables (RFC 1951) ---
lens    dw 3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99
        dw 115,131,163,195,227,258
lext    db 0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0
dists   dw 1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769
        dw 1025,1537,2049,3073,4097,6145,8193,12289,16385,24577
dext    db 0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13
order   db 16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15

section .bss
align 2
lmode       resb 1
xmode       resb 1
xallmode    resb 1
amode       resb 1
xindex      resw 1
destdir     resb 128
addlist     resb 128
srcpath     resb 128
sfh         resw 1
lgot        resw 1
lend        resw 1
a_crc       resd 1
a_size      resd 1
a_outpos    resd 1
a_lhoff     resd 1
a_cdstart   resd 1
a_cdsize    resw 1
a_count     resw 1
a_cdptr     resw 1
a_baseptr   resw 1
a_namelen   resw 1
tok1        resb 128
fname       resb 128
fh          resw 1
fsize_lo    resw 1
fsize_hi    resw 1
taillen     resw 1
tailgot     resw 1
cdgot       resw 1
zcount      resw 1
cdofs_lo    resw 1
cdofs_hi    resw 1
hiq         resw 1
numtmp      resb 16
linebuf     resb 160

; --- extraction state ---
filei       resw 1                  ; current FILE index while scanning
e_method    resw 1
e_csize     resd 1                  ; compressed size / remaining input budget
e_loff      resd 1                  ; local-header offset
e_doff      resd 1                  ; member data offset
e_name      resb 128
outpath     resb 160
lhdr        resb 32
ofh         resw 1

; --- INFLATE state ---
bitbuf      resd 1
bitcnt      resb 1
bfinal      resb 1
alignb 2
ibpos       resw 1
ibcnt       resw 1
wpos        resw 1                  ; circular-window write position
obpos       resw 1                  ; output-buffer fill
m_len       resw 1
m_dist      resw 1
d_nlen      resw 1
d_ndist     resw 1
d_ncode     resw 1
d_total     resw 1
con_cnt_p   resw 1
con_sym_p   resw 1
con_len_p   resw 1
con_n       resw 1
dc_cnt_p    resw 1
dc_sym_p    resw 1
lc_count    resw 16
lc_symbol   resw 288
dc_count    resw 16
dc_symbol   resw 32
clc_count   resw 16
clc_symbol  resw 19
cl_lengths  resw 19
lengths     resw 320
offs        resw 17
ibuf        resb IBUF_SZ
obuf        resb OBUF_SZ
iobuf       resb IBUF_SZ

tailbuf     resb TAILMAX
cdbuf       resb CDMAX
win         equ cdbuf               ; 32 KB INFLATE window reuses cdbuf (dead by then)
stackspace  resb 1024
stacktop:
