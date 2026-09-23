; ============================================================================
;  CMDL_SKELETON.ASM  --  Skeleton for CCMDL.COM, a Quake .mdl viewer
;
;  IMPORTANT: This file is a DESIGN SKELETON only.  It is not referenced by
;  cc's build system or keytab.  It is safe to leave here; wiring into cc
;  (cc.ini [view] + package.ps1) happens in a LATER implementation phase.
;
;  Usage (when complete):
;      CCMDL <file.mdl>          show the model in VGA mode 13h; ESC returns
;
;  Exit convention (same as every cc Layer-3 viewer):
;      - Restore text mode (INT 10h AX=0003h) before returning.
;      - Exit via INT 21h AH=4Ch AL=0 (success) or AL=1 (error).
;
;  Assemble (standalone, no link step):
;      nasm -f bin cmdl_skeleton.asm -o ccmdl.com
;
;  Memory model:
;      Flat .COM, one 64 KB segment, org 100h.
;      Back-buffer (64000 bytes) allocated from DOS heap (INT 21h AH=48h).
;      MDL file kept OPEN for streaming; only small blocks are in-segment.
;
;  Renderer origin:
;      All MDL load / animate / render routines to be ported verbatim from
;      C:\LLM\DOS\ASMQuake\src\m4_anim.asm (the Milestone-4 streamed
;      animator with LERP and axis-remap).  The only change needed is
;      replacing the hardcoded   mdlname db "test.mdl",0   with the
;      dynamically-filled   fname   buffer parsed from the PSP command tail.
;
;  Controls (planned):
;      ESC / F3 / Q       exit viewer, return to cc
;      Left / Right       manual yaw rotation (overrides auto-tumble)
;      Up / Down          manual pitch rotation
;      Space              toggle auto-tumble on/off
;      A                  toggle animation play/pause
;      N                  next animation frame (pauses auto)
;      P                  previous animation frame (pauses auto)
;
;  Key conventions:
;      INT 16h AH=01h (BIOS key-check, no wait)
;      INT 16h AH=00h (consume the key)
;      Extended keys: AL=00h, then AH = scan code.
;      Scan codes: 4Bh=Left, 4Dh=Right, 48h=Up, 50h=Down.
;      ASCII: 1Bh=ESC, 20h=Space, 27h=Q (or 71h), 61h=A, 6Eh=N, 70h=P.
;
; ============================================================================

cpu 386
bits 16
org 100h

; --- vga.inc constants (inline here to keep the skeleton self-contained) ---
; When porting the full renderer, replace this block with:
;   %include "vga.inc"
; and ensure vga.inc is in the NASM include path (copy from ASMQuake/src/).
VGA_SEG     equ 0A000h
SCREEN_W    equ 320
SCREEN_H    equ 200
SCREEN_SZ   equ SCREEN_W * SCREEN_H        ; 64000

; --- renderer constants (from m4_anim.asm) ---
MAXVERTS    equ 600
MAXTRIS     equ 1024
MAXPOSES    equ 256
AMBIENT     equ 48
DIFFUSE     equ 207

; ============================================================================
;  ENTRY POINT
; ============================================================================
start:
        cld
        mov     sp, stacktop

        ; ------------------------------------------------------------------
        ;  Step 1: parse the PSP command tail for the filename.
        ;  The tail starts at 81h; byte at 80h is its length.
        ;  cc invokes us as:  CCMDL C:\GAMES\QUAKE\PROGS\SOLDIER.MDL
        ;  (run_view_helper builds "<helper> <targpath>" into cmdbuf)
        ; ------------------------------------------------------------------
        call    parse_args
        cmp     byte [fname], 0
        jne     .have_file
        mov     si, s_usage
        call    puts
        mov     ax, 4C01h
        int     21h
