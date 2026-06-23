; ============================================================================
;  CCWAV.COM  --  Claude Commander's WAV player (PCM via Sound Blaster)
;
;  Usage:  CCWAV <file.wav>     play the WAV via the Sound Blaster (ESC aborts)
;          CCWAV /D <file.wav>  parse only -> CCWAV.RAW (diagnostic dump:
;                               rate(4) channels(2) bits(2) datasize(4) then
;                               the raw PCM data bytes), no audio
;
;  Walks the RIFF/WAVE chunk chain (skipping unknown chunks like LIST/fact),
;  reads the "fmt " chunk and the "data" chunk. Plays 8-bit or 16-bit, mono or
;  stereo PCM by down-mixing to 8-bit unsigned mono and streaming it to the
;  SB's single-cycle 8-bit DMA in page-safe blocks (works on SB / SB Pro /
;  SB16; base + DMA channel come from the BLASTER env var, default A220 D1).
;  cc maps it through cc.ini [view] (wav = CCWAV).
;
;  Assemble:  nasm -f bin cwav.asm -o ccwav.com
; ============================================================================
        org     100h
start:
        cld
        mov     sp, stacktop
        mov     byte [dumpmode], 0
        mov     byte [fname], 0
        call    parse_args
        cmp     byte [fname], 0
        je      .usage
        mov     ax, 3D00h
        mov     dx, fname
        int     21h
        jc      .noopen
        mov     [fh], ax
        call    seek0
        call    parse_wav           ; fills rate/channels/bits/dataoff/datasize
        jc      .badfmt
        cmp     byte [dumpmode], 0
        jne     .dump
        call    play_wav
        jmp     .close_ok
.dump:
        call    dump_wav
.close_ok:
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
.badfmt:
        mov     bx, [fh]
        mov     ah, 3Eh
        int     21h
        mov     si, s_badfmt
.die:
        call    puts
        mov     ax, 4C01h
        int     21h

; ============================================================================
;  Buffered input with absolute-position tracking
; ============================================================================
seek0:
        mov     bx, [fh]
        mov     ax, 4200h
        xor     cx, cx
        xor     dx, dx
        int     21h
        mov     dword [filebase], 0
        mov     word [iolen], 0
        mov     word [iopos], 0
        ret

; seek to dx:ax absolute, force refill, set filebase
seek_set:
        push    ax
        push    dx
        mov     cx, dx
        mov     dx, ax
        mov     bx, [fh]
        mov     ax, 4200h
        int     21h
        pop     dx
        pop     ax
        movzx   ebx, dx
        shl     ebx, 16
        movzx   ecx, ax
        or      ebx, ecx
        mov     [filebase], ebx
        mov     word [iolen], 0
        mov     word [iopos], 0
        ret

iorefill:
        ; advance filebase past the buffer we just exhausted
        movzx   eax, word [iolen]
        add     [filebase], eax
        mov     ah, 3Fh
        mov     bx, [fh]
        mov     cx, IOBUF_SZ
        mov     dx, iobuf
        int     21h
        mov     [iolen], ax
        mov     word [iopos], 0
        ret

; getb -> al = next byte, CF=1 on EOF. Preserves bx,cx,dx (iorefill/int21h
; clobber cx & dx; callers rely on them across getb).
getb:
        push    bx
        push    cx
        push    dx
.again:
        mov     bx, [iopos]
        cmp     bx, [iolen]
        jb      .have
        call    iorefill
        cmp     word [iolen], 0
        je      .eof
        jmp     .again
.have:
        mov     al, [iobuf+bx]
        inc     word [iopos]
        clc
        jmp     .done
.eof:
        xor     al, al
        stc
.done:
        pop     dx
        pop     cx
        pop     bx
        ret

; getw -> ax = little-endian word
getw:
        call    getb
        mov     ah, al
        call    getb
        xchg    al, ah
        ret

; getdw -> eax = little-endian dword (CF=1 if first byte at EOF).
; Accumulate in ebx, NOT eax: getb returns in al (= eax's low byte) and would
; clobber the accumulator on each call. getb preserves bx/cx/dx, so ebx/ecx
; survive across the calls.
getdw:
        call    getb
        jc      .eof
        movzx   ebx, al
        call    getb
        movzx   ecx, al
        shl     ecx, 8
        or      ebx, ecx
        call    getb
        movzx   ecx, al
        shl     ecx, 16
        or      ebx, ecx
        call    getb
        movzx   ecx, al
        shl     ecx, 24
        or      ebx, ecx
        mov     eax, ebx
        clc
        ret
.eof:
        stc
        ret

; cur_filepos -> dx:ax = filebase + iopos (32-bit absolute)
cur_filepos:
        mov     eax, [filebase]
        movzx   ecx, word [iopos]
        add     eax, ecx
        mov     edx, eax
        shr     edx, 16
        ret

; ============================================================================
;  WAV parsing: walk chunks, capture fmt + data
; ============================================================================
parse_wav:
        mov     word [havefmt], 0
        call    getdw
        cmp     eax, 'RIFF'         ; "RIFF"
        jne     .bad
        call    getdw               ; riff size (ignored)
        call    getdw
        cmp     eax, 'WAVE'         ; "WAVE"
        jne     .bad
.chunk:
        call    getdw               ; chunk id
        jc      .endchunks
        mov     [ckid], eax
        call    getdw               ; chunk size
        mov     [cksize], eax
        mov     eax, [ckid]
        cmp     eax, 'fmt '         ; "fmt "
        je      .fmt
        cmp     eax, 'data'         ; "data"
        je      .data
        call    skip_chunk
        jmp     .chunk
.fmt:
        call    getw                ; audio format
        mov     [afmt], ax
        call    getw                ; channels
        mov     [channels], ax
        call    getdw               ; sample rate
        mov     [rate], eax
        call    getdw               ; byte rate (ignored)
        call    getw                ; block align (ignored)
        call    getw                ; bits per sample
        mov     [wbits], ax
        mov     word [havefmt], 1
        mov     eax, [cksize]       ; skip any extra fmt bytes
        sub     eax, 16
        jbe     .chunk
        mov     [cksize], eax
        call    skip_chunk
        jmp     .chunk
.data:
        call    cur_filepos         ; dx:ax = data offset
        mov     [dataoff], ax
        mov     [dataoff+2], dx
        mov     eax, [cksize]
        mov     [datasize], eax
        cmp     word [havefmt], 0
        je      .bad
        clc
        ret
.endchunks:
.bad:
        stc
        ret

; advance the file position by [cksize] bytes (rounded up to even)
skip_chunk:
        mov     eax, [cksize]
        test    al, 1
        jz      .even
        inc     eax
.even:
        push    eax
        call    cur_filepos         ; dx:ax = current pos
        movzx   ebx, ax
        movzx   ecx, dx
        shl     ecx, 16
        or      ebx, ecx            ; ebx = current pos (32-bit)
        pop     eax                 ; skip amount
        add     ebx, eax            ; ebx = new pos
        mov     eax, ebx
        mov     edx, ebx
        shr     edx, 16             ; dx = high word
        call    seek_set
        ret

; ============================================================================
;  /D dump: CCWAV.RAW = rate(4) channels(2) bits(2) datasize(4) + PCM data
; ============================================================================
dump_wav:
        mov     ah, 3Ch
        xor     cx, cx
        mov     dx, s_rawname
        int     21h
        jc      .ret
        mov     [ofh], ax
        mov     eax, [rate]
        mov     [hdrout], eax
        mov     ax, [channels]
        mov     [hdrout+4], ax
        mov     ax, [wbits]
        mov     [hdrout+6], ax
        mov     eax, [datasize]
        mov     [hdrout+8], eax
        mov     bx, [ofh]
        mov     ah, 40h
        mov     cx, 12
        mov     dx, hdrout
        int     21h
        ; seek source to dataoff
        mov     ax, [dataoff]
        mov     dx, [dataoff+2]
        mov     cx, dx
        mov     dx, ax
        mov     bx, [fh]
        mov     ax, 4200h
        int     21h
        mov     eax, [datasize]
        mov     [remaining], eax
.loop:
        mov     eax, [remaining]
        test    eax, eax
        jz      .done
        mov     cx, PCMBUF_SZ
        cmp     eax, PCMBUF_SZ
        jae     .rd
        mov     cx, ax
.rd:
        push    cx
        mov     ah, 3Fh
        mov     bx, [fh]
        mov     dx, pcmbuf
        int     21h                 ; cx = block size
        pop     cx
        or      ax, ax
        jz      .done
        mov     cx, ax
        mov     ah, 40h
        mov     bx, [ofh]
        mov     dx, pcmbuf
        int     21h
        movzx   eax, cx
        sub     [remaining], eax
        jmp     .loop
.done:
        mov     bx, [ofh]
        mov     ah, 3Eh
        int     21h
.ret:
        ret

; ============================================================================
;  Sound Blaster playback (8-bit single-cycle DMA, down-mixed to mono)
; ============================================================================
play_wav:
        ; only 8/16-bit PCM is supported; bail quietly otherwise
        mov     ax, [wbits]
        cmp     ax, 8
        je      .ok
        cmp     ax, 16
        je      .ok
        ret
.ok:
        call    parse_blaster       ; sets sbbase, dmachan
        call    sb_reset
        jc      .ret                ; no card -> silent
        ; seek source to data
        mov     ax, [dataoff]
        mov     dx, [dataoff+2]
        mov     cx, dx
        mov     dx, ax
        mov     bx, [fh]
        mov     ax, 4200h
        int     21h
        mov     eax, [datasize]
        mov     [remaining], eax
        ; physical address of dmabuf
        xor     eax, eax
        mov     ax, cs
        shl     eax, 4
        mov     ebx, dmabuf
        add     eax, ebx
        mov     [dmaphys], eax
        ; speaker on
        mov     al, 0D1h
        call    dsp_write
        ; time constant from rate (mono 8-bit): TC = 256 - 1000000/rate
        mov     eax, 1000000
        xor     edx, edx
        mov     ebx, [rate]
        or      ebx, ebx
        jnz     .haverate
        mov     ebx, 11025
.haverate:
        div     ebx                 ; eax = 1000000/rate
        mov     ecx, 256
        sub     ecx, eax
        mov     [timeconst], cl
        ; set the DSP sample rate via time constant once
        mov     al, 40h
        call    dsp_write
        mov     al, [timeconst]
        call    dsp_write
.block:
        mov     eax, [remaining]
        test    eax, eax
        jz      .ret
        ; check for ESC keypress -> abort
        mov     ah, 1
        int     16h
        jz      .nokey
        xor     ah, ah
        int     16h
        cmp     al, 1Bh
        je      .ret
.nokey:
        call    fill_block          ; -> [blocklen] = output bytes in dmabuf
        cmp     word [blocklen], 0
        je      .ret
        call    dma_program
        ; single-cycle 8-bit output: DSP 0x14, (len-1) lo, hi
        mov     al, 14h
        call    dsp_write
        mov     ax, [blocklen]
        dec     ax
        mov     [dsplen], ax
        mov     al, [dsplen]
        call    dsp_write
        mov     al, [dsplen+1]
        call    dsp_write
        call    dma_wait
        jmp     .block
.ret:
        ; speaker off
        mov     al, 0D3h
        call    dsp_write
        ret

; fill dmabuf with up to BLOCK_SAMPLES mono 8-bit samples converted from the
; source PCM; [blocklen] = bytes produced. Honours the DMA 64 KB page limit.
fill_block:
        ; max output samples this block, capped to stay inside one DMA page
        mov     ax, BLOCK_SAMPLES
        mov     [maxout], ax
        mov     eax, [dmaphys]
        and     eax, 0FFFFh
        mov     ebx, 10000h
        sub     ebx, eax            ; bytes to end of 64 KB page
        cmp     ebx, BLOCK_SAMPLES
        jae     .capok
        mov     [maxout], bx
.capok:
        mov     word [blocklen], 0
        mov     di, dmabuf
.more:
        mov     ax, [blocklen]
        cmp     ax, [maxout]
        jae     .full
        mov     eax, [remaining]
        test    eax, eax
        jz      .full
        call    src_sample          ; al = next mono 8-bit unsigned sample
        jc      .full
        mov     [di], al
        inc     di
        inc     word [blocklen]
        jmp     .more
.full:
        ret

; produce one mono 8-bit unsigned sample from the source stream into al.
; consumes channels*(bits/8) bytes of source; CF=1 at EOF. Updates remaining.
; (src_byte preserves bx/cx/dx so accumulators here survive across the call.)
src_sample:
        mov     cx, [channels]
        or      cx, cx
        jnz     .havech
        mov     cx, 1
.havech:
        cmp     word [wbits], 16
        je      .b16
        ; 8-bit unsigned: average channels
        xor     bx, bx              ; accumulator
        mov     bp, cx              ; channel count
.s8:
        call    src_byte
        jc      .eof
        movzx   ax, al
        add     bx, ax
        dec     bp
        jnz     .s8
        mov     ax, bx
        xor     dx, dx
        div     cx                  ; ax = average (0..255)
        clc
        ret
.b16:
        ; 16-bit signed: average channels, convert to unsigned 8-bit
        xor     ebx, ebx            ; signed accumulator (32-bit)
        mov     bp, cx
.s16:
        call    src_byte            ; low byte
        jc      .eof
        mov     dl, al
        call    src_byte            ; high byte
        jc      .eof
        mov     dh, al
        movsx   esi, dx             ; sign-extend the 16-bit sample
        add     ebx, esi
        dec     bp
        jnz     .s16
        movzx   ecx, cx             ; channel count
        mov     eax, ebx
        cdq
        idiv    ecx                 ; eax = signed average
        sar     eax, 8
        add     eax, 128            ; -> unsigned 8-bit
        cmp     eax, 0
        jge     .lo_ok
        xor     eax, eax
.lo_ok:
        cmp     eax, 255
        jle     .hi_ok
        mov     eax, 255
.hi_ok:
        clc
        ret
.eof:
        stc
        ret

; src_byte -> al = next source data byte, decrement remaining; CF=1 at EOF.
; Preserves bx,cx,dx so src_sample's accumulators are not clobbered.
src_byte:
        push    bx
        push    cx
        push    dx
        mov     eax, [remaining]
        test    eax, eax
        jz      .eof
        mov     bx, [srcpos]
        cmp     bx, [srclen]
        jb      .have
        call    src_refill
        cmp     word [srclen], 0
        je      .eof
        mov     bx, [srcpos]
.have:
        mov     al, [srcbuf+bx]
        inc     word [srcpos]
        dec     dword [remaining]
        clc
        jmp     .done
.eof:
        stc
.done:
        pop     dx
        pop     cx
        pop     bx
        ret

src_refill:
        mov     ah, 3Fh
        mov     bx, [fh]
        mov     cx, SRCBUF_SZ
        mov     dx, srcbuf
        int     21h
        mov     [srclen], ax
        mov     word [srcpos], 0
        ret

; ============================================================================
;  DMA + DSP helpers
; ============================================================================
; program the 8-bit DMA channel for a single-cycle read of [blocklen] bytes
dma_program:
        mov     bl, [dmachan]
        ; mask channel
        mov     al, bl
        or      al, 04h
        mov     dx, 0Ah
        out     dx, al
        ; clear byte-pointer flip-flop
        xor     al, al
        mov     dx, 0Ch
        out     dx, al
        ; mode: single, read, channel
        mov     al, bl
        or      al, 48h
        mov     dx, 0Bh
        out     dx, al
        ; base address (offset within page) -> port chan*2
        movzx   si, bl
        shl     si, 1
        mov     dx, si              ; addr port = chan*2
        mov     eax, [dmaphys]
        out     dx, al              ; low
        mov     al, ah
        out     dx, al              ; high
        ; count = blocklen-1 -> port chan*2+1
        mov     dx, si
        inc     dx
        mov     ax, [blocklen]
        dec     ax
        out     dx, al              ; low
        mov     al, ah
        out     dx, al              ; high
        ; page register
        movzx   bx, byte [dmachan]
        mov     al, [dma_pageport+bx]
        mov     dl, al
        xor     dh, dh
        mov     eax, [dmaphys]
        shr     eax, 16
        out     dx, al
        ; unmask channel
        mov     al, [dmachan]
        mov     dx, 0Ah
        out     dx, al
        ret

; wait for the single-cycle transfer to finish by polling the DMA count
; (terminal count wraps to 0xFFFF). Times out; ESC also aborts.
dma_wait:
        mov     ecx, 8000000        ; spin cap (fallback if TC never seen)
.poll:
        ; latch + read current count
        xor     al, al
        mov     dx, 0Ch
        out     dx, al              ; clear flip-flop
        movzx   si, byte [dmachan]
        shl     si, 1
        inc     si                  ; count port = chan*2+1
        mov     dx, si
        in      al, dx
        mov     bl, al
        in      al, dx
        mov     bh, al              ; bx = current count
        cmp     bx, 0FFFFh
        je      .done
        ; check ESC only occasionally (int 16h is expensive)
        test    cx, 0FFFh
        jnz     .nokey
        mov     ah, 1
        int     16h
        jz      .nokey
        xor     ah, ah
        int     16h
        cmp     al, 1Bh
        je      .abort
.nokey:
        dec     ecx
        jnz     .poll
.done:
        clc
        ret
.abort:
        mov     dword [remaining], 0    ; drain so the main loop stops
        stc
        ret

; reset the DSP; CF=1 if no card responds
sb_reset:
        mov     dx, [sbbase]
        add     dx, 6
        mov     al, 1
        out     dx, al
        ; short delay
        mov     cx, 8
.d1:
        in      al, dx
        loop    .d1
        xor     al, al
        out     dx, al
        ; read 0xAA from base+0xA when base+0xE bit7 set
        mov     di, 256
.wait:
        mov     dx, [sbbase]
        add     dx, 0Eh
        in      al, dx
        test    al, 80h
        jz      .next
        mov     dx, [sbbase]
        add     dx, 0Ah
        in      al, dx
        cmp     al, 0AAh
        je      .ok
.next:
        dec     di
        jnz     .wait
        stc
        ret
.ok:
        clc
        ret

; write al to the DSP (poll write-status base+0xC bit7)
dsp_write:
        mov     ah, al
.busy:
        mov     dx, [sbbase]
        add     dx, 0Ch
        in      al, dx
        test    al, 80h
        jnz     .busy
        mov     al, ah
        out     dx, al
        ret

; ============================================================================
;  BLASTER env parse -> sbbase, dmachan (defaults A220 D1)
; ============================================================================
parse_blaster:
        mov     word [sbbase], 220h
        mov     byte [dmachan], 1
        ; environment segment from PSP:2Ch
        mov     ax, [2Ch]
        or      ax, ax
        jz      .done
        mov     es, ax
        xor     di, di
.scan:
        mov     al, [es:di]
        or      al, al
        jz      .nul                ; NUL between/after vars
        ; try to match "BLASTER=" starting at di
        push    di
        mov     si, s_blaster
.cmp:
        mov     bl, [si]
        or      bl, bl
        jz      .found              ; whole prefix matched
        mov     al, [es:di]
        cmp     al, bl
        jne     .nope
        inc     si
        inc     di
        jmp     .cmp
.nope:
        pop     di
        inc     di
        jmp     .scan
.nul:
        inc     di
        mov     al, [es:di]
        or      al, al
        jz      .done               ; double NUL = end of environment
        jmp     .scan
.found:
        pop     ax                  ; discard saved start; di is past prefix
.tok:
        mov     al, [es:di]
        or      al, al
        jz      .done
        cmp     al, 'A'
        je      .base
        cmp     al, 'a'
        je      .base
        cmp     al, 'D'
        je      .dma
        cmp     al, 'd'
        je      .dma
        inc     di
        jmp     .tok
.base:
        inc     di
        call    hexword_es          ; -> ax
        mov     [sbbase], ax
        jmp     .tok
.dma:
        inc     di
        mov     al, [es:di]
        sub     al, '0'
        mov     [dmachan], al
        inc     di
        jmp     .tok
.done:
        ret

; parse a hex word at es:di (advances di past hex digits) -> ax
hexword_es:
        xor     bx, bx
.hx:
        mov     al, [es:di]
        ; 0-9
        cmp     al, '0'
        jb      .end
        cmp     al, '9'
        jbe     .dig
        and     al, 0DFh            ; upper
        cmp     al, 'A'
        jb      .end
        cmp     al, 'F'
        ja      .end
        sub     al, 'A'-10
        jmp     .acc
.dig:
        sub     al, '0'
.acc:
        movzx   cx, al
        shl     bx, 4
        add     bx, cx
        inc     di
        jmp     .hx
.end:
        mov     ax, bx
        ret

; ============================================================================
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
        cmp     byte [si], '/'
        jne     .name
        inc     si
        mov     al, [si]
        and     al, 0DFh
        cmp     al, 'D'
        jne     .name
        mov     byte [dumpmode], 1
        inc     si
        call    skip_sp
.name:
        mov     di, fname
.cp:
        mov     al, [si]
        or      al, al
        jz      .d
        cmp     al, ' '
        je      .d
        mov     [di], al
        inc     si
        inc     di
        jmp     .cp
.d:
        mov     byte [di], 0
        ret

skip_sp:
        cmp     byte [si], ' '
        jne     .d
        inc     si
        jmp     skip_sp
.d:     ret

; ============================================================================
s_usage     db 'Usage: CCWAV <file.wav>',0Dh,0Ah,0
s_noopen    db 'CCWAV: cannot open file',0Dh,0Ah,0
s_badfmt    db 'CCWAV: not a PCM WAV file',0Dh,0Ah,0
s_rawname   db 'CCWAV.RAW',0
s_blaster   db 'BLASTER=',0
dma_pageport db 87h, 83h, 81h, 82h     ; page registers for DMA ch 0..3

IOBUF_SZ    equ 1024
SRCBUF_SZ   equ 8192
PCMBUF_SZ   equ 8192
BLOCK_SAMPLES equ 8192

section .bss
alignb 2
dumpmode    resb 1
fname       resb 128
fh          resw 1
ofh         resw 1
filebase    resd 1
iopos       resw 1
iolen       resw 1
; WAV fields
ckid        resd 1
cksize      resd 1
afmt        resw 1
channels    resw 1
rate        resd 1
wbits       resw 1
havefmt     resw 1
dataoff     resd 1
datasize    resd 1
remaining   resd 1
hdrout      resb 16
; source streaming
srcpos      resw 1
srclen      resw 1
; SB / DMA state
sbbase      resw 1
dmachan     resb 1
timeconst   resb 1
dmaphys     resd 1
blocklen    resw 1
maxout      resw 1
dsplen      resw 1
alignb 2
iobuf       resb IOBUF_SZ
srcbuf      resb SRCBUF_SZ
pcmbuf      resb PCMBUF_SZ
dmabuf      resb BLOCK_SAMPLES
stackspace  resb 1024
stacktop:
