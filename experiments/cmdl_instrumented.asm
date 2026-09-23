; ============================================================================
;  CMDL.ASM  ->  CCMDL.COM   --  Quake Alias .mdl viewer for "Claude Commander"
; ----------------------------------------------------------------------------
;  BUILD: nasm -f bin cmdl.asm -o CCMDL.COM     (16-bit real-mode .COM)
;
;  The rendering core (streaming .mdl loader, trivertx unpack with axis remap,
;  camera/projection, backface cull, painter sort, flat grayscale shade,
;  double-buffer + vsync blit, 2-pose streaming LERP animation) is ported
;  VERBATIM from the verified ASMQuake engine:
;      C:\LLM\DOS\ASMQuake\src\m4_anim.asm  +  vga.inc
;  Do not "fix" the math; it renders an upright soldier correctly.
;
;  cc viewer convention:
;      - filename comes from the PSP command tail (81h..).
;      - switch to VGA mode 13h only after a successful parse.
;      - ESC / Q / F3 restore 80x25 text mode and INT 21h 4Ch back to cc.
;
;  Invocation forms:
;      CCMDL <file.mdl>
;      CCMDL <container.pak> <index>
;          -> read a model embedded inside a Quake .pak by its 0-based
;             directory index (matching CCPAK's "L" listing order). This is
;             cc's generic in-container F3 protocol (mod/vfs.inc's vfs_view:
;             "<viewhelper> <container> <index>"), the same convention every
;             [open] container uses for F3 without extracting. CCMDL opens
;             the .pak itself, reads the directory entry at <index> to get
;             the model's file offset, and the streaming loader adds that
;             offset as a base to every lseek and treats that region as the
;             file.
;
;  Controls:
;      ESC / Q / F3   return to cc
;      Left / Right   yaw the model
;      Up / Down      pitch the model
;      Space          toggle auto-spin (default off -> static upright view)
;      A              toggle animation playback (default off)
;      N / P          step to next / previous frame (pauses animation)
;
;  Initial view is STATIC + UPRIGHT (angX=0, fixed angY for a 3/4 view), like
;  the fixed m3 static pose; the user opts into spin / animation.
; ============================================================================

BITS 16
org  0x100
jmp  start                      ; MUST be first: skip the included subroutines

; ---- VGA constants (inlined from vga.inc to stay self-contained) ----------
VGA_SEG     equ 0A000h
SCREEN_W    equ 320
SCREEN_H    equ 200
SCREEN_SZ   equ SCREEN_W*SCREEN_H        ; 64000

; ---- DEBUG INSTRUMENTATION (cmdl_instrumented.asm / CCMDL_DBG.COM only) ----
; Progress markers written to guest-physical 0xAFA00+ (VGA_SEG:0xFA00), just
; past the 64000/0xFA00-byte visible mode-13h framebuffer, still inside the
; A0000-AFFFF VRAM window. FS is used as the marker segment (armed once at
; `start:`) since FS is never touched anywhere else in this file. See
; ccmdl-rig-results.md instrumentation plan for the full marker map.
MARK_BASE   equ 0FA00h        ; -> guest physical 0xAFA00

; ---- renderer budget (from m4_anim.asm) -----------------------------------
MAXVERTS    equ 600
MAXTRIS     equ 1024
MAXPOSES    equ 256
AMBIENT     equ 48
DIFFUSE     equ 207

%macro SWAPW 1
    mov     ax, [%1+si]
    mov     cx, [%1+di]
    mov     [%1+si], cx
    mov     [%1+di], ax
%endmacro
%macro SWAPPT 4
    mov     ax, [%1]
    mov     cx, [%3]
    mov     [%1], cx
    mov     [%3], ax
    mov     ax, [%2]
    mov     cx, [%4]
    mov     [%2], cx
    mov     [%4], ax
%endmacro

; ===========================================================================
;  VGA helpers (verbatim from vga.inc)
; ===========================================================================
set_mode13:
    mov     ax, 0013h
    int     10h
    ret

set_text_mode:
    mov     ax, 0003h
    int     10h
    ret

wait_vsync:
    mov     dx, 03DAh
.vs_drain:
    in      al, dx
    test    al, 08h
    jnz     .vs_drain
.vs_start:
    in      al, dx
    test    al, 08h
    jz      .vs_start
    ret

set_gray_palette:
    mov     byte [fs:MARK_BASE+0Dh], 0Dh  ; M_SGP_ENTRY: set_gray_palette reached (CALL landed here)
    mov     dx, 03C8h
    xor     al, al
    out     dx, al
    inc     dx
    xor     bx, bx
.gp_loop:
    mov     al, bl
    shr     al, 2
    out     dx, al
    out     dx, al
    out     dx, al
    inc     bx
    mov     [fs:MARK_BASE+0Eh], bx        ; M_SGP_PROGRESS: word = # DAC entries written so far (0..256)
    cmp     bx, 256
    jb      .gp_loop
    mov     byte [fs:MARK_BASE+10h], 10h  ; M_SGP_EXIT: loop finished, about to RET
    ret

; ===========================================================================
;  ENTRY POINT
; ===========================================================================
start:
    cld
    mov     ax, VGA_SEG
    mov     fs, ax                        ; arm FS once; never reused elsewhere
    mov     byte [fs:MARK_BASE+0], 01h    ; M1: process entered
    call    parse_args
    cmp     byte [fname], 0
    jne     .have_file
    mov     si, s_usage
    call    puts
    mov     ax, 4C01h
    int     21h
.have_file:
    call    resolve_pak_index
    jc      .badpak

    ; -- shrink our block, then grab a 64000-byte back buffer --------------
    mov     ax, cs
    mov     es, ax
    mov     bx, 1000h
    mov     ah, 4Ah
    int     21h

    mov     bx, (SCREEN_SZ + 15) / 16
    mov     ah, 48h
    int     21h
    jc      .nomem
    mov     [bbseg], ax
    mov     byte [fs:MARK_BASE+1], 02h    ; M2: args/pak resolved, mem shrunk + backbuffer allocated

    ; -- open + parse the .mdl (streaming) BEFORE switching video ----------
    call    open_model
    jc      .open_err
    call    parse_model
    jc      .parse_err
    mov     byte [fs:MARK_BASE+2], 03h    ; M3: file opened + fully parsed (header/skins/tris/poses streamed)

    call    set_mode13
    mov     byte [fs:MARK_BASE+0Ch], 0Ch  ; M3b: set_mode13 (INT10h AX=13h) RETURNED to caller
    call    set_gray_palette
    mov     byte [fs:MARK_BASE+3], 04h    ; M4: VGA mode13h + palette set (cross-check vs BDA 0x449)

.frame:
    mov     ah, 01h
    int     16h
    jz      .nokey
    xor     ax, ax
    int     16h                 ; AL=ascii, AH=scan

    cmp     al, 1Bh             ; ESC
    je      .quit
    cmp     al, 'q'
    je      .quit
    cmp     al, 'Q'
    je      .quit
    cmp     al, ' '
    je      .k_space
    cmp     al, 'a'
    je      .k_anim
    cmp     al, 'A'
    je      .k_anim
    cmp     al, 'n'
    je      .k_next
    cmp     al, 'N'
    je      .k_next
    cmp     al, 'p'
    je      .k_prev
    cmp     al, 'P'
    je      .k_prev
    or      al, al
    jnz     .nokey              ; other ascii -> ignore
    ; extended key: scan in AH
    cmp     ah, 3Dh             ; F3
    je      .quit
    cmp     ah, 4Bh             ; Left
    je      .k_left
    cmp     ah, 4Dh             ; Right
    je      .k_right
    cmp     ah, 48h             ; Up
    je      .k_up
    cmp     ah, 50h             ; Down
    je      .k_down
    jmp     .nokey

.k_space:                       ; toggle auto-spin
    xor     byte [auto_tumble], 1
    cmp     byte [auto_tumble], 0
    je      .spin_off
    mov     eax, [spinY]
    mov     [dAngY], eax
    mov     eax, [spinX]
    mov     [dAngX], eax
    jmp     .nokey
.spin_off:
    xor     eax, eax
    mov     [dAngY], eax
    mov     [dAngX], eax
    jmp     .nokey

.k_anim:                        ; toggle animation playback
    xor     byte [auto_anim], 1
    jmp     .nokey

.k_next:                        ; next frame (pause animation)
    mov     byte [auto_anim], 0
    mov     ax, [poseidx]
    inc     ax
    cmp     ax, [nposes]
    jb      .nset
    xor     ax, ax
.nset:
    mov     [poseidx], ax
    mov     word [loaded_idx], 0FFFFh
    mov     dword [posefrac], 0
    jmp     .nokey

.k_prev:                        ; previous frame (pause animation)
    mov     byte [auto_anim], 0
    mov     ax, [poseidx]
    or      ax, ax
    jnz     .pdec
    mov     ax, [nposes]
.pdec:
    dec     ax
    mov     [poseidx], ax
    mov     word [loaded_idx], 0FFFFh
    mov     dword [posefrac], 0
    jmp     .nokey

.k_left:
    fld     dword [angY]
    fsub    dword [kstep]
    fstp    dword [angY]
    jmp     .nokey
.k_right:
    fld     dword [angY]
    fadd    dword [kstep]
    fstp    dword [angY]
    jmp     .nokey
.k_up:
    fld     dword [angX]
    fsub    dword [kstep]
    fstp    dword [angX]
    jmp     .nokey
.k_down:
    fld     dword [angX]
    fadd    dword [kstep]
    fstp    dword [angX]
    jmp     .nokey

.nokey:
    inc     byte [fs:MARK_BASE+4]         ; M5: per-iteration lap counter, wraps 0..255
    mov     es, [bbseg]
    call    clear_back

    call    update_angles
    mov     byte [fs:MARK_BASE+5], 05h    ; M6: update_angles done (2x FSINCOS survived)
    cmp     byte [auto_anim], 0
    je      .static_pose
    call    advance_pose        ; step time, stream poseA/poseB, set blendt
    jmp     .have_pose
.static_pose:
    mov     dword [blendt], 0   ; show pure poseidx (no lerp)
    call    ensure_loaded
.have_pose:
    call    unpack_pose
    mov     byte [fs:MARK_BASE+6], 06h    ; M7: unpack_pose done (per-vertex LERP + axis-remap FPU survived)
    call    transform_verts
    mov     byte [fs:MARK_BASE+7], 07h    ; M8: transform_verts done (rotate + direct-mem FDIV projection survived)
    call    build_vislist
    mov     byte [fs:MARK_BASE+8], 08h    ; M9: build_vislist done (FSQRT + register-form FDIVP lighting-normalize survived)
    mov     ax, [nvis]
    mov     [fs:MARK_BASE+020h], ax       ; bonus: word @ 0xAFA20 = triangle-visible count this frame
    call    sort_vislist
    call    draw_vislist
    mov     byte [fs:MARK_BASE+9], 09h    ; M10: sort+draw done (rasterized into BACK buffer, not yet on screen)

    call    wait_vsync
    mov     byte [fs:MARK_BASE+0Ah], 0Ah  ; M11: wait_vsync RETURNED
    call    flip
    mov     byte [fs:MARK_BASE+0Bh], 0Bh  ; M12: flip done -- frame fully committed to the real framebuffer
    jmp     .frame

.quit:
    mov     bx, [fhandle]
    or      bx, bx
    jz      .noclose
    mov     ah, 3Eh
    int     21h
.noclose:
    call    set_text_mode
    mov     ax, 4C00h
    int     21h

.badpak:
    mov     si, s_badpak
    call    puts
    mov     ax, 4C01h
    int     21h
.nomem:
    mov     si, s_nomem
    call    puts
    mov     ax, 4C01h
    int     21h
.open_err:
    mov     si, s_noopen
    call    puts
    mov     ax, 4C01h
    int     21h
.parse_err:
    mov     bx, [fhandle]
    or      bx, bx
    jz      .pe_msg
    mov     ah, 3Eh
    int     21h
.pe_msg:
    mov     si, s_badfmt
    call    puts
    mov     ax, 4C01h
    int     21h

; ===========================================================================
;  parse_args - read PSP tail (81h..): first token = fname; an optional
;  second decimal token = a 0-based PAK directory index (cc's generic
;  in-container F3 protocol -- see the header comment). has_idx=1 if a
;  second token was present. fname[0]=0 if no filename present.
; ===========================================================================
parse_args:
    ; terminate the tail at CR
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
    mov     byte [fname], 0
    mov     byte [has_idx], 0
    mov     si, 81h
    call    skip_sp
    mov     di, fname
.cpf:
    mov     al, [si]
    or      al, al
    jz      .fdone
    cmp     al, ' '
    je      .fdone
    mov     [di], al
    inc     si
    inc     di
    jmp     .cpf
.fdone:
    mov     byte [di], 0
    call    skip_sp
    cmp     byte [si], 0
    je      .adone
    call    parse_u32           ; -> EDX (decimal index)
    mov     [pak_idx], edx
    mov     byte [has_idx], 1
.adone:
    ret

skip_sp:
    cmp     byte [si], ' '
    jne     .d
    inc     si
    jmp     skip_sp
.d: ret

; parse_u32 - read decimal digits at DS:SI into EDX, advance SI.
parse_u32:
    xor     edx, edx
.pd:
    mov     al, [si]
    cmp     al, '0'
    jb      .pdone
    cmp     al, '9'
    ja      .pdone
    sub     al, '0'
    movzx   ebx, al
    imul    edx, edx, 10
    add     edx, ebx
    inc     si
    jmp     .pd
.pdone:
    ret

; ===========================================================================
;  resolve_pak_index - if has_idx, open fname as a PAK container, verify its
;  header, and read directory entry [pak_idx] to compute fbase (filepos) so
;  the streaming loader reads the model straight out of the .pak (see
;  seek_cursor). flen is set from the entry's filelen (informational).
;  No-op (fbase/flen stay 0) in plain-file mode. CF=1 on error.
; ===========================================================================
resolve_pak_index:
    cmp     byte [has_idx], 0
    je      .ok
    mov     dx, fname
    mov     ax, 3D00h
    int     21h
    jc      .err
    mov     [pfh], ax
    mov     bx, ax
    mov     ah, 3Fh
    mov     cx, 12
    mov     dx, pak_hdr
    int     21h
    jc      .err_close
    cmp     ax, 12
    jne     .err_close
    cmp     byte [pak_hdr+0], 'P'
    jne     .err_close
    cmp     byte [pak_hdr+1], 'A'
    jne     .err_close
    cmp     byte [pak_hdr+2], 'C'
    jne     .err_close
    cmp     byte [pak_hdr+3], 'K'
    jne     .err_close
    mov     eax, [pak_hdr+8]        ; dirlen
    shr     eax, 6                  ; -> entry count
    cmp     eax, [pak_idx]
    jbe     .err_close              ; pak_idx >= count -> out of range
    mov     eax, [pak_idx]
    imul    eax, eax, 64
    add     eax, [pak_hdr+4]        ; + dirofs
    add     eax, 56                 ; + E_FPOS field offset within the record
    mov     [seek_tmp], eax
    mov     bx, [pfh]
    mov     ah, 42h
    xor     al, al
    mov     dx, word [seek_tmp]
    mov     cx, word [seek_tmp+2]
    int     21h
    jc      .err_close
    mov     bx, [pfh]
    mov     ah, 3Fh
    mov     cx, 8                   ; filepos (4) + filelen (4)
    mov     dx, entry_pair
    int     21h
    jc      .err_close
    cmp     ax, 8
    jne     .err_close
    mov     eax, [entry_pair]
    mov     [fbase], eax
    mov     eax, [entry_pair+4]
    mov     [flen], eax
    mov     bx, [pfh]
    mov     ah, 3Eh
    int     21h
.ok:
    clc
    ret
.err_close:
    mov     bx, [pfh]
    mov     ah, 3Eh
    int     21h
.err:
    stc
    ret

; puts - write ASCIIZ string at DS:SI to stdout (handle 1).
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
    jcxz    .ret
    mov     ah, 40h
    mov     bx, 1
    mov     dx, si
    int     21h
.ret:
    ret

; ===========================================================================
; open_model - open FNAME for read, keep handle open for streaming.
; ===========================================================================
open_model:
    mov     dx, fname
    mov     ax, 3D00h
    int     21h
    jc      .oerr
    mov     [fhandle], ax
    mov     word [fcursor], 0
    mov     word [fcursor+2], 0
    clc
    ret
.oerr:
    stc
    ret

; ===========================================================================
; seek_cursor - lseek to (fbase + fcursor), method 0.  fbase is the PAK base
;   offset (0 in plain-file mode); fcursor is relative to the model region.
; ===========================================================================
seek_cursor:
    push    ax
    push    bx
    push    cx
    push    dx
    mov     ah, 42h
    xor     al, al
    mov     bx, [fhandle]
    mov     dx, [fcursor]
    mov     cx, [fcursor+2]
    add     dx, [fbase]
    adc     cx, [fbase+2]
    int     21h
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

; ===========================================================================
; read_chunk - seek to fcursor, read CX bytes into DS:DX, advance fcursor.
; ===========================================================================
read_chunk:
    call    seek_cursor
    mov     bx, [fhandle]
    mov     ah, 3Fh
    int     21h
    jc      .rcerr
    add     word [fcursor], ax
    adc     word [fcursor+2], 0
    clc
    ret
.rcerr:
    stc
    ret

; ===========================================================================
; skip32 - advance fcursor by the 32-bit amount DX:AX without reading.
; ===========================================================================
skip32:
    add     word [fcursor], ax
    adc     word [fcursor+2], dx
    ret

; ===========================================================================
; parse_model - STREAM: header, skip skins, skip stverts, read tri indices,
;   build the per-pose file-offset table.  CF set on error.
; ===========================================================================
parse_model:
    mov     word [fcursor], 0
    mov     word [fcursor+2], 0
    mov     dx, hdr
    mov     cx, 84
    call    read_chunk
    jc      .bad
    mov     ax, [hdr+0]
    cmp     ax, 0x4449
    jne     .bad
    mov     ax, [hdr+2]
    cmp     ax, 0x4F50
    jne     .bad
    mov     ax, [hdr+4]
    cmp     ax, 6
    jne     .bad
    mov     ax, [hdr+8]
    mov     [scaleX], ax
    mov     ax, [hdr+10]
    mov     [scaleX+2], ax
    mov     ax, [hdr+12]
    mov     [scaleY], ax
    mov     ax, [hdr+14]
    mov     [scaleY+2], ax
    mov     ax, [hdr+16]
    mov     [scaleZ], ax
    mov     ax, [hdr+18]
    mov     [scaleZ+2], ax
    mov     ax, [hdr+48]
    mov     [numskins], ax
    mov     ax, [hdr+52]
    mov     [skinw], ax
    mov     ax, [hdr+56]
    mov     [skinh], ax
    mov     ax, [hdr+60]
    mov     [nverts], ax
    mov     ax, [hdr+64]
    mov     [ntris], ax
    mov     ax, [hdr+68]
    mov     [nframes], ax
    fld     dword [scaleX]
    fmul    dword [fitscale]
    fstp    dword [sAdjX]
    fld     dword [scaleY]
    fmul    dword [fitscale]
    fstp    dword [sAdjY]
    fld     dword [scaleZ]
    fmul    dword [fitscale]
    fstp    dword [sAdjZ]

    mov     cx, [numskins]
.skins:
    jcxz    .skinsdone
    push    cx
    mov     dx, typ
    mov     cx, 4
    call    read_chunk
    mov     ax, [typ]
    cmp     ax, 0
    jne     .skingroup
    mov     ax, [skinw]
    mul     word [skinh]
    call    skip32
    jmp     .skinnext
.skingroup:
    mov     dx, typ
    mov     cx, 4
    call    read_chunk
    mov     ax, [typ]
    mov     [iv], ax
    shl     ax, 2
    xor     dx, dx
    call    skip32
    mov     cx, [iv]
.sgimg:
    jcxz    .skinnext
    push    cx
    mov     ax, [skinw]
    mul     word [skinh]
    call    skip32
    pop     cx
    dec     cx
    jmp     .sgimg
.skinnext:
    pop     cx
    dec     cx
    jmp     .skins
.skinsdone:

    mov     ax, [nverts]
    mov     dx, 12
    mul     dx
    call    skip32

    call    seek_cursor
    mov     di, tri_idx
    mov     cx, [ntris]
.tcopy:
    jcxz    .tdone
    push    cx
    mov     bx, [fhandle]
    mov     dx, tribuf
    mov     cx, 16
    mov     ah, 3Fh
    int     21h
    jc      .terr
    add     word [fcursor], 16
    adc     word [fcursor+2], 0
    mov     ax, [tribuf+4]
    mov     [di], ax
    mov     ax, [tribuf+8]
    mov     [di+2], ax
    mov     ax, [tribuf+12]
    mov     [di+4], ax
    add     di, 6
    pop     cx
    dec     cx
    jmp     .tcopy
.terr:
    pop     cx
    stc
    ret
.tdone:

    mov     word [nposes], 0
    mov     di, pose_ofs
    mov     cx, [nframes]
.frames:
    jcxz    .framesdone
    push    cx
    mov     dx, typ
    mov     cx, 4
    call    read_chunk
    jc      .ferr
    mov     ax, [typ]
    cmp     ax, 0
    jne     .fgroup
    mov     ax, 24
    xor     dx, dx
    call    skip32
    call    record_pose
    jmp     .fnext
.fgroup:
    mov     dx, typ
    mov     cx, 4
    call    read_chunk
    jc      .ferr
    mov     ax, [typ]
    mov     [gposes], ax
    mov     ax, 8
    xor     dx, dx
    call    skip32
    mov     ax, [gposes]
    shl     ax, 2
    xor     dx, dx
    call    skip32
.gpose:
    mov     ax, [gposes]
    cmp     ax, 0
    je      .fnext
    dec     ax
    mov     [gposes], ax
    mov     ax, 24
    xor     dx, dx
    call    skip32
    call    record_pose
    jmp     .gpose
.fnext:
    pop     cx
    dec     cx
    jmp     .frames
.ferr:
    pop     cx
    stc
    ret
.framesdone:
    clc
    ret
.bad:
    stc
    ret

; ---------------------------------------------------------------------------
; record_pose - pose_ofs[nposes++] = fcursor; advance DI; skip nverts*4.
; ---------------------------------------------------------------------------
record_pose:
    mov     ax, [fcursor]
    mov     [di], ax
    mov     ax, [fcursor+2]
    mov     [di+2], ax
    add     di, 4
    inc     word [nposes]
    mov     ax, [nverts]
    shl     ax, 2
    xor     dx, dx
    call    skip32
    ret

; ===========================================================================
; load_pose_buf - read pose pose_ofs[AX]'s trivertx block into buffer at DX.
; ===========================================================================
load_pose_buf:
    shl     ax, 2
    mov     bx, ax
    mov     ax, [pose_ofs+bx]
    mov     [fcursor], ax
    mov     ax, [pose_ofs+bx+2]
    mov     [fcursor+2], ax
    mov     cx, [nverts]
    shl     cx, 2
    call    read_chunk
    ret

; ===========================================================================
; ensure_loaded - for the static / manual path: make sure vbufA holds poseidx
;   and vbufB holds nidx=(poseidx+1)%nposes; reload only when poseidx changed.
; ===========================================================================
ensure_loaded:
    mov     ax, [poseidx]
    inc     ax
    cmp     ax, [nposes]
    jb      .nok
    xor     ax, ax
.nok:
    mov     [nidx], ax
    mov     ax, [poseidx]
    cmp     ax, [loaded_idx]
    je      .done
    mov     [loaded_idx], ax
    mov     ax, [poseidx]
    mov     dx, vbufA
    call    load_pose_buf
    mov     ax, [nidx]
    mov     dx, vbufB
    call    load_pose_buf
.done:
    ret

; ===========================================================================
; advance_pose - step animation time; choose poseidx/nidx; stream both bufs.
; ===========================================================================
advance_pose:
    fld     dword [posefrac]
    fadd    dword [dposefrac]
    fstp    dword [posefrac]
    fld     dword [posefrac]
    fsub    dword [fone]
    ftst
    fstsw   ax
    fstp    st0
    sahf
    jb      .nowrap
    fld     dword [posefrac]
    fsub    dword [fone]
    fstp    dword [posefrac]
    mov     ax, [poseidx]
    inc     ax
    cmp     ax, [nposes]
    jb      .pidxok
    xor     ax, ax
.pidxok:
    mov     [poseidx], ax
.nowrap:
    mov     ax, [poseidx]
    inc     ax
    cmp     ax, [nposes]
    jb      .nidxok
    xor     ax, ax
.nidxok:
    mov     [nidx], ax
    mov     eax, [posefrac]
    mov     [blendt], eax
    mov     ax, [poseidx]
    cmp     ax, [loaded_idx]
    je      .loaded
    mov     [loaded_idx], ax
    mov     ax, [poseidx]
    mov     dx, vbufA
    call    load_pose_buf
    mov     ax, [nidx]
    mov     dx, vbufB
    call    load_pose_buf
.loaded:
    ret

; ===========================================================================
; unpack_pose - decode + LERP vbufA/vbufB into mverts[] with the QUAKE->ENGINE
;   axis remap (x,y,z)->(x,z,-y).
; ===========================================================================
unpack_pose:
    mov     si, vbufA
    mov     bp, vbufB
    mov     di, mverts
    mov     cx, [nverts]
.uv:
    push    cx
    xor     ax, ax
    mov     al, [si]
    mov     [iv], ax
    fild    word [iv]
    fsub    dword [fhalf255]
    fmul    dword [sAdjX]
    xor     ax, ax
    mov     al, [bp]
    mov     [iv], ax
    fild    word [iv]
    fsub    dword [fhalf255]
    fmul    dword [sAdjX]
    fsub    st0, st1
    fmul    dword [blendt]
    faddp   st1, st0
    fstp    dword [tvx]
    xor     ax, ax
    mov     al, [si+1]
    mov     [iv], ax
    fild    word [iv]
    fsub    dword [fhalf255]
    fmul    dword [sAdjY]
    xor     ax, ax
    mov     al, [bp+1]
    mov     [iv], ax
    fild    word [iv]
    fsub    dword [fhalf255]
    fmul    dword [sAdjY]
    fsub    st0, st1
    fmul    dword [blendt]
    faddp   st1, st0
    fstp    dword [tvy]
    xor     ax, ax
    mov     al, [si+2]
    mov     [iv], ax
    fild    word [iv]
    fsub    dword [fhalf255]
    fmul    dword [sAdjZ]
    xor     ax, ax
    mov     al, [bp+2]
    mov     [iv], ax
    fild    word [iv]
    fsub    dword [fhalf255]
    fmul    dword [sAdjZ]
    fsub    st0, st1
    fmul    dword [blendt]
    faddp   st1, st0
    fstp    dword [tvz]
    ; AXIS REMAP (x,y,z) -> (x, z, -y)
    mov     ax, [tvx]
    mov     [di], ax
    mov     ax, [tvx+2]
    mov     [di+2], ax
    mov     ax, [tvz]
    mov     [di+4], ax
    mov     ax, [tvz+2]
    mov     [di+6], ax
    fld     dword [tvy]
    fchs
    fstp    dword [di+8]
    add     si, 4
    add     bp, 4
    add     di, 12
    pop     cx
    dec     cx
    jnz     .uv
    ret

; ===========================================================================
; clear_back / flip / update_angles
; ===========================================================================
clear_back:
    xor     di, di
    xor     ax, ax
    mov     cx, SCREEN_SZ/2
    rep     stosw
    ret

flip:
    push    ds
    mov     ax, VGA_SEG
    mov     es, ax
    mov     ds, [cs:bbseg]
    xor     si, si
    xor     di, di
    mov     cx, SCREEN_SZ/2
    rep     movsw
    pop     ds
    mov     es, [bbseg]
    ret

update_angles:
    fld     dword [angY]
    fsincos
    fstp    dword [cosY]
    fstp    dword [sinY]
    fld     dword [angX]
    fsincos
    fstp    dword [cosX]
    fstp    dword [sinX]
    fld     dword [angY]
    fadd    dword [dAngY]
    fstp    dword [angY]
    fld     dword [angX]
    fadd    dword [dAngX]
    fstp    dword [angX]
    ret

; ===========================================================================
; transform_verts - rotate/translate/project all nverts of mverts[].
; ===========================================================================
transform_verts:
    mov     si, mverts
    xor     bx, bx
    mov     cx, [nverts]
.vloop:
    push    cx
    fld     dword [si]
    fmul    dword [cosY]
    fld     dword [si+8]
    fmul    dword [sinY]
    faddp   st1, st0
    fstp    dword [rx]
    fld     dword [si+8]
    fmul    dword [cosY]
    fld     dword [si]
    fmul    dword [sinY]
    fsubp   st1, st0
    fstp    dword [rz]
    fld     dword [si+4]
    fmul    dword [cosX]
    fld     dword [rz]
    fmul    dword [sinX]
    fsubp   st1, st0
    fstp    dword [oy]
    fld     dword [si+4]
    fmul    dword [sinX]
    fld     dword [rz]
    fmul    dword [cosX]
    faddp   st1, st0
    fadd    dword [zcam]
    fstp    dword [oz]

    mov     di, bx
    shl     di, 1
    fld     dword [rx]
    fstp    dword [vvx + di]
    fld     dword [oy]
    fstp    dword [vvy + di]
    fld     dword [oz]
    fstp    dword [vvz + di]

    fld     dword [fov]
    fdiv    dword [oz]
    fstp    dword [factor]
    fld     dword [rx]
    fmul    dword [factor]
    fadd    dword [centerx]
    fistp   dword [itmp]
    mov     ax, [itmp]
    mov     [scrx + bx], ax
    fld     dword [centery]
    fld     dword [oy]
    fmul    dword [factor]
    fsubp   st1, st0
    fistp   dword [itmp]
    mov     ax, [itmp]
    mov     [scry + bx], ax

    add     si, 12
    add     bx, 2
    pop     cx
    dec     cx
    jnz     .vloop
    ret

; ===========================================================================
; build_vislist - per triangle: backface cull, flat shade, depth key.
; ===========================================================================
build_vislist:
    mov     word [nvis], 0
    mov     si, tri_idx
    mov     cx, [ntris]
.tloop:
    push    cx
    push    si
    mov     ax, [si]
    mov     [idxA], ax
    mov     ax, [si+2]
    mov     [idxB], ax
    mov     ax, [si+4]
    mov     [idxC], ax

    mov     bx, [idxA]
    shl     bx, 2
    fld     dword [vvx+bx]
    fstp    dword [vAx]
    fld     dword [vvy+bx]
    fstp    dword [vAy]
    fld     dword [vvz+bx]
    fstp    dword [vAz]
    mov     bx, [idxB]
    shl     bx, 2
    fld     dword [vvx+bx]
    fstp    dword [vBx]
    fld     dword [vvy+bx]
    fstp    dword [vBy]
    fld     dword [vvz+bx]
    fstp    dword [vBz]
    mov     bx, [idxC]
    shl     bx, 2
    fld     dword [vvx+bx]
    fstp    dword [vCx]
    fld     dword [vvy+bx]
    fstp    dword [vCy]
    fld     dword [vvz+bx]
    fstp    dword [vCz]

    fld     dword [vBx]
    fsub    dword [vAx]
    fstp    dword [E1x]
    fld     dword [vBy]
    fsub    dword [vAy]
    fstp    dword [E1y]
    fld     dword [vBz]
    fsub    dword [vAz]
    fstp    dword [E1z]
    fld     dword [vCx]
    fsub    dword [vAx]
    fstp    dword [E2x]
    fld     dword [vCy]
    fsub    dword [vAy]
    fstp    dword [E2y]
    fld     dword [vCz]
    fsub    dword [vAz]
    fstp    dword [E2z]

    fld     dword [E1y]
    fmul    dword [E2z]
    fld     dword [E1z]
    fmul    dword [E2y]
    fsubp   st1, st0
    fstp    dword [Nx]
    fld     dword [E1z]
    fmul    dword [E2x]
    fld     dword [E1x]
    fmul    dword [E2z]
    fsubp   st1, st0
    fstp    dword [Ny]
    fld     dword [E1x]
    fmul    dword [E2y]
    fld     dword [E1y]
    fmul    dword [E2x]
    fsubp   st1, st0
    fstp    dword [Nz]

    fld     dword [Nx]
    fmul    dword [vAx]
    fld     dword [Ny]
    fmul    dword [vAy]
    faddp   st1, st0
    fld     dword [Nz]
    fmul    dword [vAz]
    faddp   st1, st0
    ftst
    fstsw   ax
    fstp    st0
    sahf
    jae     .cull

    fld     dword [Nx]
    fmul    dword [Lx]
    fld     dword [Ny]
    fmul    dword [Ly]
    faddp   st1, st0
    fld     dword [Nz]
    fmul    dword [Lz]
    faddp   st1, st0
    fld     dword [Nx]
    fmul    st0, st0
    fld     dword [Ny]
    fmul    st0, st0
    faddp   st1, st0
    fld     dword [Nz]
    fmul    st0, st0
    faddp   st1, st0
    fsqrt
    fdivp   st1, st0
    ftst
    fstsw   ax
    sahf
    jae     .pos
    fstp    st0
    fldz
.pos:
    fmul    dword [fdiffuse]
    fadd    dword [fambient]
    fistp   dword [itmp]
    mov     ax, [itmp]
    cmp     ax, 255
    jle     .cmin
    mov     ax, 255
.cmin:
    cmp     ax, AMBIENT
    jge     .colok
    mov     ax, AMBIENT
.colok:
    mov     [tmpcol], ax

    fld     dword [vAz]
    fadd    dword [vBz]
    fadd    dword [vCz]
    fmul    dword [fk1000]
    fistp   dword [itmp]
    mov     ax, [itmp]
    mov     [tmpkey], ax

    mov     di, [nvis]
    shl     di, 1
    mov     bx, [idxA]
    shl     bx, 1
    mov     ax, [scrx+bx]
    mov     [vt0x+di], ax
    mov     ax, [scry+bx]
    mov     [vt0y+di], ax
    mov     bx, [idxB]
    shl     bx, 1
    mov     ax, [scrx+bx]
    mov     [vt1x+di], ax
    mov     ax, [scry+bx]
    mov     [vt1y+di], ax
    mov     bx, [idxC]
    shl     bx, 1
    mov     ax, [scrx+bx]
    mov     [vt2x+di], ax
    mov     ax, [scry+bx]
    mov     [vt2y+di], ax
    mov     ax, [tmpcol]
    mov     [vcol+di], ax
    mov     ax, [tmpkey]
    mov     [vkey+di], ax
    inc     word [nvis]

.cull:
    pop     si
    add     si, 6
    pop     cx
    dec     cx
    jnz     .tloop
    ret

; ===========================================================================
; sort_vislist - painter's order: insertion sort DESCENDING by depth key.
; ===========================================================================
sort_vislist:
    mov     cx, [nvis]
    cmp     cx, 2
    jl      .done
    mov     bx, 2
.outer:
    cmp     bx, cx
    jae     .done
    mov     di, bx
.inner:
    cmp     di, 0
    je      .placed
    mov     si, di
    sub     si, 2
    mov     ax, [vkey+si]
    cmp     ax, [vkey+di]
    jge     .placed
    call    swap_records
    mov     di, si
    jmp     .inner
.placed:
    add     bx, 2
    jmp     .outer
.done:
    ret

swap_records:
    push    cx
    push    bx
    SWAPW   vt0x
    SWAPW   vt0y
    SWAPW   vt1x
    SWAPW   vt1y
    SWAPW   vt2x
    SWAPW   vt2y
    SWAPW   vcol
    SWAPW   vkey
    pop     bx
    pop     cx
    ret

; ===========================================================================
; draw_vislist - rasterise each visible triangle in sorted order.
; ===========================================================================
draw_vislist:
    mov     cx, [nvis]
    cmp     cx, 0
    je      .none
    xor     bx, bx
.dloop:
    push    cx
    push    bx
    mov     ax, [vt0x+bx]
    mov     [t0x], ax
    mov     ax, [vt0y+bx]
    mov     [t0y], ax
    mov     ax, [vt1x+bx]
    mov     [t1x], ax
    mov     ax, [vt1y+bx]
    mov     [t1y], ax
    mov     ax, [vt2x+bx]
    mov     [t2x], ax
    mov     ax, [vt2y+bx]
    mov     [t2y], ax
    mov     ax, [vcol+bx]
    mov     [fillcol], al
    call    fill_tri
    pop     bx
    pop     cx
    add     bx, 2
    dec     cx
    jnz     .dloop
.none:
    ret

; ===========================================================================
; fill_tri / span_row - solid scanline triangle fill (16.16 fixed point).
; ===========================================================================
fill_tri:
    mov     ax, [t0y]
    cmp     ax, [t1y]
    jle     .s1
    SWAPPT  t0x,t0y, t1x,t1y
.s1:
    mov     ax, [t1y]
    cmp     ax, [t2y]
    jle     .s2
    SWAPPT  t1x,t1y, t2x,t2y
.s2:
    mov     ax, [t0y]
    cmp     ax, [t1y]
    jle     .s3
    SWAPPT  t0x,t0y, t1x,t1y
.s3:
    mov     ax, [t2y]
    sub     ax, [t0y]
    jle     .ftret
    mov     [dy02], ax

    movsx   eax, word [t2x]
    movsx   ecx, word [t0x]
    sub     eax, ecx
    shl     eax, 16
    cdq
    movsx   ecx, word [dy02]
    idiv    ecx
    mov     [islope02], eax
    movsx   eax, word [t0x]
    shl     eax, 16
    mov     [xlong], eax

    mov     ax, [t1y]
    sub     ax, [t0y]
    jle     .lower
    mov     [dyseg], ax
    movsx   eax, word [t1x]
    movsx   ecx, word [t0x]
    sub     eax, ecx
    shl     eax, 16
    cdq
    movsx   ecx, word [dyseg]
    idiv    ecx
    mov     [islopeS], eax
    movsx   eax, word [t0x]
    shl     eax, 16
    mov     [xshort], eax

    mov     dx, [t0y]
.uloop:
    cmp     dx, [t1y]
    jge     .lower
    call    span_row
    mov     eax, [xlong]
    add     eax, [islope02]
    mov     [xlong], eax
    mov     eax, [xshort]
    add     eax, [islopeS]
    mov     [xshort], eax
    inc     dx
    jmp     .uloop

.lower:
    mov     ax, [t2y]
    sub     ax, [t1y]
    js      .ftret
    mov     [dyseg], ax
    movsx   eax, word [t1x]
    shl     eax, 16
    mov     [xshort], eax
    mov     ax, [dyseg]
    cmp     ax, 0
    jle     .lzero
    movsx   eax, word [t2x]
    movsx   ecx, word [t1x]
    sub     eax, ecx
    shl     eax, 16
    cdq
    movsx   ecx, word [dyseg]
    idiv    ecx
    mov     [islopeS], eax
    jmp     .lgo
.lzero:
    mov     dword [islopeS], 0
.lgo:
    mov     dx, [t1y]
.lloop:
    cmp     dx, [t2y]
    jg      .ftret
    call    span_row
    mov     eax, [xlong]
    add     eax, [islope02]
    mov     [xlong], eax
    mov     eax, [xshort]
    add     eax, [islopeS]
    mov     [xshort], eax
    inc     dx
    jmp     .lloop
.ftret:
    ret

span_row:
    push    dx
    cmp     dx, 0
    jl      .srret
    cmp     dx, SCREEN_H-1
    jg      .srret
    mov     eax, [xlong]
    sar     eax, 16
    mov     bx, ax
    mov     eax, [xshort]
    sar     eax, 16
    mov     cx, ax
    cmp     bx, cx
    jle     .ord
    xchg    bx, cx
.ord:
    cmp     cx, 0
    jl      .srret
    cmp     bx, SCREEN_W-1
    jg      .srret
    cmp     bx, 0
    jge     .lok
    xor     bx, bx
.lok:
    cmp     cx, SCREEN_W-1
    jle     .rok
    mov     cx, SCREEN_W-1
.rok:
    mov     ax, dx
    shl     ax, 8
    mov     di, ax
    mov     ax, dx
    shl     ax, 6
    add     di, ax
    add     di, bx
    mov     ax, cx
    sub     ax, bx
    inc     ax
    mov     cx, ax
    mov     al, [fillcol]
    rep     stosb
.srret:
    pop     dx
    ret

; ===========================================================================
;  Strings
; ===========================================================================
s_usage     db 'Usage: CCMDL <file.mdl>  or  CCMDL <file.pak> <index>',0Dh,0Ah,0
s_nomem     db 'CCMDL: out of memory',0Dh,0Ah,0
s_noopen    db 'CCMDL: cannot open file',0Dh,0Ah,0
s_badfmt    db 'CCMDL: not a valid Quake .mdl (bad magic or version)',0Dh,0Ah,0
s_badpak    db 'CCMDL: cannot open container or index out of range',0Dh,0Ah,0

; ===========================================================================
;  Data
; ===========================================================================
fname       times 128 db 0      ; filename from the PSP tail (parse_args)
bbseg       dw 0
fhandle     dw 0
fcursor     dd 0                ; 32-bit cursor, RELATIVE to the model region
fbase       dd 0                ; PAK base offset (0 = plain file)
flen        dd 0                ; model region length (informational)
has_idx     db 0                ; 1 = second PSP-tail token was a PAK index
pak_idx     dd 0                ; the parsed index (resolve_pak_index)
pfh         dw 0                ; container file handle (resolve_pak_index)
pak_hdr     times 12 db 0       ; container's 12-byte PACK header
seek_tmp    dd 0                ; resolve_pak_index seek scratch
entry_pair  times 8 db 0        ; directory record's filepos(4)+filelen(4)

; --- camera / projection constants ----------------------------------------
centerx     dd 160.0
centery     dd 100.0
fov         dd 120.0
zcam        dd 4.0
dAngY       dd 0.0              ; static by default (Space toggles spin)
dAngX       dd 0.0
spinY       dd 0.0300          ; auto-spin rates copied into dAngY/dAngX
spinX       dd 0.0205
kstep       dd 0.19634954      ; manual rotation step (~PI/16 rad)

; --- fit / remap constants -------------------------------------------------
fitscale    dd 0.04
fhalf255    dd 127.5

; --- light + shade constants ----------------------------------------------
Lx          dd -0.3030
Ly          dd  0.5051
Lz          dd -0.8081
fambient    dd 48.0
fdiffuse    dd 207.0
fk1000      dd 1000.0

; --- model header fields ---------------------------------------------------
scaleX      dd 0.0
scaleY      dd 0.0
scaleZ      dd 0.0
sAdjX       dd 0.0
sAdjY       dd 0.0
sAdjZ       dd 0.0
numskins    dw 0
skinw       dw 0
skinh       dw 0
nverts      dw 0
ntris       dw 0
nframes     dw 0
nposes      dw 0
gposes      dw 0
iv          dw 0

; --- animation / view state ------------------------------------------------
poseidx     dw 0
nidx        dw 0
loaded_idx  dw 0FFFFh
posefrac    dd 0.0
dposefrac   dd 0.04
blendt      dd 0.0
fone        dd 1.0
auto_tumble db 0                ; auto-spin off by default
auto_anim   db 0                ; animation off by default

; --- streaming scratch -----------------------------------------------------
hdr         times 84 db 0
typ         dd 0
tribuf      times 16 db 0

; --- per-frame / per-vertex scratch (floats) -------------------------------
tvx  dd 0.0
tvy  dd 0.0
tvz  dd 0.0
angY dd 0.6                     ; fixed 3/4 turn (upright, no tumble)
angX dd 0.0
sinY dd 0.0
cosY dd 0.0
sinX dd 0.0
cosX dd 0.0
rx   dd 0.0
rz   dd 0.0
oy   dd 0.0
oz   dd 0.0
factor dd 0.0
itmp dd 0

; --- triangle normal / shade scratch (floats) ------------------------------
vAx dd 0.0
vAy dd 0.0
vAz dd 0.0
vBx dd 0.0
vBy dd 0.0
vBz dd 0.0
vCx dd 0.0
vCy dd 0.0
vCz dd 0.0
E1x dd 0.0
E1y dd 0.0
E1z dd 0.0
E2x dd 0.0
E2y dd 0.0
E2z dd 0.0
Nx dd 0.0
Ny dd 0.0
Nz dd 0.0
idxA dw 0
idxB dw 0
idxC dw 0
tmpcol dw 0
tmpkey dw 0

; --- rasteriser scratch ----------------------------------------------------
t0x dw 0
t0y dw 0
t1x dw 0
t1y dw 0
t2x dw 0
t2y dw 0
fillcol  db 0
dy02     dw 0
dyseg    dw 0
xlong    dd 0
xshort   dd 0
islope02 dd 0
islopeS  dd 0

; --- working arrays --------------------------------------------------------
mverts      times MAXVERTS*3 dd 0.0
vvx         times MAXVERTS   dd 0.0
vvy         times MAXVERTS   dd 0.0
vvz         times MAXVERTS   dd 0.0
scrx        times MAXVERTS   dw 0
scry        times MAXVERTS   dw 0
tri_idx     times MAXTRIS*3  dw 0
pose_ofs    times MAXPOSES   dd 0
vbufA       times MAXVERTS*4 db 0
vbufB       times MAXVERTS*4 db 0

nvis        dw 0
vt0x        times MAXTRIS dw 0
vt0y        times MAXTRIS dw 0
vt1x        times MAXTRIS dw 0
vt1y        times MAXTRIS dw 0
vt2x        times MAXTRIS dw 0
vt2y        times MAXTRIS dw 0
vcol        times MAXTRIS dw 0
vkey        times MAXTRIS dw 0