.have_file:

        ; ------------------------------------------------------------------
        ;  Step 2: shrink our memory block so later INT 21h AH=48h has room.
        ;  (Same pattern as m4_anim.asm start: shrink to 0x1000 paragraphs)
        ; ------------------------------------------------------------------
        mov     ax, cs
        mov     es, ax
        mov     bx, 1000h
        mov     ah, 4Ah
        int     21h

        ; ------------------------------------------------------------------
        ;  Step 3: allocate a 64000-byte off-screen back-buffer.
        ;  If the allocation fails we proceed without double-buffering
        ;  (writes go straight to A000:0000 -- acceptable for debugging).
        ; ------------------------------------------------------------------
        mov     bx, (SCREEN_SZ + 15) / 16
        mov     ah, 48h
        int     21h
        jc      .nobuf
        mov     [bbseg], ax
.nobuf:

        ; ------------------------------------------------------------------
        ;  Step 4: open and parse the MDL (streaming, text-mode still on
        ;  so error messages print normally).
        ; ------------------------------------------------------------------
        ; TODO: call  open_model     ; open fname, store handle in fhandle
        ; TODO: jc    .open_err
        ; TODO: call  parse_model    ; stream header/skins/stverts/tris/poses
        ; TODO: jc    .parse_err

        ; ------------------------------------------------------------------
        ;  Step 5: switch to VGA mode 13h and load the grayscale palette.
        ;  Do this ONLY after a successful parse so errors stay on-screen.
        ; ------------------------------------------------------------------
        ; TODO: call  set_mode13
        ; TODO: call  set_gray_palette

        ; ------------------------------------------------------------------
        ;  Main render loop
        ; ------------------------------------------------------------------
.frame:
        ; --- poll keyboard (non-blocking) ---
        mov     ah, 01h
        int     16h
        jz      .nokey

        xor     ax, ax
        int     16h                 ; consume key -> AL=ascii, AH=scan

        ; ESC, Q, F3 -> quit
        cmp     al, 1Bh
        je      .quit
        cmp     al, 'q'
        je      .quit
        cmp     al, 'Q'
        je      .quit
        cmp     ah, 3Dh             ; F3
        je      .quit

        ; Extended keys (AL=0): check scan in AH
        or      al, al
        jnz     .ascii_key
        ; TODO: handle extended keys
        ;   cmp     ah, 4Bh  ; Left arrow  -> manual yaw -= dAngY_manual
        ;   cmp     ah, 4Dh  ; Right arrow -> manual yaw += dAngY_manual
        ;   cmp     ah, 48h  ; Up arrow    -> manual pitch -= dAngX_manual
        ;   cmp     ah, 50h  ; Down arrow  -> manual pitch += dAngX_manual
        jmp     .nokey
.ascii_key:
        ; TODO: Space -> toggle auto_tumble flag
        ; TODO: A     -> toggle auto_anim flag
        ; TODO: N     -> inc poseidx (clamped), clear auto_anim
        ; TODO: P     -> dec poseidx (clamped), clear auto_anim
        jmp     .nokey
.nokey:

        ; --- select render target (back-buffer or direct) ---
        mov     ax, [bbseg]
        or      ax, ax
        jnz     .use_bb
        mov     ax, VGA_SEG
.use_bb:
        mov     es, ax

        ; --- clear back buffer ---
        ; TODO: call  clear_back

        ; --- advance model state ---
        ; TODO: cmp   byte [auto_tumble], 0
        ; TODO: je    .no_tumble
        ; TODO: call  update_angles    ; increment angY, angX; recompute sin/cos
        ; TODO: .no_tumble:
        ; TODO: cmp   byte [auto_anim], 0
        ; TODO: je    .no_anim
        ; TODO: call  advance_pose     ; step poseidx, stream vbufA/vbufB if changed
        ; TODO: .no_anim:
        ; TODO: call  unpack_pose      ; lerp poseA/poseB -> mverts[] (axis-remapped)
        ; TODO: call  transform_verts  ; rotate/project mverts -> scrx/scry + vvz
        ; TODO: call  build_vislist    ; cull + shade triangles -> vis list
        ; TODO: call  sort_vislist     ; painter's order (descending z-key)
        ; TODO: call  draw_vislist     ; rasterise into back-buffer (ES)

        ; --- flip to screen ---
        mov     ax, [bbseg]
        or      ax, ax
        jz      .noflip
        ; TODO: call  wait_vsync
        ; TODO: call  flip             ; copy bbseg -> A000:0000
.noflip:

        jmp     .frame

        ; ------------------------------------------------------------------
        ;  Quit path: restore text mode and exit
        ; ------------------------------------------------------------------
.quit:
        ; TODO: close the MDL file handle (INT 21h AH=3Eh BX=[fhandle])
        ;   mov     bx, [fhandle]
        ;   mov     ah, 3Eh
        ;   int     21h
        ; TODO: free the back-buffer (INT 21h AH=49h ES=[bbseg]) -- optional
        ;   cmp     word [bbseg], 0
        ;   je      .nofree
        ;   mov     es, [bbseg]
        ;   mov     ah, 49h
        ;   int     21h
        ; .nofree:
        mov     ax, 0003h           ; restore 80x25 text mode
        int     10h
        mov     ax, 4C00h           ; exit code 0 = success
        int     21h

        ; ------------------------------------------------------------------
        ;  Error paths (text mode, no mode switch needed)
        ; ------------------------------------------------------------------
.open_err:
        mov     si, s_noopen
        call    puts
        mov     ax, 4C01h
        int     21h

.parse_err:
        ; TODO: close fhandle if it was opened
        mov     si, s_badfmt
        call    puts
        mov     ax, 4C01h
        int     21h

; ============================================================================
;  parse_args -- read the PSP command tail (81h..) into fname.
;  Skips leading spaces, copies until space / CR / NUL.
;  Sets fname[0]=0 if no argument is present.
; ============================================================================
parse_args:
        mov     si, 81h
        ; NUL-terminate the tail at the CR (position 80h is the byte count but
        ; NASM .COM gets a real PSP; find the CR and replace it)
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
        ; copy the argument into fname
        mov     di, fname
.cp:
        mov     al, [si]
        or      al, al
        jz      .done
        cmp     al, ' '
        je      .done
        mov     [di], al
        inc     si
        inc     di
        jmp     .cp
.done:
        mov     byte [di], 0
        ret

skip_sp:
        cmp     byte [si], ' '
        jne     .d
        inc     si
        jmp     skip_sp
.d:     ret

; ============================================================================
;  puts -- write ASCIIZ string at DS:SI to stdout (handle 1).
; ============================================================================
puts:
        mov     di, si
.l:     cmp     byte [di], 0
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
.ret:   ret

; ============================================================================
;  TODO STUBS -- replace with verbatim ports from m4_anim.asm
;
;  Port the following routines in this order (they have no dependencies on
;  each other except those listed):
;
;  GROUP A: file streaming (no VGA / FPU dependencies)
;    open_model      <- m4_anim.asm:open_model  (change: dx=mdlname -> dx=fname)
;    seek_cursor     <- m4_anim.asm:seek_cursor  (verbatim)
;    read_chunk      <- m4_anim.asm:read_chunk   (verbatim)
;    skip32          <- m4_anim.asm:skip32        (verbatim)
;    parse_model     <- m4_anim.asm:parse_model  (verbatim; uses seek/read/skip)
;    record_pose     <- m4_anim.asm:record_pose  (verbatim)
;    load_pose_buf   <- m4_anim.asm:load_pose_buf (verbatim)
;
;  GROUP B: animation (depends on FPU, Group A data)
;    advance_pose    <- m4_anim.asm:advance_pose (verbatim)
;    unpack_pose     <- m4_anim.asm:unpack_pose  (verbatim; FPU lerp + axis remap)
;
;  GROUP C: render (depends on FPU, Group B output)
;    update_angles   <- m4_anim.asm:update_angles (verbatim)
;    transform_verts <- m4_anim.asm:transform_verts (verbatim)
;    build_vislist   <- m4_anim.asm:build_vislist  (verbatim)
;    sort_vislist    <- m4_anim.asm:sort_vislist   (verbatim)
;    swap_records    <- m4_anim.asm:swap_records   (verbatim)
;    draw_vislist    <- m4_anim.asm:draw_vislist   (verbatim)
;    scan_right      <- m4_anim.asm:scan_right     (verbatim, rasteriser helper)
;    fill_scan       <- m4_anim.asm:fill_scan      (verbatim, rasteriser helper)
;
;  GROUP D: VGA (from vga.inc or inline from m0_vga.asm / m4_anim.asm)
;    set_mode13      <- vga.inc:set_mode13     (verbatim)
;    set_text_mode   <- vga.inc:set_text_mode  (verbatim)
;    set_gray_palette <- vga.inc:set_gray_palette (verbatim)
;    wait_vsync      <- vga.inc:wait_vsync     (verbatim)
;    clear_back      <- m4_anim.asm:clear_back (verbatim; uses [bbseg] via ES)
;    flip            <- m4_anim.asm:flip       (verbatim; DS->[bbseg] -> ES->A000)
;
;  MACRO dependencies from m4_anim.asm:
;    %macro SWAPW 1
;    %macro SWAPPT 4
;  (These are only used by swap_records; include them at the top of the file.)
; ============================================================================

; ============================================================================
;  Strings
; ============================================================================
s_usage     db 'Usage: CCMDL <file.mdl>',0Dh,0Ah,0
s_noopen    db 'CCMDL: cannot open file',0Dh,0Ah,0
s_badfmt    db 'CCMDL: not a valid Quake .mdl (bad magic or version)',0Dh,0Ah,0

; ============================================================================
;  Data -- viewer state
; ============================================================================
fname       times 128 db 0      ; filename from PSP tail (filled by parse_args)
fhandle     dw 0                ; open MDL file handle
fcursor     dd 0                ; 32-bit streaming cursor (seek position)
bbseg       dw 0                ; segment of the 64000-byte back-buffer (0=none)
auto_tumble db 1                ; 1 = auto-rotate on each frame
auto_anim   db 1                ; 1 = advance pose on each frame

; TODO: copy the data block verbatim from m4_anim.asm (lines 1072-1207):
;   mdlname, bbseg, fhandle, fcursor,
;   centerx, centery, fov, zcam, dAngY, dAngX,
;   fitscale, fhalf255,
;   Lx, Ly, Lz, fambient, fdiffuse, fk1000,
;   scaleX..sAdjZ, numskins..gposes..iv,
;   poseidx, nidx, loaded_idx, posefrac, dposefrac, blendt, fone,
;   hdr[84], typ, tribuf[16],
;   tvx..tvz, angY..cosX, rx..factor, itmp,
;   vAx..vCz, E1x..E2z, Nx..Nz, idxA..tmpkey,
;   t0x..fillcol, dy02..islopeS,
;   mverts[], vvx[], vvy[], vvz[], scrx[], scry[],
;   tri_idx[], pose_ofs[], vbufA[], vbufB[],
;   nvis, vt0x[]..vkey[]
;
; NOTE: in the CCMDL version, 'mdlname' is no longer needed (we use 'fname'
; above).  Remove 'mdlname db "test.mdl",0' from the ported data block and
; use 'fname' in open_model instead.

; ============================================================================
;  Stack (at the very end, past all data + working arrays)
; ============================================================================
; TODO: after pasting the data block above, add:
;   stackspace  resb 1024
;   stacktop:
;
; For the skeleton only, place a minimal stack here:
section .bss
align 2
stackspace  resb 1024
stacktop:
