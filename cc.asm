; ============================================================================
;  Claude Commander (cc.com) -- a Volkov Commander-style file manager for DOS
;  Stage A: B800 renderer, two panels, directory read+sort, navigation.
;
;  Assemble:  nasm -f bin cc.asm -o cc.com
;  Target:    DOS, 286+, color text mode (80x25).
;
;  Test mode: "cc /T"  -> reads keystroke script cc.key (pairs of bytes
;                         al,ah), feeds them to the dispatcher, and appends
;                         the 80x25 screen (chars only) to CCDUMP.TXT after
;                         each frame; quits when the script is exhausted.
;             "cc /D"  -> render one frame, dump it, quit (no key script).
; ============================================================================

cpu 386
bits 16
org 100h

; ---- constants -------------------------------------------------------------
VIDEO       equ 0B800h
SCR_W       equ 80
SCR_H       equ 25
ROW_BYTES   equ SCR_W*2

; panel geometry (shared single divider at col 39)
; left  : border col 0 , content cols 1..38 (w=38), divider col 39
; right : divider col 39, content cols 40..78 (w=39), border col 79
L_CONX      equ 1
L_CONW      equ 38
R_CONX      equ 40
R_CONW      equ 39
; Panel row geometry. With the persistent menu bar (FEAT_MENUBAR) the whole
; panel block slides down one row so the bar can own row 0; the actual equs are
; defined after the FEAT-resolution block (see "panel geometry" below) so they
; can see FEAT_MENUBAR however it was set (command line or tier).

; attributes (bg<<4 | fg)
A_NORM      equ 017h       ; light grey on blue (files)
A_DIR       equ 01Fh       ; bright white on blue (dirs)
A_TAG       equ 01Eh       ; yellow on blue (tagged entries)
A_CUR       equ 030h       ; black on cyan (cursor, active panel)
A_CURI      equ 070h       ; black on grey (cursor, inactive panel)
A_FRAME     equ 017h       ; light grey on blue
A_FRAMEA    equ 01Fh       ; bright white on blue (active frame)
A_TITLE     equ 030h       ; black on cyan (active path title)
A_TITLEI    equ 017h       ; grey on blue (inactive path title)
A_CMD       equ 007h       ; grey on black
A_FKN       equ 007h       ; grey on black (fkey number)
A_FKL       equ 030h       ; black on cyan (fkey label)
A_BG        equ 017h

; box-drawing chars (CP437)
C_TL        equ 0DAh
C_TR        equ 0BFh
C_BL        equ 0C0h
C_BR        equ 0D9h
C_H         equ 0C4h
C_V         equ 0B3h
C_TT        equ 0C2h       ; top tee
C_BT        equ 0C1h       ; bottom tee

; panel struct layout
P_PATH      equ 0          ; ASCIIZ current dir, e.g. "C:\GAMES"  (68 bytes)
P_COUNT     equ 68         ; word: number of entries
P_TOP       equ 70         ; word: first visible entry index
P_CUR       equ 72         ; word: cursor entry index (absolute)
P_VFS       equ 74         ; byte: 1 = this panel is a container (virtual) view
; P_VFS is really a panel-SOURCE enum (the FEAT_RESULTS work widened it):
;   SRC_DIR=0 real directory, SRC_VFS=1 archive/container, SRC_RESULT=2 find list.
; Old code that tested "P_VFS != 0 -> not a real dir" still behaves: a results
; panel is also "not a real dir". Code that does container things now tests ==1.
P_SRC       equ 74         ; alias of P_VFS, read as the source enum
SRC_DIR     equ 0
SRC_VFS     equ 1
SRC_RESULT  equ 2
P_CNAME     equ 76         ; 14 bytes: container filename when P_VFS=1
P_CPATH     equ 90         ; 64 bytes: path WITHIN the container ('/'-terminated
                           ;   or empty at the archive root) when P_VFS=1
P_VIEW      equ 154        ; byte: body view mode (0 = full list, 1 = brief 3-col)
P_ENTRIES   equ 156        ; entry array
MAX_FILES   equ 512         ; per panel (keeps the whole .COM within one 64KB segment)
ENTSIZE     equ 24
PANELSIZE   equ P_ENTRIES + MAX_FILES*ENTSIZE

; container (VFS) registry: extension -> external helper, parsed from cc.ini
OPENMAX     equ 12          ; max [open] mappings
OPENROW     equ 18          ; 4-byte ext (upper, NUL-padded) + 14-byte helper

; user-tool registry (FEAT_TOOLS_INI): cc.ini [tools] "label = program" rows
UTOOL_MAX   equ 12          ; max [tools] entries added to the Tools pull-down
UTBUF_SZ    equ 512         ; ASCIIZ storage for all labels + program names

; recursive copy/delete: per-level DTA stack
DTASZ       equ 64         ; bytes per FindFirst DTA (record is 43)
MAX_DEPTH   equ 24         ; max directory nesting we will recurse

; entry layout
E_NAME      equ 0          ; 14 bytes ASCIIZ (8.3 max 12 + nul)
E_ATTR      equ 14
E_SIZE      equ 16         ; dword
E_TIME      equ 20         ; word
E_DATE      equ 22         ; word
; FEAT_RESULTS reuses two entry slots on a SRC_RESULT panel ONLY (fenced hard by
; P_SRC==SRC_RESULT everywhere they are read). HAZARD: a future date/time column
; feature must not read these on a results panel.
E_RES_OFF   equ 20         ; (= E_TIME) near offset of the full path in res_heap
E_RES_LINE  equ 22         ; (= E_DATE) first matching line, and the row-type
                           ;   discriminator: 0 = find row (Enter -> jump to the
                           ;   file's folder); >0 = grep file row (Enter -> open
                           ;   the F3 viewer at this line). Grep lists one row per
                           ;   FILE, so the matched text is no longer stored.
E_RES_TEXT  equ 16         ; (= E_SIZE low word) alias; on a grep file row E_SIZE
                           ;   holds the line number so it shows in the size column.
E_ATTR_STATUS equ 08h      ; E_ATTR bit for a non-selectable status row
                           ;   (unused by 10h dir / 20h archive / 40h tagged)
RESHEAP_MAX equ 3072       ; packed full-path bytes for the results panel

; --- data-driven key dispatch -------------------------------------------------
; Each binding is a 4-byte row: db class, db code, dw handler. A module can
; register its own keys by emitting KEYBIND_* rows into keytab (see plan/
; m1_dispatch.md). dispatch walks the table; unmatched printable ASCII falls
; through to cmd_addchar exactly as the old cmp/je chain did.
KB_EXT      equ 0          ; match on AH (scan) -- extended key (al was 0)
KB_ASC      equ 1          ; match on AL (ascii)
KB_END      equ 0FFh       ; table sentinel (class byte)

%macro KEYBIND_EXT 2        ; %1 = scan code (AH), %2 = handler label
        db      KB_EXT
        db      %1
        dw      %2
%endmacro

%macro KEYBIND_ASC 2        ; %1 = ascii code (AL), %2 = handler label
        db      KB_ASC
        db      %1
        dw      %2
%endmacro

%macro KEYBIND_END 0
        db      KB_END
        db      0
        dw      0
%endmacro

; --- widget descriptor table (the in-process draw/tick/key seam) --------------
; Every visible part of cc -- the two panels, the frame chrome, the command and
; fkey rows, and the optional footer/clock/menu-bar -- is one row in wtab. The
; three walkers (widgets_draw / widgets_tick / widgets_key) each sweep the table
; calling the one non-zero column, so adding a widget is a single WIDGET row
; gated by its FEAT_ -- the walkers never change (the keytab pattern, for paint).
; Rows are listed in DRAW ORDER; the table is the literal render sequence.
;
; The walkers + the core rows (panels/frames/cmd/fkeys) are core, so even a
; FEAT_MIN build (no FEAT_WIDGETS) renders through the table. FEAT_WIDGETS now
; only marks the presence of the optional overlay widgets; the seam is core.
WIDGET_SZ   equ 8
%macro WIDGET 5             ; %1 draw_fn  %2 tick_fn  %3 key_fn  %4 region  %5 flags
        dw      %1
        dw      %2
        dw      %3
        db      %4
        db      %5
%endmacro
; region ids -- advisory today (documentation + future partial repaint)
WR_PANL     equ 0          ; left panel content
WR_PANR     equ 1          ; right panel content
WR_FRAME    equ 2          ; panel frames (borders)
WR_CMD      equ 3          ; command row
WR_FKEY     equ 4          ; function-key row
WR_FOOT     equ 5          ; free-space / tag footer
WR_TOP      equ 6          ; top row (menu bar)
WF_NONE     equ 0

; --- external-tool discovery bitmap (FEAT_DISCOVER) ---------------------------
; One bit per external helper cc knows about. discover_tools (mod/discover.inc)
; sets the bits at startup; tool key/menu handlers gate on them. The equates are
; always defined so the gates compile unconditionally; the scan + present_tools
; storage are FEAT_DISCOVER-only.
TOOLBIT_FIND  equ 0001h
TOOLBIT_GREP  equ 0002h
TOOLBIT_SUM   equ 0004h
TOOLBIT_DIFF  equ 0008h
TOOLBIT_SPLIT equ 0010h
TOOLBIT_REN   equ 0020h

; --- build profile -> feature set ---------------------------------------------
; build.ps1 passes -dFEAT_MIN / -dFEAT_STD / -dFEAT_FULL. A bare `nasm cc.asm`
; (no flag) builds as STD. Tiers are cumulative: FULL = STD + heavy features.
;
; configure.ps1 instead passes -dFEAT_CUSTOM plus an explicit -dFEAT_X per
; widget the user picked (a-la-carte). In that mode we skip the tier defaults
; and only resolve hard dependencies below, so the binary contains exactly the
; chosen set and its size scales with it.
%ifndef FEAT_CUSTOM
  %ifdef FEAT_FULL
    %define _TIER 3
  %elifdef FEAT_STD
    %define _TIER 2
  %elifdef FEAT_MIN
    %define _TIER 1
  %else
    %define _TIER 2          ; default bare build == STD
  %endif

  %if _TIER >= 2             ; ---- STD feature set ----
    %define FEAT_CLOCK
    %define FEAT_WIDGETS
    %define FEAT_SORT
    %define FEAT_SEARCH
    %define FEAT_FREE
    %define FEAT_COLS
    %define FEAT_MENU
    %define FEAT_MENUBAR        ; persistent pull-down bar (supersedes the pop-up)
    %define FEAT_MASK
    %define FEAT_EDIT
    %define FEAT_FIND
    %define FEAT_ZIP
    %define FEAT_INI
    %define FEAT_HELP
    %define FEAT_LANG
    %define FEAT_LFN
    %define FEAT_GREP
    %define FEAT_ATTR
    %define FEAT_VFS
    %define FEAT_VIEW
    %define FEAT_VIEWS
    %define FEAT_TREE
    %define FEAT_TOOLS          ; "Tools" menu-bar pull-down (CCSUM/CCDIFF/...)
    %define FEAT_RESULTS        ; Alt-F7/Alt-F8 land in a browsable results panel
  %endif
  %if _TIER >= 3             ; ---- FULL adds (reserved for heavy features) ----
  %endif
%endif

; --- hard dependency closure (applies to every build mode) -------------------
; A widget that draws through the widgets seam needs that seam; the cc.ini-fed
; features need the ini parser (which owns their bss scratch). Auto-pull them
; so an a-la-carte set can never half-wire itself into an assemble error.
%ifdef FEAT_CLOCK
  %define FEAT_WIDGETS
%endif
%ifdef FEAT_FREE
  %define FEAT_WIDGETS
%endif
%ifdef FEAT_VFS
  %define FEAT_INI
%endif
%ifdef FEAT_VIEW
  %define FEAT_VFS              ; run_view_helper uses vfs_cat (lives in vfs.inc)
  %define FEAT_INI
%endif
%ifdef FEAT_LANG
  %define FEAT_INI
%endif
%ifdef FEAT_LFN
  %define FEAT_INI
%endif
%ifdef FEAT_LFN_FULL
  %define FEAT_LFN    ; LFN_FULL implies basic LFN cursor display
%endif
%ifdef FEAT_ATTR
  %define FEAT_INI
%endif
%ifdef FEAT_TOOLS_INI
  %define FEAT_TOOLS            ; user tools (cc.ini [tools]) live on the Tools menu
  %define FEAT_INI              ; ...parsed from cc.ini, so the ini reader is needed
%endif
%ifdef FEAT_TOOLS
  %define FEAT_MENUBAR          ; the Tools pull-down lives on the menu bar
%endif
%ifdef FEAT_MENUBAR
  %define FEAT_WIDGETS          ; the persistent bar draws through the widget seam
%endif
%ifdef FEAT_RESULTS
  %define FEAT_FIND             ; the results panel is populated by Alt-F7 find
%endif

; --- panel row geometry (depends on the resolved FEAT set) -------------------
; FKEY_ROW (24) and CMD_ROW (23) are fixed at the bottom; the menu bar steals a
; row from the top, so the file-list block is one row shorter when it is on.
%ifdef FEAT_MENUBAR
MENUBAR_ROW equ 0          ; persistent pull-down bar
TOP_ROW     equ 1          ; top frame
FIRST_ROW   equ 2          ; first file row
VIS_ROWS    equ 20         ; visible file rows (rows 2..21)
%else
TOP_ROW     equ 0          ; top frame
FIRST_ROW   equ 1          ; first file row
VIS_ROWS    equ 21         ; visible file rows (rows 1..21)
%endif
BOT_ROW     equ 22         ; bottom frame
CMD_ROW     equ 23         ; command line
FKEY_ROW    equ 24         ; function-key bar

; ============================================================================
start:
        cld
        mov     sp, stacktop        ; relocate stack into resident region
        ; --- parse command tail for /T and /D ---
        mov     si, 81h             ; PSP command tail text
        movzx   cx, byte [80h]      ; tail length
        jcxz    .noargs
.scan:
        lodsb
        cmp     al, '/'
        jne     .next
        cmp     cx, 1
        jb      .noargs
        mov     al, [si]            ; char after '/'
        or      al, 20h             ; tolower
        cmp     al, 't'
        je      .set_test
        cmp     al, 'd'
        je      .set_dump
        cmp     al, 'c'
        je      .set_count
%ifdef FEAT_SNAP
        cmp     al, 's'
        je      .set_snap
%endif
        jmp     .next
.set_test:
        mov     byte [test_mode], 1
        mov     byte [want_keys], 1
        jmp     .next
.set_dump:
        mov     byte [test_mode], 1
        jmp     .next
.set_count:
        mov     byte [test_mode], 1
        mov     byte [count_dbg], 1
        jmp     .next
%ifdef FEAT_SNAP
.set_snap:
        mov     byte [snap_mode], 1
%endif
.next:
        loop    .scan
.noargs:

        ; --- shrink memory block so EXEC (Stage B) has room; keep up to end ---
        mov     ax, prog_end
        add     ax, 15
        shr     ax, 4               ; paragraphs of resident image
        add     ax, 16              ; + a little slack for stack
        mov     bx, ax
        mov     ah, 4Ah
        int     21h                 ; resize PSP block (ES=PSP at entry)

        ; --- allocate the off-screen back-buffer (4000 bytes = 250 paragraphs).
        ;     render_all draws here then block-copies to VRAM in one shot, so the
        ;     visible page never shows a half-painted frame (no flicker). If the
        ;     alloc fails, bufseg stays 0 and render_all paints straight to VRAM.
        mov     ah, 48h
        mov     bx, 250
        int     21h
        jc      .nobuf
        mov     [bufseg], ax
.nobuf:

        ; --- save original video mode, switch to 80x25 colour text ---
        mov     ah, 0Fh
        int     10h
        mov     [orig_mode], al
        mov     ax, 0003h
        int     10h
        call    hide_cursor

        ; --- test-mode setup: open dump file, load key script ---
        cmp     byte [test_mode], 0
        je      .noteset
        call    open_dump
        cmp     byte [want_keys], 0
        je      .noteset
        call    load_keys
.noteset:

%ifdef FEAT_INI
        ; --- load cc.ini before the panels are read so sort/columns apply ---
        call    ini_load
%endif
%ifdef FEAT_LANG
        ; --- repoint the F-key bar labels from cc.lng if present ---
        call    lang_load
%endif
%ifdef FEAT_DISCOVER
        ; --- scan cwd/PATH/progdir for the helper .COMs we know about ---
        call    discover_tools
%endif
%ifdef FEAT_TOOLS_INI
        ; --- fold any cc.ini [tools] entries into the Tools pull-down ---
        call    build_tools_menu
%endif

        ; --- init both panels to current drive/dir ---
        mov     di, panelL
        call    init_panel_cwd
        mov     di, panelR
        call    init_panel_cwd

        mov     word [active], panelL
        mov     word [cmdlen], 0

        ; --- diagnostic: write panel counts + first names, then exit ---
        cmp     byte [count_dbg], 0
        je      .nodbg
        call    selftest
        call    close_dump
        mov     ah, 0
        mov     al, [orig_mode]
        int     10h
        mov     ax, 4C00h
        int     21h
.nodbg:

%ifdef FEAT_SNAP
        ; --- snapshot mode: render once, dump raw VRAM to CCSNAP.BIN, exit ---
        cmp     byte [snap_mode], 0
        je      .nosnap
        call    render_all
        call    snap_vram
        mov     ah, 0
        mov     al, [orig_mode]
        int     10h
        call    show_cursor
        mov     ax, 4C00h
        int     21h
.nosnap:
%endif

        ; --- mouse init (live mode only) ---
        mov     byte [mouse_ok], 0
        mov     byte [mouse_vis], 0
        mov     byte [mouse_mode], MM_BROWSER
        mov     byte [m_lb], 0
        mov     byte [m_rb], 0
        mov     word [m_lastpan], 0FFFFh
        cmp     byte [test_mode], 0
        jne     .nomouse
        xor     ax, ax
        int     33h                 ; reset / detect mouse driver
        or      ax, ax
        jz      .nomouse            ; AX=0 -> no driver
        mov     byte [mouse_ok], 1
        mov     ax, 1
        int     33h                 ; show mouse cursor
        mov     byte [mouse_vis], 1 ; seed the idempotent-visibility flag (shown)
.nomouse:
        call    clear_bg            ; one-time full screen clear before entering the loop

; ---- main loop -------------------------------------------------------------
main_loop:
        call    mouse_hide
        call    render_all
        call    mouse_show
        cmp     byte [test_mode], 0
        je      .live
        call    dump_screen
.live:
        call    get_key             ; -> al=ascii, ah=scan
        call    dispatch
        cmp     byte [quit_flag], 0
        je      main_loop

        ; --- exit: close dump, restore video ---
        cmp     byte [test_mode], 0
        je      .noclose
        call    close_dump
.noclose:
        call    mouse_hide
        mov     ah, 0
        mov     al, [orig_mode]
        int     10h
        call    show_cursor
        ; --- cd-on-exit (Norton/Volkov style): leave COMMAND.COM in the active
        ;     panel's directory. DOS keeps the current dir as global state, so a
        ;     CHDIR here persists to the shell after we terminate. Virtual
        ;     (container) panels are skipped; any failure is ignored. ---
        mov     bx, [active]
        cmp     byte [bx+P_VFS], 0
        jne     .nocd
        mov     al, [bx+P_PATH]         ; drive letter 'A'..'Z'
        sub     al, 'A'
        mov     dl, al
        mov     ah, 0Eh                 ; select default drive
        int     21h
        lea     dx, [bx+P_PATH]         ; ASCIIZ "C:\DIR\SUB"
        mov     ah, 3Bh                 ; CHDIR
        int     21h
.nocd:
        mov     ax, 4C00h
        int     21h

; ============================================================================
;  DISPATCH
; ============================================================================
; Data-driven: walk keytab (built by KEYBIND_* rows). al=ascii, ah=scan from
; get_key. al==0 -> match scan(ah) against KB_EXT rows; else match ascii(al)
; against KB_ASC rows. No row + printable ascii -> cmd_addchar fallthrough.
; AL/AH are preserved into the handler (scratch is DL/DH/CL/SI/BX only).
dispatch:
        call    widgets_key         ; input-owning widgets get first refusal
        jc      .ret                ; a widget claimed (and handled) the key
        mov     dl, KB_ASC          ; assume ascii key
        mov     dh, al              ; code to match = al (ascii)
        or      al, al
        jnz     .haveclass
        mov     dl, KB_EXT          ; al==0 -> extended key
        mov     dh, ah              ; code to match = ah (scan)
.haveclass:
        mov     si, keytab
.scan:
        mov     cl, [si]            ; row class
        cmp     cl, KB_END
        je      .nomatch            ; hit sentinel -> no explicit binding
        cmp     cl, dl
        jne     .nextrow            ; class differs (ext vs ascii)
        cmp     dh, [si+1]          ; code match?
        je      .hit
.nextrow:
        add     si, 4
        jmp     .scan
.hit:
        mov     bx, [si+2]          ; handler offset
        call    bx                  ; handler ret returns to main_loop
        ret
.nomatch:
%ifdef FEAT_TOOLS_INI
        ; no static binding -> offer the key to runtime [tools] hotkeys (dl=class,
        ; dh=code still set). A match runs the tool and reports CF=1.
        call    ukey_dispatch
        jc      .ret
%endif
        or      al, al              ; extended key, no binding -> nothing
        jz      .ret
        cmp     al, 20h             ; printable range -> append to cmd line
        jb      .ret
        cmp     al, 7Eh
        ja      .ret
        call    cmd_addchar
.ret:
        ret

key_quit:
        mov     byte [quit_flag], 1
        ret

; Enter: if the command line has text, run it; else act on the current entry
on_enter:
        cmp     word [cmdlen], 0
        jne     run_command
        jmp     key_enter

on_esc:
        cmp     word [cmdlen], 0
        jne     .clear              ; text on the command line -> just clear it
%ifdef FEAT_RESULTS
        mov     bx, [active]
        cmp     byte [bx+P_SRC], SRC_RESULT
        jne     .clear              ; empty line, regular panel -> nothing to do
        jmp     go_parent           ; empty line on a results panel -> leave it
%endif
.clear:
        mov     word [cmdlen], 0
        ret

on_bksp:
        mov     ax, [cmdlen]
        or      ax, ax
        jz      .parent             ; empty command line -> go up a folder
        dec     ax
        mov     [cmdlen], ax
        ret
.parent:
        call    go_parent
        ret

cmd_addchar:
        mov     bx, [cmdlen]
        cmp     bx, 127
        jae     .r
        mov     [cmdbuf+bx], al
        inc     word [cmdlen]
.r:
        ret

key_tab:
        ; swap active <-> other
        mov     ax, [active]
        cmp     ax, panelL
        jne     .toL
        mov     word [active], panelR
        ret
.toL:
        mov     word [active], panelL
        ret

; cursor movement helpers (operate on active panel) ---------------------------
key_up:
        mov     bx, [active]
        mov     ax, [bx+P_CUR]
        or      ax, ax
        jz      .done
        dec     ax
        mov     [bx+P_CUR], ax
        call    fix_scroll
.done:
        ret

key_down:
        mov     bx, [active]
        mov     ax, [bx+P_CUR]
        mov     cx, [bx+P_COUNT]
        jcxz    .done
        inc     ax
        cmp     ax, cx
        jb      .ok
        mov     ax, cx
        dec     ax
.ok:
        mov     [bx+P_CUR], ax
        call    fix_scroll
.done:
        ret

key_pgup:
        mov     bx, [active]
%ifdef FEAT_VIEWS
        mov     cl, VD_PAGE
        call    view_word           ; ax = entries per page for this view
        mov     cx, ax
        mov     ax, [bx+P_CUR]
        sub     ax, cx
%else
        mov     ax, [bx+P_CUR]
        sub     ax, VIS_ROWS-1
%endif
        jns     .ok
        xor     ax, ax
.ok:
        mov     [bx+P_CUR], ax
        call    fix_scroll
        ret

key_pgdn:
        mov     bx, [active]
        mov     cx, [bx+P_COUNT]
        jcxz    .done
%ifdef FEAT_VIEWS
        mov     cl, VD_PAGE
        call    view_word           ; ax = entries per page for this view
        mov     dx, ax
        mov     ax, [bx+P_CUR]
        add     ax, dx
%else
        mov     ax, [bx+P_CUR]
        add     ax, VIS_ROWS-1
%endif
        mov     cx, [bx+P_COUNT]    ; reload count (VD_PAGE clobbered cl above)
        cmp     ax, cx
        jb      .ok
        mov     ax, cx
        dec     ax
.ok:
        mov     [bx+P_CUR], ax
        call    fix_scroll
.done:
        ret

key_home:
        mov     bx, [active]
        mov     word [bx+P_CUR], 0
        call    fix_scroll
        ret

key_end:
        mov     bx, [active]
        mov     cx, [bx+P_COUNT]
        jcxz    .done
        dec     cx
        mov     [bx+P_CUR], cx
        call    fix_scroll
.done:
        ret

; keep cursor visible: adjust P_TOP (bx = panel) -----------------------------
fix_scroll:
%ifdef FEAT_VIEWS
        jmp     view_fixscroll      ; table dispatch by P_VIEW (mod/views.inc)
fix_scroll_full:                    ; registered scroll for P_VIEW=0
%endif
        mov     ax, [bx+P_CUR]
        ; if cur < top -> top = cur
        cmp     ax, [bx+P_TOP]
        jae     .belowtop
        mov     [bx+P_TOP], ax
        ret
.belowtop:
        ; if cur >= top + VIS_ROWS -> top = cur - VIS_ROWS + 1
        mov     dx, [bx+P_TOP]
        add     dx, VIS_ROWS
        cmp     ax, dx
        jb      .ok
        sub     ax, VIS_ROWS-1
        mov     [bx+P_TOP], ax
.ok:
        ret

; ============================================================================
;  ENTER: descend into dir, or go up on ".."
; ============================================================================
key_enter:
        mov     bx, [active]
        mov     cx, [bx+P_COUNT]
        jcxz    .ret
        call    cur_entry_ptr       ; -> si = entry ptr
%ifdef FEAT_RESULTS
        cmp     byte [bx+P_SRC], SRC_RESULT
        jne     .notresult
        call    results_enter       ; jump to the found file's folder (or inert)
        ret
.notresult:
%endif
        test    byte [si+E_ATTR], 10h
        jz      .file               ; not a directory -> maybe run it
%ifdef FEAT_VFS
        ; inside a container, directory entries are virtual (synthetic sub-folders
        ; or ".."). Navigate within the archive instead of touching the real FS.
        mov     bx, [active]
        cmp     byte [bx+P_VFS], 0
        je      .realdir
        mov     al, [si+E_NAME]
        cmp     al, '.'
        jne     .vfsdescend
        cmp     byte [si+E_NAME+1], '.'
        jne     .vfsdescend
        call    vfs_go_up           ; ".." -> up one archive level (or leave)
        ret
.vfsdescend:
        call    vfs_descend         ; sub-folder -> deeper into the archive
        ret
.realdir:
%endif
        ; directory: is it ".."?
        mov     al, [si+E_NAME]
        cmp     al, '.'
        jne     .descend
        cmp     byte [si+E_NAME+1], '.'
        jne     .descend
        ; go up, landing the cursor on the folder we came from
        call    go_parent
        ret
.descend:
        ; append "\name" to path
        lea     di, [si+E_NAME]
        call    path_append
        call    read_dir
.ret:
        ret
.file:
%ifdef FEAT_VFS
        ; inside an archive view, members are virtual: they aren't real files on
        ; disk, so don't try to browse them as nested containers or run them
        ; (that corrupted the panel). Use F5 to extract, or ".." to leave.
        mov     bx, [active]
        cmp     byte [bx+P_VFS], 0
        jne     .ret
        ; container? (extension registered in cc.ini's [open] map)
        push    si
        lea     si, [si+E_NAME]
        call    open_lookup         ; CF=1 if the extension maps to a helper
        pop     si
        jnc     .notcont
        call    vfs_enter           ; si=entry -> browse it as a folder
        ret
.notcont:
%endif
        call    is_exec             ; si -> CF set if .EXE/.COM/.BAT
        jnc     .ret
        ; copy filename onto the command line and shell-run it
        push    si
        lea     si, [si+E_NAME]
        mov     di, cmdbuf
        xor     cx, cx
.fc:
        mov     al, [si]
        mov     [di], al
        or      al, al
        jz      .fce
        inc     si
        inc     di
        inc     cx
        jmp     .fc
.fce:
        mov     [cmdlen], cx
        pop     si
        call    set_active_cwd
        jmp     run_command

; si=entry -> CF=1 if the name ends in .EXE/.COM/.BAT (case-insensitive)
is_exec:
        push    si
        lea     si, [si+E_NAME]
        xor     bx, bx              ; bx = ptr just past last '.'
.f:
        mov     al, [si]
        or      al, al
        jz      .chk
        cmp     al, '.'
        jne     .nx
        lea     bx, [si+1]
.nx:
        inc     si
        jmp     .f
.chk:
        or      bx, bx
        jz      .no
        mov     si, bx
        mov     di, s_exe
        call    cmp3
        je      .yes
        mov     si, bx
        mov     di, s_com
        call    cmp3
        je      .yes
        mov     si, bx
        mov     di, s_bat
        call    cmp3
        je      .yes
.no:
        pop     si
        clc
        ret
.yes:
        pop     si
        stc
        ret

; compare 3 bytes [si] (uppercased) vs [di]; ZF=1 if equal
cmp3:
        mov     cx, 3
.l:
        mov     al, [si]
        cmp     al, 'a'
        jb      .u
        cmp     al, 'z'
        ja      .u
        sub     al, 20h
.u:
        cmp     al, [di]
        jne     .ne
        inc     si
        inc     di
        loop    .l
        xor     al, al              ; ZF=1 (equal)
        ret
.ne:
        mov     al, 1
        or      al, al              ; ZF=0 (differ)
        ret

; set the DOS current drive + directory to the active panel's path
set_active_cwd:
        mov     bx, [active]
        mov     dl, [bx+P_PATH]
        sub     dl, 'A'
        mov     ah, 0Eh             ; select drive
        int     21h
        lea     dx, [bx+P_PATH]
        mov     ah, 3Bh             ; chdir
        int     21h
        ret

; ============================================================================
;  RENDER
; ============================================================================
render_all:
        cmp     word [bufseg], 0
        je      .live               ; no back-buffer -> paint straight to VRAM
        mov     ax, [bufseg]
        mov     [vseg], ax          ; redirect all widget writes to the buffer
        call    widgets_draw        ; walk wtab in draw order (panels..frames..overlays)
        mov     word [vseg], VIDEO  ; restore live target before the blit
        jmp     blit_buf            ; one atomic copy buffer -> VRAM (tail-call)
.live:
        call    widgets_draw
        ret

; copy the whole 80x25 back-buffer to video memory in one rep movsw. Done with
; the mouse hidden by the caller (main loop / modal loops all wrap render_all in
; mouse_hide/mouse_show), so the cursor cell isn't clobbered mid-copy. Preserves
; ds (callers rely on ds = our data segment).
blit_buf:
        push    ds
        push    si
        push    di
        push    cx
        push    es
        mov     ax, [bufseg]
        mov     ds, ax
        mov     ax, VIDEO
        mov     es, ax
        xor     si, si
        xor     di, di
        mov     cx, SCR_W*SCR_H
        rep     movsw
        pop     es
        pop     cx
        pop     di
        pop     si
        pop     ds
        ret

; The widget descriptor table -- listed in draw order (= the literal old
; render_all sequence). Core rows first, then FEAT-gated overlay widgets.
wtab:
        WIDGET  draw_panelL, 0,          0,           WR_PANL,  WF_NONE
        WIDGET  draw_panelR, 0,          0,           WR_PANR,  WF_NONE
        WIDGET  draw_frames, 0,          0,           WR_FRAME, WF_NONE
        WIDGET  draw_cmdline,0,          0,           WR_CMD,   WF_NONE
        WIDGET  draw_fkeys,  0,          0,           WR_FKEY,  WF_NONE
%ifdef FEAT_FREE
        WIDGET  draw_foot,   0,          0,           WR_FOOT,  WF_NONE
%endif
%ifdef FEAT_MENUBAR
        WIDGET  mb_bar_draw, 0,          mb_key,      WR_TOP,   WF_NONE
%endif
%ifdef FEAT_CLOCK
        WIDGET  draw_clock,  clock_tick, 0,           WR_CMD,   WF_NONE
%endif
wtab_end:

; draw walker: call every non-zero draw_fn, in table order.
widgets_draw:
        mov     si, wtab
.l:
        cmp     si, wtab_end
        jae     .done
        mov     ax, [si]            ; draw_fn
        or      ax, ax
        jz      .next
        push    si
        call    ax
        pop     si
.next:
        add     si, WIDGET_SZ
        jmp     .l
.done:
        ret

; tick walker: idle refresh -- call every non-zero tick_fn (only the clock today).
widgets_tick:
        mov     si, wtab
.l:
        cmp     si, wtab_end
        jae     .done
        mov     ax, [si+2]          ; tick_fn
        or      ax, ax
        jz      .next
        push    si
        call    ax
        pop     si
.next:
        add     si, WIDGET_SZ
        jmp     .l
.done:
        ret

; key walker: offer the key (al=ascii, ah=scan) to each non-zero key_fn before
; the keytab. A widget claims it by returning CF=1; declining widgets leave
; al/ah untouched. Returns CF=1 if some widget claimed it. al/ah are preserved
; across the sweep (the walk uses si/dx only).
widgets_key:
        mov     si, wtab
.l:
        cmp     si, wtab_end
        jae     .none
        mov     dx, [si+4]          ; key_fn
        or      dx, dx
        jz      .next
        push    si
        call    dx
        pop     si
        jc      .claimed
.next:
        add     si, WIDGET_SZ
        jmp     .l
.none:
        clc
        ret
.claimed:
        stc
        ret

; panel draw rows: set the panel's screen geometry, then draw it. Tail-call.
draw_panelL:
        mov     bx, panelL
        mov     byte [pcx], L_CONX
        mov     byte [pcw], L_CONW
        jmp     draw_panel
draw_panelR:
        mov     bx, panelR
        mov     byte [pcx], R_CONX
        mov     byte [pcw], R_CONW
        jmp     draw_panel

; fill whole screen with blue spaces ------------------------------------------
clear_bg:
        push    es
        mov     ax, [vseg]
        mov     es, ax
        xor     di, di
        mov     ax, (A_BG<<8) | ' '
        mov     cx, SCR_W*SCR_H
        rep     stosw
        pop     es
        ret

; draw both panel frames (single line, shared divider) ------------------------
draw_frames:
        push    es
        mov     ax, [vseg]
        mov     es, ax
        ; top row
        mov     bx, TOP_ROW
        mov     al, C_TL
        mov     cl, C_TR
        mov     ch, C_TT
        call    frame_row
        ; bottom row
        mov     bx, BOT_ROW
        mov     al, C_BL
        mov     cl, C_BR
        mov     ch, C_BT
        call    frame_row
        ; verticals on file rows
        mov     bx, FIRST_ROW
.vloop:
        cmp     bx, BOT_ROW
        jae     .vdone
        ; col 0
        mov     ax, bx
        imul    ax, ROW_BYTES
        mov     di, ax
        mov     ah, A_FRAME
        mov     al, C_V
        mov     [es:di], ax
        ; col 39 (divider)
        mov     [es:di + 39*2], ax
        ; col 79
        mov     [es:di + 79*2], ax
        inc     bx
        jmp     .vloop
.vdone:
        pop     es
        call    draw_titles
        ret

; draw a frame row: bx=row, al=left char, cl=right char, ch=tee char ----------
; (es already = VIDEO)
frame_row:
        push    bx
        imul    bx, ROW_BYTES       ; bx = row * ROW_BYTES (al = corner char preserved)
        mov     di, bx
        pop     bx
        push    cx                  ; save right/tee
        ; left corner
        mov     ah, A_FRAME
        mov     [es:di], al
        mov     [es:di+1], ah
        ; horizontal fill cols 1..78
        add     di, 2
        mov     al, C_H
        mov     cx, 78
.hf:
        mov     [es:di], al
        mov     [es:di+1], ah
        add     di, 2
        loop    .hf
        ; tee at col 39 (di currently at col 79)
        pop     cx                  ; cl=right, ch=tee
        mov     bx, TOP_ROW         ; scratch
        ; right corner at col 79 (di points here)
        mov     al, cl
        mov     [es:di], al
        mov     [es:di+1], ah
        ; tee at col 39
        mov     al, ch
        push    di
        sub     di, (79-39)*2
        mov     [es:di], al
        mov     [es:di+1], ah
        pop     di
        ret

; draw path titles into top frame for both panels ----------------------------
draw_titles:
        ; left
        mov     bx, panelL
        mov     cx, L_CONX
        mov     dx, L_CONW
        call    one_title
        ; right
        mov     bx, panelR
        mov     cx, R_CONX
        mov     dx, R_CONW
        call    one_title
        ret

; bx=panel, cx=content x, dx=content w
one_title:
        push    es
        mov     ax, [vseg]
        mov     es, ax
        ; attr: active panel title highlighted
        mov     al, A_TITLEI
        cmp     bx, [active]
        jne     .a
        mov     al, A_TITLE
.a:
        mov     [tattr], al
        ; compute strlen(path) -- or the container name when browsing one
        lea     si, [bx+P_PATH]
%ifdef FEAT_VFS
        cmp     byte [bx+P_VFS], 1  ; only a real container shows its archive name;
        jne     .src                ; SRC_DIR(0) and SRC_RESULT(2) show P_PATH
        lea     si, [bx+P_CNAME]
.src:
%endif
        call    strlen              ; -> ax = len
        mov     bp, ax              ; bp = path len
        ; field width = dx-2 (leave a space each side)
        mov     di, dx
        sub     di, 2
        ; if len > field, show last (field) chars
        cmp     bp, di
        jbe     .fits
        ; advance si to show tail
        mov     ax, bp
        sub     ax, di
        add     si, ax
        mov     bp, di
.fits:
        ; start col = contentx + (w - (len+2))/2 , centered. Add framing spaces.
        ; compute video offset for row 0
        mov     ax, cx              ; content x
        ; center: startcol = cx + (dx - (bp+2))/2
        mov     bx, dx
        sub     bx, bp
        sub     bx, 2
        shr     bx, 1
        add     ax, bx              ; ax = start col
        push    ax
        ; di = (TOP_ROW, start col) offset
        mov     di, ax
        shl     di, 1               ; col*2
        add     di, TOP_ROW*ROW_BYTES
        mov     ah, [tattr]
        ; leading space
        mov     al, ' '
        stosw                       ; note: es=VIDEO, di advances by 2
        ; path chars
        mov     cx, bp
.pl:
        lodsb
        stosw
        loop    .pl
        ; trailing space
        mov     al, ' '
        stosw
        pop     ax
        pop     es
        ret

; ---------------------------------------------------------------------------
; draw one panel's file list. bx=panel ptr, [pcx]=content x, [pcw]=content w
draw_panel:
%ifdef FEAT_VIEWS
        jmp     view_render         ; table dispatch by P_VIEW (mod/views.inc)
draw_panel_full:                    ; registered renderer for P_VIEW=0
%endif
        mov     [ppanel], bx
        ; for row i in 0..VIS_ROWS-1
        xor     bp, bp              ; bp = visible row index
.row:
        cmp     bp, VIS_ROWS
        jae     .done
        ; build rowbuf (filled with spaces) FIRST -- it clobbers AL
        call    clear_rowbuf
        mov     bx, [ppanel]
        mov     ax, [bx+P_TOP]
        add     ax, bp              ; entry index
        cmp     ax, [bx+P_COUNT]
        jae     .blank              ; past end -> blank row
        ; format entry into rowbuf
        push    ax
        call    entry_ptr           ; ax=index -> si
        call    format_entry        ; si -> rowbuf
        pop     ax
        ; choose attribute
        push    ax
        call    pick_attr           ; ax=index -> al=attr
        mov     [rattr], al
        pop     ax
        jmp     .emit
.blank:
        mov     byte [rattr], A_NORM
.emit:
        ; emit rowbuf at (FIRST_ROW+bp, pcx) width pcw
        push    bp
        mov     ax, FIRST_ROW
        add     ax, bp
        movzx   bx, byte [pcx]
        call    rc_to_off           ; ax=row,bx=col -> di
        mov     si, rowbuf
        movzx   cx, byte [pcw]
        mov     ah, [rattr]
        call    putbuf
        pop     bp
        inc     bp
        jmp     .row
.done:
        call    draw_info
        ret

; choose attribute for entry index ax in panel [ppanel] -> al
pick_attr:
        mov     bx, [ppanel]
        cmp     ax, [bx+P_CUR]
        jne     .notcur
        ; cursor row: active panel cyan, inactive grey
        mov     al, A_CURI
        cmp     bx, [active]
        jne     .ret
        mov     al, A_CUR
        ret
.notcur:
        push    ax
        call    entry_ptr           ; -> si
        pop     ax
        test    byte [si+E_ATTR], 40h
        jnz     .tagged
        mov     al, A_NORM
        test    byte [si+E_ATTR], 10h
        jz      .ret
        mov     al, A_DIR
.ret:
        ret
.tagged:
        mov     al, A_TAG
        ret

; draw info line (bottom frame title) for both panels ------------------------
draw_info:
        ; show current entry size or <DIR> at bottom frame of this panel
        mov     bx, [ppanel]
        mov     cx, [bx+P_COUNT]
        jcxz    .ret
        mov     ax, [bx+P_CUR]
        call    entry_ptr           ; -> si
        ; build "[ name ]" small? For v1 show name in bottom frame title.
        ; We'll just show the highlighted file name centered in bottom border.
        push    es
        mov     ax, [vseg]
        mov     es, ax
        movzx   ax, byte [pcx]
        add     ax, 1               ; start a bit in
        mov     di, ax
        shl     di, 1
        add     di, BOT_ROW*ROW_BYTES
        mov     ah, A_FRAME
        mov     al, ' '
        stosw
        lea     si, [si+E_NAME]
        movzx   cx, byte [pcw]
        sub     cx, 4
.nl:
        lodsb
        or      al, al
        jz      .pad
        stosw
        loop    .nl
        jmp     .sp
.pad:
.sp:
        mov     al, ' '
        stosw
        pop     es
.ret:
        ret

; ---------------------------------------------------------------------------
; command line (row 23): show active path + ">"
draw_cmdline:
        push    es
        mov     ax, [vseg]
        mov     es, ax
        mov     di, CMD_ROW*ROW_BYTES
        ; clear row
        mov     ax, (A_CMD<<8)|' '
        mov     cx, SCR_W
        rep     stosw
        ; write path>
        mov     di, CMD_ROW*ROW_BYTES
        mov     bx, [active]
        lea     si, [bx+P_PATH]
        mov     ah, A_CMD
.pl:
        lodsb
        or      al, al
        jz      .gt
        stosw
        jmp     .pl
.gt:
        mov     al, '>'
        stosw
        ; typed command-line text
        mov     si, cmdbuf
        mov     cx, [cmdlen]
        jcxz    .nocmd
.cl:
        lodsb
        stosw
        loop    .cl
        pop     es
        ret
.nocmd:
%ifdef FEAT_LFN
        call    lfn_draw_cursor         ; di still just past "path>"
%endif
        pop     es
        ret

; function-key bar (row 24): 10 evenly-spaced 8-column slots. Each slot shows
; the digit(s) in grey-on-black and the label in black-on-cyan, so the keys
; read as separated buttons.
draw_fkeys:
        push    es
        mov     ax, [vseg]
        mov     es, ax
        ; clear the row to grey-on-black (the gaps between buttons)
        mov     di, FKEY_ROW*ROW_BYTES
        mov     ax, (A_FKN<<8)|' '
        mov     cx, SCR_W
        rep     stosw
        xor     bp, bp              ; slot index 0..9
.slot:
        cmp     bp, 10
        jae     .done
        mov     ax, bp             ; di = row base + slot*8 cells
        shl     ax, 4              ; *16 bytes (8 cols * 2)
        add     ax, FKEY_ROW*ROW_BYTES
        mov     di, ax
        mov     bx, bp             ; si = fk_tbl[slot]
        shl     bx, 1
        mov     si, [fk_tbl+bx]
.ch:
        mov     al, [si]
        or      al, al
        jz      .nextslot
        mov     ah, A_FKL          ; label -> black on cyan
        cmp     al, '0'
        jb      .put
        cmp     al, '9'
        ja      .put
        mov     ah, A_FKN          ; digit -> grey on black
.put:
        mov     [es:di], al
        mov     [es:di+1], ah
        add     di, 2
        inc     si
        jmp     .ch
.nextslot:
        inc     bp
        jmp     .slot
.done:
        pop     es
        ret

; ============================================================================
;  DIRECTORY READING
; ============================================================================
; init a panel to the current drive + directory. di = panel ptr
init_panel_cwd:
        push    di
        ; drive letter
        mov     ah, 19h             ; get current drive (0=A)
        int     21h
        add     al, 'A'
        mov     [di+P_PATH], al
        mov     byte [di+P_PATH+1], ':'
        mov     byte [di+P_PATH+2], '\'
        ; current dir (without leading backslash) appended after "C:\"
        push    di
        lea     si, [di+P_PATH+3]
        mov     ah, 47h
        xor     dl, dl              ; current drive
        int     21h
        pop     di
        ; ensure terminator: AH=47h null-terminates. If empty -> "C:\"
        mov     word [di+P_COUNT], 0
        mov     word [di+P_TOP], 0
        mov     word [di+P_CUR], 0
        mov     byte [di+P_VFS], 0
%ifdef FEAT_VIEWS
        mov     byte [di+P_VIEW], 0     ; default to the full list view
%endif
        mov     bx, di
        call    read_dir
        pop     di
        ret

; read directory for panel bx into its entry array, then sort -----------------
read_dir:
        mov     [ppanel], bx
%ifdef FEAT_RESULTS
        cmp     byte [bx+P_SRC], SRC_RESULT
        jne     .notresult
        ret                         ; synthetic results: nothing on disk to re-read
                                    ; (refresh_panels must not wipe the list)
.notresult:
%endif
%ifdef FEAT_VFS
        cmp     byte [bx+P_VFS], 0
        je      .notvfs
        jmp     vfs_relist          ; virtual panel -> re-list the container
.notvfs:
%endif
%ifndef FEAT_LFN_FULL
        ; set DTA = dta_buf
        push    dx
        mov     ah, 1Ah
        mov     dx, dta_buf
        int     21h
        pop     dx
%endif
        ; build search string "PATH\*.*"
        call    build_search        ; -> srchbuf
        mov     word [_count], 0
%ifndef FEAT_LFN_FULL
        ; FindFirst (standard DTA)
        mov     ah, 4Eh
        mov     cx, 37h             ; RO|Hidden|System|Dir|Archive
        mov     dx, srchbuf
        int     21h
        jc      .finish
.loop:
        call    accept_dta
        mov     ah, 4Fh
        int     21h
        jnc     .loop
%else
        ; LFN FindFirst (714Eh) -> WIN32_FIND_DATA in copybuf, handle in BX
        push    es
        push    ds
        pop     es                  ; ES = DS for copybuf
        mov     ax, 714Eh
        mov     cx, 37h             ; same attrmask: RO|Hidden|System|Dir|Archive
        xor     si, si              ; date format = local time
        mov     dx, srchbuf         ; DS:DX = search spec
        mov     di, copybuf         ; ES:DI = WIN32_FIND_DATA (318 bytes)
        int     21h
        pop     es
        jc      .finish
        mov     bx, ax              ; BX = search handle
.lfn_loop:
        push    bx                  ; preserve handle across accept_lfn
        call    accept_lfn
        pop     bx
        push    ds
        pop     es                  ; ES = DS for FindNext output buffer
        mov     ax, 714Fh
        mov     di, copybuf         ; ES:DI = WIN32_FIND_DATA
        int     21h
        jnc     .lfn_loop
        mov     ax, 71A1h           ; LFN FindClose
        int     21h
%endif
.finish:
        mov     bx, [ppanel]
        mov     ax, [_count]
        mov     [bx+P_COUNT], ax
        mov     word [bx+P_TOP], 0
        mov     word [bx+P_CUR], 0
        call    sort_panel
        ret

; copy current DTA result into the entry array (if not "." and not root "..")
accept_dta:
        ; skip "." always
        mov     al, [dta_buf+1Eh]
        cmp     al, '.'
        jne     .keep
        mov     al, [dta_buf+1Fh]
        or      al, al
        jz      .skip               ; "."  -> skip
        cmp     al, '.'
        jne     .keep
        ; ".." -> skip if at root
        mov     bx, [ppanel]
        lea     si, [bx+P_PATH]
        call    strlen
        cmp     ax, 3               ; "C:\" == root
        jbe     .skip
.keep:
        mov     ax, [_count]
        cmp     ax, MAX_FILES
        jae     .skip
        call    entry_ptr           ; ax=index -> si = dest
        mov     di, si
        ; copy name (DTA+1Eh) ASCIIZ, max 13
        mov     si, dta_buf+1Eh
        mov     cx, 13
.cpn:
        lodsb
        mov     [di], al
        inc     di
        or      al, al
        jz      .nend
        loop    .cpn
        mov     byte [di], 0
.nend:
        ; attr
        mov     ax, [_count]
        call    entry_ptr           ; -> si=dest base
        mov     al, [dta_buf+15h]
        mov     [si+E_ATTR], al
        ; size dword (DTA+1Ah)
        mov     ax, [dta_buf+1Ah]
        mov     [si+E_SIZE], ax
        mov     ax, [dta_buf+1Ch]
        mov     [si+E_SIZE+2], ax
        ; time / date
        mov     ax, [dta_buf+16h]
        mov     [si+E_TIME], ax
        mov     ax, [dta_buf+18h]
        mov     [si+E_DATE], ax
        inc     word [_count]
.skip:
        ret

%ifdef FEAT_LFN_FULL
; copy one WIN32_FIND_DATA result (in copybuf) into the panel entry array.
; Mirrors accept_dta but reads from the LFN 714Eh/714Fh output buffer.
; WIN32_FIND_DATA offsets: attrs+0, nFileSizeHigh+28, nFileSizeLow+32,
;   cFileName+44 (long), cAlternateFileName+304 (8.3, up to 14 bytes).
accept_lfn:
        ; skip "." always (use cAlternateFileName at copybuf+304)
        mov     al, [copybuf+304]
        cmp     al, '.'
        jne     .keep
        mov     al, [copybuf+305]
        or      al, al
        jz      .skip               ; "."  -> skip
        cmp     al, '.'
        jne     .keep
        ; ".." -> skip if at root
        mov     bx, [ppanel]
        lea     si, [bx+P_PATH]
        call    strlen
        cmp     ax, 3               ; "C:\" == root
        jbe     .skip
.keep:
        mov     ax, [_count]
        cmp     ax, MAX_FILES
        jae     .skip
        call    entry_ptr           ; ax=index -> si = dest entry
        mov     di, si
        ; copy 8.3 name from cAlternateFileName (copybuf+304), max 13 bytes
        mov     si, copybuf+304
        mov     cx, 13
.cpn:
        lodsb
        mov     [di], al
        inc     di
        or      al, al
        jz      .nend
        loop    .cpn
        mov     byte [di], 0
.nend:
        ; attr: low byte of dwFileAttributes at copybuf+0
        mov     ax, [_count]
        call    entry_ptr           ; -> si = dest entry base
        mov     al, [copybuf+0]
        mov     [si+E_ATTR], al
        ; size: low word then high word of nFileSizeLow (DWORD at copybuf+32)
        mov     ax, [copybuf+32]
        mov     [si+E_SIZE], ax
        mov     ax, [copybuf+34]
        mov     [si+E_SIZE+2], ax
        ; time/date not in DOS packed format in WIN32_FIND_DATA -- zero out
        mov     word [si+E_TIME], 0
        mov     word [si+E_DATE], 0
        inc     word [_count]
.skip:
        ret
%endif

; build "PATH\*.*" ASCIIZ into srchbuf (panel = [ppanel]) ---------------------
build_search:
        mov     bx, [ppanel]
        lea     si, [bx+P_PATH]
        mov     di, srchbuf
.cp:
        lodsb
        or      al, al
        jz      .end
        mov     [di], al
        inc     di
        jmp     .cp
.end:
        ; di points after path. Ensure trailing backslash.
        cmp     byte [di-1], '\'
        je      .star
        mov     byte [di], '\'
        inc     di
.star:
        mov     byte [di], '*'
        mov     byte [di+1], '.'
        mov     byte [di+2], '*'
        mov     byte [di+3], 0
        ret

; ============================================================================
;  PATH MANIPULATION
; ============================================================================
; append "\NAME" to active panel path. di -> NAME (ASCIIZ). bx=panel.
path_append:
        mov     si, di              ; si = name
        mov     bx, [active]
        lea     di, [bx+P_PATH]
        call    strlen_di           ; -> ax=len, di at end
        ; if last char != '\' add one
        cmp     byte [di-1], '\'
        je      .nm
        mov     byte [di], '\'
        inc     di
.nm:
        ; copy name
.cn:
        lodsb
        mov     [di], al
        inc     di
        or      al, al
        jnz     .cn
        ret

; go up one directory in active panel path -----------------------------------
path_up:
        mov     bx, [active]
        lea     di, [bx+P_PATH]
        call    strlen_di           ; di at terminator
        ; di-1 = last char. Walk back to previous '\'
        dec     di                  ; last char
.back:
        ; stop if di reaches path+3 (just after "C:\")
        lea     ax, [bx+P_PATH+2]   ; the root backslash position
        cmp     di, ax
        jbe     .root
        cmp     byte [di], '\'
        je      .cut
        dec     di
        jmp     .back
.cut:
        ; di points at a backslash that separates parent\child
        ; if it's the root backslash, keep it (set terminator after it)
        lea     ax, [bx+P_PATH+2]
        cmp     di, ax
        jne     .normal
        mov     byte [di+1], 0
        ret
.normal:
        mov     byte [di], 0
        ret
.root:
        ; already at root "C:\" -> keep terminator after backslash
        mov     byte [bx+P_PATH+3], 0
        ret

; go up a folder in the active panel, leaving the cursor on the child we left
go_parent:
%ifdef FEAT_RESULTS
        mov     bx, [active]
        cmp     byte [bx+P_SRC], SRC_RESULT
        jne     .notresult_gp
        mov     byte [bx+P_SRC], SRC_DIR    ; leave results -> the searched folder
        call    read_dir
        ret
.notresult_gp:
%endif
%ifdef FEAT_VFS
        mov     bx, [active]
        cmp     byte [bx+P_VFS], 0
        je      .real
        mov     byte [bx+P_VFS], 0  ; leaving a container -> back to its folder
        call    read_dir
        ret
.real:
%endif
        mov     bx, [active]
        ; capture the last path component of P_PATH into comefrom
        lea     si, [bx+P_PATH]
        mov     di, si
.fend:
        cmp     byte [di], 0
        je      .feod
        inc     di
        jmp     .fend
.feod:
        ; di at terminator; walk back to the separating '\'
.fb:
        cmp     di, si
        jbe     .nolf
        dec     di
        cmp     byte [di], '\'
        jne     .fb
        inc     di                  ; di -> leaf start
        mov     si, di
        mov     di, comefrom
.fc:
        mov     al, [si]
        mov     [di], al
        or      al, al
        jz      .doup
        inc     si
        inc     di
        jmp     .fc
.nolf:
        mov     byte [comefrom], 0
.doup:
        mov     bx, [active]
        call    path_up
        mov     bx, [active]
        call    read_dir
        ; select the remembered child among the parent's entries
        cmp     byte [comefrom], 0
        je      .ret
        mov     bx, [active]
        mov     [ppanel], bx
        mov     cx, [bx+P_COUNT]
        jcxz    .ret
        xor     dx, dx              ; entry index
.scan:
        mov     ax, dx
        call    entry_ptr           ; si -> entry (name at offset 0)
        mov     di, comefrom
        call    streqi              ; CF=1 if equal (cx/dx preserved)
        jc      .found
        inc     dx
        cmp     dx, cx
        jb      .scan
        ret                         ; not found -> cursor stays at top
.found:
        mov     bx, [active]
        mov     [bx+P_CUR], dx
        call    fix_scroll
.ret:
        ret

; ============================================================================
;  SORT (insertion sort on entry array; dirs first, ".." first, name asc)
; ============================================================================
sort_panel:
        mov     bx, [ppanel]
        mov     cx, [bx+P_COUNT]
        cmp     cx, 2
        jb      .done
        mov     bp, 1               ; i
.outer:
        cmp     bp, cx
        jae     .done
        ; temp = entry[i]
        mov     ax, bp
        call    entry_ptr           ; -> si
        mov     di, sort_tmp
        push    cx
        mov     cx, ENTSIZE
        rep     movsb
        pop     cx
        ; j = i-1
        mov     dx, bp
        dec     dx                  ; j (signed via comparisons)
.inner:
        ; while j>=0 and order(entry[j], tmp) > 0
        ; check j>=0
        cmp     dx, 0
        jl      .place
        mov     ax, dx
        call    entry_ptr           ; -> si = entry[j]
        mov     di, sort_tmp
        push    cx
        push    dx
        call    order_cmp           ; si vs di -> ax (>0 means si after di)
        pop     dx
        pop     cx
        or      ax, ax
        jle     .place
        ; entry[j+1] = entry[j]
        mov     ax, dx
        call    entry_ptr           ; si = entry[j]
        push    si
        mov     ax, dx
        inc     ax
        call    entry_ptr           ; si = entry[j+1] (dest)
        mov     di, si
        pop     si
        push    cx
        mov     cx, ENTSIZE
        rep     movsb
        pop     cx
        dec     dx
        jmp     .inner
.place:
        ; entry[j+1] = tmp
        mov     ax, dx
        inc     ax
        call    entry_ptr           ; -> si dest
        mov     di, si
        mov     si, sort_tmp
        push    cx
        mov     cx, ENTSIZE
        rep     movsb
        pop     cx
        inc     bp
        jmp     .outer
.done:
        ret

; compare two entries by sort order. si=A, di=B.
; returns ax > 0 if A should come AFTER B; <0 before; 0 equal.
order_cmp:
        push    si
        push    di
        ; rank: ".." =0, dir=1, file=2
        call    rank_of             ; si -> al
        mov     bl, al
        xchg    si, di
        call    rank_of
        mov     bh, al
        xchg    si, di
        ; compare ranks
        mov     al, bl
        sub     al, bh              ; rankA - rankB
        cbw
        or      ax, ax
        jnz     .ret
        ; same rank. ".." and directories always sort by name; only files
        ; (rank 2) honour sort_mode. bl still holds the common rank here.
        cmp     bl, 2
        jne     .byname
        ; files: compare by sort_mode (0=name 1=ext 2=size 3=date), name tiebreak.
        mov     bl, [sort_mode]
        cmp     bl, 2
        je      .bysize
        cmp     bl, 3
        je      .bydate
        cmp     bl, 1
        je      .byext
.byname:
        lea     si, [si+E_NAME]
        lea     di, [di+E_NAME]
        call    strcmp_ci           ; -> ax
        jmp     .ret
.bysize:                            ; ascending file size (dirs split out by rank)
        mov     ax, [si+E_SIZE+2]
        mov     dx, [di+E_SIZE+2]
        cmp     ax, dx
        ja      .after
        jb      .before
        mov     ax, [si+E_SIZE]
        mov     dx, [di+E_SIZE]
        cmp     ax, dx
        ja      .after
        jb      .before
        jmp     .byname             ; equal size -> name tiebreak
.bydate:                            ; newest first (descending packed date/time)
        mov     ax, [si+E_DATE]
        mov     dx, [di+E_DATE]
        cmp     ax, dx
        ja      .before
        jb      .after
        mov     ax, [si+E_TIME]
        mov     dx, [di+E_TIME]
        cmp     ax, dx
        ja      .before
        jb      .after
        jmp     .byname
.byext:                             ; case-insensitive extension, name tiebreak
        push    si
        push    di
        mov     bx, si
        call    ext_of
        mov     si, ax
        mov     bx, di
        call    ext_of
        mov     di, ax
        call    strcmp_ci
        pop     di
        pop     si
        or      ax, ax
        jnz     .ret
        jmp     .byname
.after:
        mov     ax, 1
        jmp     .ret
.before:
        mov     ax, -1
.ret:
        pop     di
        pop     si
        ret

; bx = entry -> ax = ptr to extension chars (after the '.'), or to the
; terminating NUL when the name has no dot. Preserves si/di/cx/dx/bp.
ext_of:
        push    bx
        add     bx, E_NAME
.f:
        mov     al, [bx]
        or      al, al
        jz      .done
        cmp     al, '.'
        je      .dot
        inc     bx
        jmp     .f
.dot:
        inc     bx
.done:
        mov     ax, bx
        pop     bx
        ret

; rank of entry at si -> al (0=="..",1=dir,2=file)
rank_of:
        mov     al, [si+E_NAME]
        cmp     al, '.'
        jne     .notdd
        cmp     byte [si+E_NAME+1], '.'
        jne     .notdd
        cmp     byte [si+E_NAME+2], 0
        jne     .notdd
        xor     al, al              ; ".." -> 0
        ret
.notdd:
        test    byte [si+E_ATTR], 10h
        jz      .file
        mov     al, 1
        ret
.file:
        mov     al, 2
        ret

; ============================================================================
;  FORMATTING
; ============================================================================
; format entry (si) into rowbuf (already space-filled to [pcw]):
;   name left-justified, then size (or <DIR>/<UP>) right-justified.
SIZEW       equ 8
format_entry:
        ; Results rows (find and grep-file) render through the normal path: the
        ; basename in the name field and a number in the size field (size for real
        ; files; the first-match line number for grep-file rows, stashed in E_SIZE).
        push    si
        mov     di, rowbuf
        ; name field width = pcw - SIZEW - 1
        movzx   cx, byte [pcw]
        sub     cx, SIZEW+1
        lea     si, [si+E_NAME]
.nl:
        mov     al, [si]
        or      al, al
        jz      .ndone
        mov     [di], al
        inc     di
        inc     si
        loop    .nl
.ndone:
        pop     si
        ; size field at rowbuf + (pcw - SIZEW)
        movzx   bx, byte [pcw]
        sub     bx, SIZEW
        lea     di, [rowbuf+bx]
        ; ".." -> "<UP>", dir -> "<DIR>", file -> decimal size
        mov     al, [si+E_NAME]
        cmp     al, '.'
        jne     .chkdir
        cmp     byte [si+E_NAME+1], '.'
        jne     .chkdir
        mov     si, str_up
        jmp     .putlabel
.chkdir:
        test    byte [si+E_ATTR], 10h
        jz      .num
        mov     si, str_dir
.putlabel:
        ; right-justify label in SIZEW field
        push    si
        call    strlen              ; ax=len
        mov     cx, SIZEW
        sub     cx, ax              ; leading spaces
        add     di, cx
        pop     si
.lp:
        mov     al, [si]
        or      al, al
        jz      .ret
        mov     [di], al
        inc     di
        inc     si
        jmp     .lp
.num:
        ; file: right-justified field shows size / date / time per col_mode.
%ifdef FEAT_COLS
        mov     bl, [col_mode]
        or      bl, bl
        jz      .numsize
        cmp     bl, 1
        je      .numdate
        cmp     bl, 2
        je      .numtime
        mov     al, [si+E_ATTR]     ; mode 3 = attributes
        call    fmt_attr            ; -> si=numbuf, cx=len
        jmp     .numjust
.numdate:
        mov     ax, [si+E_DATE]
        call    fmt_date            ; -> si=numbuf, cx=len
        jmp     .numjust
.numtime:
        mov     ax, [si+E_TIME]
        call    fmt_time            ; -> si=numbuf, cx=len
        jmp     .numjust
.numsize:
%endif
        mov     ax, [si+E_SIZE]
        mov     dx, [si+E_SIZE+2]
        ; di -> field start; produce into numbuf then right-justify
        call    fmt_size            ; dx:ax -> human-readable "nnn U" in numbuf
.numjust:
        mov     bx, SIZEW
        sub     bx, cx              ; leading spaces
        add     di, bx
.cp:
        mov     al, [si]
        or      al, al
        jz      .ret
        mov     [di], al
        inc     di
        inc     si
        jmp     .cp
.ret:
        ret


; fill rowbuf with [pcw] spaces, null-terminate
clear_rowbuf:
        mov     di, rowbuf
        movzx   cx, byte [pcw]
        mov     al, ' '
        push    cx
        rep     stosb
        pop     cx
        mov     byte [rowbuf+0], ' '   ; (already) ; ensure
        ; null terminator just past field
        movzx   bx, byte [pcw]
        mov     byte [rowbuf+bx], 0
        ret

; unsigned 32-bit dx:ax -> decimal ASCII (left aligned) ending at numbuf+15.
; returns si=first digit, cx=length.
u32toa:
        push    di                  ; preserve caller's di (it builds output position)
        mov     di, numbuf+15
        mov     byte [di], 0
.dl:
        ; divide dx:ax by 10 -> quotient in (si:ax), remainder in dx
        mov     cx, ax              ; save low
        mov     ax, dx              ; high
        xor     dx, dx
        mov     bx, 10
        div     bx                  ; ax = high/10 , dx = high%10
        mov     si, ax              ; quotient high
        mov     ax, cx              ; low
        div     bx                  ; ax = quotient low , dx = remainder digit
        add     dl, '0'
        dec     di
        mov     [di], dl
        mov     dx, si              ; dx:ax = quotient
        mov     cx, ax
        or      cx, dx
        jnz     .dl
        mov     si, di              ; first digit (build pointer)
        mov     cx, numbuf+15
        sub     cx, si              ; length = end - start
        pop     di                  ; restore caller's di
        ret

; human-readable size: dx:ax -> "nnn U" right-justified in SIZEW=8 chars.
; Uses same interface as u32toa: returns si=start in numbuf, cx=length.
; Thresholds: <1K -> B, <1M -> K, <1G -> M, else G.
; Any 32-bit value converges within 3 shifts (4GB>>30 = 3 < 1024).
fmt_size:
        push    di
        mov     si, .suffixes       ; si -> 'B','K','M','G'
.loop:
        or      dx, dx
        jnz     .do_shift           ; dx != 0 means >= 64K, keep shifting
        cmp     ax, 1024
        jb      .write_num          ; value < 1024, done
.do_shift:
        mov     cx, dx
        shl     cx, 6               ; carry high bits into low result
        shr     ax, 10
        or      ax, cx              ; ax = low 16 bits of (dx:ax >> 10)
        shr     dx, 10
        inc     si                  ; advance to next unit
        jmp     .loop
.write_num:
        mov     bl, [si]            ; bl = unit char (B/K/M/G)
        mov     di, numbuf+15
        mov     byte [di], 0        ; null terminator
        dec     di
        mov     [di], bl            ; unit char at +14
        dec     di
        mov     byte [di], ' '      ; space at +13
        dec     di                  ; di -> slot for last digit (starts at +12)
        or      dx, dx              ; dx should be 0; guard against overflow
        jz      .digits
        mov     ax, 9999
        xor     dx, dx
.digits:
        mov     bx, 10
        or      ax, ax
        jnz     .dl
        mov     byte [di], '0'      ; special case: value == 0
        dec     di
        jmp     .done
.dl:
        xor     dx, dx
        div     bx                  ; ax=quotient, dx=remainder digit
        add     dl, '0'
        mov     [di], dl
        dec     di
        or      ax, ax
        jnz     .dl
.done:
        inc     di                  ; di -> first digit
        mov     si, di              ; return: si = start of result in numbuf
        mov     cx, numbuf+15
        sub     cx, si              ; return: cx = length (excl. null)
        pop     di
        ret
.suffixes: db 'B','K','M','G'

; ============================================================================
;  SMALL HELPERS
; ============================================================================
; ax=index -> si = &panel[ppanel].entries[index]
entry_ptr:
        push    ax
        push    dx
        mov     dx, ENTSIZE
        mul     dx                  ; dx:ax = index*ENTSIZE  (index<700 -> no carry)
        mov     si, [ppanel]
        add     si, P_ENTRIES
        add     si, ax
        pop     dx
        pop     ax
        ret

; bx=panel -> si = entry at cursor
cur_entry_ptr:
        push    ax
        mov     [ppanel], bx
        mov     ax, [bx+P_CUR]
        call    entry_ptr
        pop     ax
        ret

; si -> ax = strlen (si preserved)
strlen:
        push    si
        xor     ax, ax
.l:
        cmp     byte [si], 0
        je      .e
        inc     si
        inc     ax
        jmp     .l
.e:
        pop     si
        ret

; di advanced to its NUL terminator (di on entry -> string)
strlen_di:
.l:
        cmp     byte [di], 0
        je      .e
        inc     di
        jmp     .l
.e:
        ret

; case-insensitive compare ds:si vs ds:di -> ax (<0,0,>0). si/di clobbered.
strcmp_ci:
.l:
        mov     al, [si]
        mov     bl, [di]
        cmp     al, 'A'
        jb      .a1
        cmp     al, 'Z'
        ja      .a1
        add     al, 20h
.a1:
        cmp     bl, 'A'
        jb      .b1
        cmp     bl, 'Z'
        ja      .b1
        add     bl, 20h
.b1:
        cmp     al, bl
        jne     .diff
        or      al, al
        jz      .eq
        inc     si
        inc     di
        jmp     .l
.diff:
        sub     al, bl
        cbw
        ret
.eq:
        xor     ax, ax
        ret

; ax=row, bx=col -> di = byte offset into video
rc_to_off:
        push    ax
        push    dx
        mov     dx, ROW_BYTES
        mul     dx
        mov     di, ax
        shl     bx, 1
        add     di, bx
        shr     bx, 1
        pop     dx
        pop     ax
        ret

; write cx chars from ds:si to video at di, attribute ah
putbuf:
        push    es
        push    ax
        mov     ax, [vseg]
        mov     es, ax
        pop     ax                  ; restore ah=attr
.l:
        mov     al, [si]
        mov     [es:di], al
        mov     [es:di+1], ah
        inc     si
        add     di, 2
        loop    .l
        pop     es
        ret

hide_cursor:
        mov     ah, 1
        mov     cx, 2000h
        int     10h
        ret
show_cursor:
        mov     ah, 1
        mov     cx, 0607h
        int     10h
        ret

; ============================================================================
;  TEST-MODE: screen dump + scripted keys
; ============================================================================
open_dump:
        mov     ah, 3Ch
        xor     cx, cx
        mov     dx, dumpname
        int     21h
        jc      .err
        mov     [dumph], ax
        ret
.err:
        mov     word [dumph], 0FFFFh
        ret

close_dump:
        mov     bx, [dumph]
        cmp     bx, 0FFFFh
        je      .r
        mov     ah, 3Eh
        int     21h
.r:
        ret

dump_screen:
        mov     bx, [dumph]
        cmp     bx, 0FFFFh
        je      .r
        push    es
        xor     bp, bp              ; row
.row:
        cmp     bp, SCR_H
        jae     .sep
        mov     ax, [vseg]
        mov     es, ax
        mov     ax, bp
        mov     dx, ROW_BYTES
        mul     dx
        mov     si, ax              ; video source offset
        mov     di, linebuf
        mov     cx, SCR_W
.col:
        mov     al, [es:si]
        mov     [di], al
        inc     di
        add     si, 2
        loop    .col
        mov     word [di], 0A0Dh    ; CR,LF
        mov     cx, SCR_W+2
        mov     dx, linebuf
        mov     bx, [dumph]
        mov     ah, 40h
        int     21h
        inc     bp
        jmp     .row
.sep:
        mov     dx, dumpsep
        mov     cx, dumpsep_len
        mov     bx, [dumph]
        mov     ah, 40h
        int     21h
        pop     es
.r:
        ret

load_keys:
        mov     ah, 3Dh
        xor     al, al
        mov     dx, keyname
        int     21h
        jc      .none
        mov     bx, ax
        mov     ah, 3Fh
        mov     cx, KEYBUF_MAX
        mov     dx, keybuf
        int     21h
        mov     [keylen], ax
        mov     ah, 3Eh
        int     21h
        ret
.none:
        mov     word [keylen], 0
        ret

; -> al=ascii, ah=scan
get_key:
        cmp     byte [test_mode], 0
        je      .live
        cmp     byte [want_keys], 0
        je      .quit
        mov     bx, [keypos]
        cmp     bx, [keylen]
        jae     .quit
        mov     al, [keybuf+bx]
        mov     ah, [keybuf+bx+1]
        add     word [keypos], 2
        ret
.quit:
        xor     al, al
        mov     ah, 44h             ; simulate F10
        ret
.live:
.poll:
        call    widgets_tick        ; idle refresh (clock ticks once a second)
        mov     ah, 1               ; keystroke waiting?
        int     16h
        jnz     .kbonly
        cmp     byte [mouse_ok], 0
        je      .poll               ; no mouse -> keep polling (key / clock)
        call    mouse_poll          ; CF=1 -> ax = synthetic key
        jc      .mret
        jmp     .poll
.kbonly:
        mov     ah, 00h             ; legacy read: gray arrows -> al=0, ah=scan
        int     16h
.mret:
        ret

; ============================================================================
;  COMMAND EXECUTION  (shell out to COMSPEC /C <cmdline>)
; ============================================================================
%include "mod/shell.inc"
; ============================================================================
;  MODAL DIALOGS  (shared by file operations)
; ============================================================================
DLG_R0  equ 9
DLG_R1  equ 13
DLG_C0  equ 14
DLG_C1  equ 65
A_DLG   equ 030h            ; black on cyan (box + prompt)
A_DLGF  equ 070h            ; black on grey (input field)
A_BTN   equ 03Fh            ; bright white on cyan (unfocused button)
A_BTNSEL equ 070h           ; black on white (focused button)
; confirm-dialog button geometry (row + column spans), symmetric in the box
BTN_ROW equ DLG_R0+3
YES_C0  equ 28
YES_C1  equ 34              ; "[ Yes ]" (7 cols)
NO_C0   equ 45
NO_C1   equ 50              ; "[ No ]"  (6 cols)
; overwrite-dialog button geometry: [Overwrite] [Skip] [All] [Cancel]
OWR_C0  equ 17
OWR_C1  equ 27              ; "[Overwrite]" (11 cols)
SKP_C0  equ 31
SKP_C1  equ 36              ; "[Skip]" (6 cols)
OAL_C0  equ 40
OAL_C1  equ 44              ; "[All]" (5 cols)
CAN_C0  equ 48
CAN_C1  equ 55              ; "[Cancel]" (8 cols)
; mouse routing modes
MM_BROWSER  equ 0
MM_OFF      equ 1
MM_CONFIRM  equ 2
MM_OWRITE   equ 3

; draw the double-line dialog box + clear interior
dlg_box:
        push    es
        mov     ax, [vseg]
        mov     es, ax
        mov     bx, DLG_R0
.row:
        mov     ax, bx
        imul    ax, ROW_BYTES
        add     ax, DLG_C0*2
        mov     di, ax
        mov     si, DLG_C0
.col:
        call    dlg_cell            ; bx=row si=col -> al=char
        mov     ah, A_DLG
        mov     [es:di], ax
        add     di, 2
        inc     si
        cmp     si, DLG_C1
        jbe     .col
        inc     bx
        cmp     bx, DLG_R1
        jbe     .row
        pop     es
        ret

; pick the CP437 char for cell (bx=row, si=col) -> al
dlg_cell:
        cmp     bx, DLG_R0
        je      .top
        cmp     bx, DLG_R1
        je      .bot
        cmp     si, DLG_C0
        je      .v
        cmp     si, DLG_C1
        je      .v
        mov     al, ' '
        ret
.v:     mov     al, 0BAh            ; vertical
        ret
.top:
        cmp     si, DLG_C0
        je      .tl
        cmp     si, DLG_C1
        je      .tr
        mov     al, 0CDh            ; horizontal
        ret
.tl:    mov     al, 0C9h
        ret
.tr:    mov     al, 0BBh
        ret
.bot:
        cmp     si, DLG_C0
        je      .bl
        cmp     si, DLG_C1
        je      .br
        mov     al, 0CDh
        ret
.bl:    mov     al, 0C8h
        ret
.br:    mov     al, 0BCh
        ret

; write ASCIIZ ds:si at es:di (es set to VIDEO here), attribute ah; di advances
putzstr:
        push    es
        push    ax
        mov     ax, [vseg]
        mov     es, ax
        pop     ax
.l:     mov     al, [si]
        or      al, al
        jz      .e
        mov     [es:di], al
        mov     [es:di+1], ah
        inc     si
        add     di, 2
        jmp     .l
.e:     pop     es
        ret

; ----------------------------------------------------------------------------
; progress / "please wait" box, shown during long copy/delete operations so the
; screen doesn't look frozen. busy_box draws the frame + title once; busy_name
; updates the second line with the item currently being processed. Both save
; every register so they can be sprinkled inside the recursive tree walkers.
; ----------------------------------------------------------------------------
busy_box:                       ; ds:si = title
        pusha
        push    es
        call    mouse_hide
        call    dlg_box
        mov     ax, DLG_R0+1
        mov     bx, DLG_C0+2
        call    rc_to_off
        mov     ah, A_DLG
        call    putzstr
        pop     es
        popa
        ret

busy_name:                      ; ds:si = ASCIIZ name/path (clipped to box width)
        pusha
        push    es
        mov     ax, [vseg]
        mov     es, ax
        mov     ax, DLG_R0+2
        mov     bx, DLG_C0+2
        call    rc_to_off           ; di = row start
        mov     dx, DLG_C1-DLG_C0-3 ; interior width
        mov     cx, dx
        push    di
.clr:   mov     byte [es:di], ' '
        mov     byte [es:di+1], A_DLG
        add     di, 2
        loop    .clr
        pop     di
        mov     cx, dx
.wr:    mov     al, [si]
        or      al, al
        jz      .done
        jcxz    .done
        mov     [es:di], al
        mov     byte [es:di+1], A_DLG
        inc     si
        add     di, 2
        dec     cx
        jmp     .wr
.done:
        pop     es
        popa
        ret

; input dialog: si=prompt. Text -> dlgbuf (NUL-term) + dlglen. CF=1 if cancelled.
dlg_input:
        mov     word [dlglen], 0    ; no prefill
dlg_input_pre:                      ; enter here with dlgbuf/dlglen preset
        mov     [dlg_prompt], si
        call    dlg_box
        mov     ax, DLG_R0+1
        mov     bx, DLG_C0+2
        call    rc_to_off
        mov     si, [dlg_prompt]
        mov     ah, A_DLG
        call    putzstr
        mov     byte [mouse_mode], MM_OFF
.loop:
        call    dlg_field
        call    get_key
        cmp     al, 0Dh
        je      .ok
        cmp     al, 1Bh
        je      .cancel
        cmp     al, 08h
        je      .bksp
        cmp     al, 20h
        jb      .loop
        cmp     al, 7Eh
        ja      .loop
        mov     bx, [dlglen]
        cmp     bx, 40
        jae     .loop
        mov     [dlgbuf+bx], al
        inc     word [dlglen]
        jmp     .loop
.bksp:
        cmp     word [dlglen], 0
        je      .loop
        dec     word [dlglen]
        jmp     .loop
.ok:
        mov     byte [mouse_mode], MM_BROWSER
        mov     bx, [dlglen]
        mov     byte [dlgbuf+bx], 0
        clc
        ret
.cancel:
        mov     byte [mouse_mode], MM_BROWSER
        mov     word [dlglen], 0
        mov     byte [dlgbuf], 0
        stc
        ret

; redraw the input field row with current dlgbuf + trailing cursor
dlg_field:
        push    es
        mov     ax, [vseg]
        mov     es, ax
        mov     ax, DLG_R0+2
        mov     bx, DLG_C0+2
        call    rc_to_off
        mov     cx, DLG_C1-DLG_C0-3
        mov     ah, A_DLGF
        push    di
.clr:   mov     byte [es:di], ' '
        mov     [es:di+1], ah
        add     di, 2
        loop    .clr
        pop     di
        mov     si, dlgbuf
        mov     cx, [dlglen]
        jcxz    .cur
.wr:    mov     al, [si]
        mov     [es:di], al
        mov     [es:di+1], ah
        inc     si
        add     di, 2
        loop    .wr
.cur:
        mov     byte [es:di], '_'
        mov     [es:di+1], ah
        pop     es
        ret

; confirm dialog: si=message. CF=0 if YES, CF=1 if NO.
; Navigable: Left/Right/Tab move focus, Enter/Space activate, Y/N shortcut,
; Esc = No, and the Yes/No buttons are mouse-clickable.
dlg_confirm:
        mov     [dlg_prompt], si
        mov     byte [dlg_focus], 0     ; default focus = Yes
        call    dlg_box
        mov     ax, DLG_R0+1
        mov     bx, DLG_C0+2
        call    rc_to_off
        mov     si, [dlg_prompt]
        mov     ah, A_DLG
        call    putzstr
        mov     byte [mouse_mode], MM_CONFIRM
.draw:
        call    dlg_draw_buttons
        cmp     byte [test_mode], 0
        jz      .k
        call    dump_screen         ; test harness: capture the dialog frame
.k:
        call    get_key
        cmp     al, 'y'
        je      .yes
        cmp     al, 'Y'
        je      .yes
        cmp     al, 'n'
        je      .no
        cmp     al, 'N'
        je      .no
        cmp     al, 1Bh             ; Esc -> No
        je      .no
        cmp     al, 0Dh             ; Enter -> activate focus
        je      .activate
        cmp     al, 20h             ; Space -> activate focus
        je      .activate
        cmp     al, 09h             ; Tab -> toggle focus
        je      .toggle
        or      al, al
        jnz     .k                  ; other ascii: ignore
        cmp     ah, 4Bh             ; Left  -> focus Yes
        je      .focusy
        cmp     ah, 4Dh             ; Right -> focus No
        je      .focusn
        jmp     .k
.toggle:
        xor     byte [dlg_focus], 1
        jmp     .draw
.focusy:
        mov     byte [dlg_focus], 0
        jmp     .draw
.focusn:
        mov     byte [dlg_focus], 1
        jmp     .draw
.activate:
        cmp     byte [dlg_focus], 0
        je      .yes
        jmp     .no
.yes:
        mov     byte [mouse_mode], MM_BROWSER
        clc
        ret
.no:
        mov     byte [mouse_mode], MM_BROWSER
        stc
        ret

; draw the Yes/No buttons, highlighting the one with focus
dlg_draw_buttons:
        mov     ax, BTN_ROW
        mov     bx, YES_C0
        call    rc_to_off
        mov     si, s_btn_yes
        mov     ah, A_BTN
        cmp     byte [dlg_focus], 0
        jne     .y2
        mov     ah, A_BTNSEL
.y2:    call    putzstr
        mov     ax, BTN_ROW
        mov     bx, NO_C0
        call    rc_to_off
        mov     si, s_btn_no
        mov     ah, A_BTN
        cmp     byte [dlg_focus], 1
        jne     .n2
        mov     ah, A_BTNSEL
.n2:    call    putzstr
        ret

; ----------------------------------------------------------------------------
; overwrite prompt: ds:si = name of the file about to be overwritten.
; Returns the choice in al: 0=overwrite, 1=skip, 2=overwrite All, 3=cancel.
; Keyboard O/S/A/C(+Esc), Enter/Space activate the focused button, Left/Right
; and Tab move focus, and all four buttons are mouse-clickable.
; ----------------------------------------------------------------------------
dlg_overwrite:
        mov     [dlg_prompt], si       ; stash the filename pointer
        mov     byte [ow_focus], 0     ; default focus = Overwrite
        call    mouse_show             ; copy hid the cursor; show it for clicks
        call    dlg_box
        mov     ax, DLG_R0+1
        mov     bx, DLG_C0+2
        call    rc_to_off
        mov     si, s_owmsg
        mov     ah, A_DLG
        call    putzstr
        mov     si, [dlg_prompt]
        call    busy_name              ; draws the clipped filename on line 2
        mov     byte [mouse_mode], MM_OWRITE
.draw:
        call    ow_draw_buttons
        cmp     byte [test_mode], 0
        jz      .k
        call    dump_screen
.k:
        call    get_key
        cmp     al, 'o'
        je      .ovr
        cmp     al, 'O'
        je      .ovr
        cmp     al, 's'
        je      .skp
        cmp     al, 'S'
        je      .skp
        cmp     al, 'a'
        je      .all
        cmp     al, 'A'
        je      .all
        cmp     al, 'c'
        je      .can
        cmp     al, 'C'
        je      .can
        cmp     al, 1Bh             ; Esc -> cancel
        je      .can
        cmp     al, 0Dh             ; Enter -> activate focus
        je      .activate
        cmp     al, 20h             ; Space -> activate focus
        je      .activate
        cmp     al, 09h             ; Tab -> next focus
        je      .tabf
        or      al, al
        jnz     .k
        cmp     ah, 4Bh             ; Left
        je      .leftf
        cmp     ah, 4Dh             ; Right
        je      .rightf
        jmp     .k
.tabf:
        mov     al, [ow_focus]
        inc     al
        cmp     al, 4
        jb      .setf
        xor     al, al
.setf:  mov     [ow_focus], al
        jmp     .draw
.leftf:
        mov     al, [ow_focus]
        or      al, al
        jz      .draw
        dec     al
        mov     [ow_focus], al
        jmp     .draw
.rightf:
        mov     al, [ow_focus]
        cmp     al, 3
        jae     .draw
        inc     al
        mov     [ow_focus], al
        jmp     .draw
.activate:
        mov     al, [ow_focus]
        cmp     al, 0
        je      .ovr
        cmp     al, 1
        je      .skp
        cmp     al, 2
        je      .all
        jmp     .can
.ovr:   mov     al, 0
        jmp     .done
.skp:   mov     al, 1
        jmp     .done
.all:   mov     al, 2
        jmp     .done
.can:   mov     al, 3
.done:
        mov     byte [mouse_mode], MM_BROWSER
        call    mouse_hide             ; restore the during-copy hidden state
        ret

; draw the four overwrite buttons, highlighting the focused one
ow_draw_buttons:
        mov     bx, OWR_C0
        mov     si, s_btn_ovr
        xor     cx, cx
        call    ow_one_btn
        mov     bx, SKP_C0
        mov     si, s_btn_skp
        mov     cx, 1
        call    ow_one_btn
        mov     bx, OAL_C0
        mov     si, s_btn_all
        mov     cx, 2
        call    ow_one_btn
        mov     bx, CAN_C0
        mov     si, s_btn_can
        mov     cx, 3
        call    ow_one_btn
        ret

; draw one button: bx=col, ds:si=label, cl=button index; highlight if focused
ow_one_btn:
        push    ax
        mov     ax, BTN_ROW
        call    rc_to_off
        mov     ah, A_BTN
        cmp     cl, [ow_focus]
        jne     .w
        mov     ah, A_BTNSEL
.w:     call    putzstr
        pop     ax
        ret

; ============================================================================
;  PATH BUILDERS for file ops
;    targpath  = source / existing entry's full path
;    targpath2 = destination / new name
; ============================================================================
; targpath = active-panel path + '\' + current entry name. si=entry (preserved).
build_entry_path:
        push    si
        mov     bx, [active]
        lea     si, [bx+P_PATH]
        mov     di, targpath
        call    bp_copy_dir
        pop     si
        push    si
        lea     si, [si+E_NAME]
        call    bp_copy_name
        pop     si
        ret

; targpath2 = active-panel path + '\' + dlgbuf  (mkdir / rename target)
build_target_path:
        mov     bx, [active]
        lea     si, [bx+P_PATH]
        mov     di, targpath2
        call    bp_copy_dir
        mov     si, dlgbuf
        call    bp_copy_name
        ret

; targpath2 = OTHER-panel path + '\' + current entry name. si=entry (preserved).
build_other_path:
        push    si
        call    other_panel_ptr     ; -> bx
        lea     si, [bx+P_PATH]
        mov     di, targpath2
        call    bp_copy_dir
        pop     si
        push    si
        lea     si, [si+E_NAME]
        call    bp_copy_name
        pop     si
        ret

; copy ASCIIZ dir ds:si -> es?no, ds:di, ensure trailing '\'. di left past it.
bp_copy_dir:
.cp:    mov     al, [si]
        or      al, al
        jz      .e
        mov     [di], al
        inc     di
        inc     si
        jmp     .cp
.e:     cmp     byte [di-1], '\'
        je      .done
        mov     byte [di], '\'
        inc     di
.done:  ret

; append ASCIIZ name ds:si -> ds:di (including terminator)
bp_copy_name:
.c:     mov     al, [si]
        mov     [di], al
        or      al, al
        jz      .done
        inc     di
        inc     si
        jmp     .c
.done:  ret

; bx = the panel that is NOT active
other_panel_ptr:
        mov     bx, [active]
        cmp     bx, panelL
        jne     .l
        mov     bx, panelR
        ret
.l:     mov     bx, panelL
        ret

; ============================================================================
;  FILE OPERATIONS
; ============================================================================
; re-read both panels (so a directory shown in both stays in sync after an op)
refresh_panels:
        mov     bx, panelL
        call    read_dir
        mov     bx, panelR
        call    read_dir
        ret

%include "mod/fileops.inc"
%include "mod/recurse.inc"
%include "mod/mouse.inc"
; BIOS tick counter low word (0040:006Ch) -> ax
get_tick:
        push    es
        push    bx
        xor     bx, bx
        mov     es, bx
        mov     ax, [es:046Ch]
        pop     bx
        pop     es
        ret

; map a click column [m_col] on the F-key bar to a synthetic key in ax.
; The bar is 10 even slots of 8 cols; slot = col/8, F-number = slot+1.
fbar_to_key:
        mov     ax, [m_col]
        shr     ax, 3               ; slot 0..9
        cmp     ax, 2
        je      .f3
        cmp     ax, 4
        je      .f5
        cmp     ax, 5
        je      .f6
        cmp     ax, 6
        je      .f7
        cmp     ax, 7
        je      .f8
        cmp     ax, 9
        je      .f10
.none:  xor     ax, ax
        ret
.f3:    mov     ax, 3D00h
        ret
.f5:    mov     ax, 3F00h
        ret
.f6:    mov     ax, 4000h
        ret
.f7:    mov     ax, 4100h
        ret
.f8:    mov     ax, 4200h
        ret
.f10:   mov     ax, 4400h
        ret

; F6 -- rename / move current entry to a name typed in a dialog
key_rename:
        mov     bx, [active]
        mov     cx, [bx+P_COUNT]
        jcxz    .ret
        call    cur_entry_ptr
        mov     al, [si+E_NAME]
        cmp     al, '.'
        jne     .ok
        cmp     byte [si+E_NAME+1], '.'
        je      .ret
.ok:
        push    si
        mov     si, s_rename
        call    dlg_input
        pop     si
        jc      .ret
        cmp     word [dlglen], 0
        je      .ret
        call    build_entry_path    ; targpath  = old full path
        call    build_target_path   ; targpath2 = active\newname
        push    ds
        pop     es
        mov     dx, targpath        ; ds:dx old
        mov     di, targpath2       ; es:di new
%ifndef FEAT_LFN_FULL
        mov     ah, 56h
%else
        mov     ax, 7156h           ; LFN Rename/Move
%endif
        int     21h
        call    refresh_panels
.ret:   ret

; copy file targpath -> targpath2 (512-byte chunks)
copy_file:
        cmp     byte [ow_cancel], 0
        jne     .ret                ; whole operation was cancelled
        mov     si, targpath        ; show what we're copying (anti-"frozen")
        call    busy_name
        ; overwrite policy: does the destination already exist?
        mov     ax, 4300h           ; get file attributes
        mov     dx, targpath2
        int     21h
        jc      .open               ; not found -> copy freely
        cmp     byte [ow_mode], 1
        je      .open               ; overwrite-all
        cmp     byte [ow_mode], 2
        je      .ret                ; skip-all
        mov     si, targpath2       ; ask: returns al = 0/1/2/3
        call    dlg_overwrite
        push    ax
        mov     si, s_busy_copy     ; the dialog clobbered the progress box
        call    busy_box
        mov     si, targpath
        call    busy_name
        pop     ax
        cmp     al, 1
        je      .ret                ; Skip this one
        cmp     al, 2
        je      .all
        cmp     al, 3
        je      .cancel
        jmp     .open               ; 0 = Overwrite this one
.all:
        mov     byte [ow_mode], 1
        jmp     .open
.cancel:
        mov     byte [ow_cancel], 1
        ret
.open:
%ifndef FEAT_LFN_FULL
        mov     ax, 3D00h           ; open src read-only
        mov     dx, targpath
%else
        mov     ax, 716Ch           ; LFN Extended Open: open existing read-only
        mov     bx, 0               ; access: read-only
        mov     cx, 0               ; attributes: normal
        mov     dx, 0001h           ; action: open-existing
        mov     si, targpath        ; DS:SI = path
%endif
        int     21h
        jc      .ret
        mov     [fh_src], ax
%ifndef FEAT_LFN_FULL
        xor     cx, cx              ; create dst (normal attr)
        mov     ah, 3Ch
        mov     dx, targpath2
%else
        mov     ax, 716Ch           ; LFN Extended Open: open-or-create write
        mov     bx, 1               ; access: write-only
        mov     cx, 0               ; attributes: normal
        mov     dx, 0012h           ; action: open-or-create
        mov     si, targpath2       ; DS:SI = path
%endif
        int     21h
        jc      .closesrc
        mov     [fh_dst], ax
.loop:
        mov     ah, 3Fh
        mov     bx, [fh_src]
        mov     cx, 512
        mov     dx, copybuf
        int     21h
        jc      .closeall
        or      ax, ax
        jz      .closeall           ; EOF
        mov     cx, ax
        mov     ah, 40h
        mov     bx, [fh_dst]
        mov     dx, copybuf
        int     21h
        jmp     .loop
.closeall:
        mov     ah, 3Eh
        mov     bx, [fh_dst]
        int     21h
.closesrc:
        mov     ah, 3Eh
        mov     bx, [fh_src]
        int     21h
.ret:   ret

; Insert -- toggle tag on current entry, advance cursor
key_tag:
        mov     bx, [active]
        mov     cx, [bx+P_COUNT]
        jcxz    .ret
        call    cur_entry_ptr
        mov     al, [si+E_NAME]
        cmp     al, '.'
        jne     .t
        cmp     byte [si+E_NAME+1], '.'
        je      .down               ; never tag ".."
.t:     xor     byte [si+E_ATTR], 40h
.down:
        call    key_down
.ret:   ret

; Alt+F1 / Alt+F2 -- switch a panel's drive (prompt for a letter)
key_drive_l:
        mov     bx, panelL
%ifdef FEAT_RESULTS
        jmp     drives_show         ; Alt-F1 -> browsable drive list (NC-style)
%else
        jmp     set_panel_drive     ; (no results panel -> fall back to the prompt)
%endif
key_drive_r:
        mov     bx, panelR
%ifdef FEAT_RESULTS
        jmp     drives_show
%else
        jmp     set_panel_drive
%endif
%ifndef FEAT_RESULTS
; Text-prompt drive switch (used only when the browsable drive list -- which
; needs the SRC_RESULT machinery in results.inc -- is not built, e.g. CCPOP).
set_panel_drive:
        push    bx
        mov     si, s_drive
        call    dlg_input
        pop     bx
        jc      .ret
        cmp     word [dlglen], 0
        je      .ret
        mov     al, [dlgbuf]
        cmp     al, 'a'
        jb      .u
        cmp     al, 'z'
        ja      .u
        sub     al, 20h
.u:
        mov     [bx+P_PATH], al
        mov     byte [bx+P_PATH+1], ':'
        mov     byte [bx+P_PATH+2], '\'
        mov     byte [bx+P_PATH+3], 0
        mov     word [bx+P_CUR], 0
        mov     word [bx+P_TOP], 0
        call    read_dir
.ret:   ret
%endif

; ============================================================================
;  F3 -- FILE VIEWER  (reads up to VIEW_MAX bytes, scrolls by line)
; ============================================================================
VIEW_MAX    equ 8192            ; built-in pager byte cap (8 KB; larger files
                                ;   truncate, as before -- external [view] tools
                                ;   handle big files). Trimmed 16->14->12->8 KB to
                                ;   keep the resident image under the std 63 KB
                                ;   wall as resident widgets (menu bar, Tools,
                                ;   hex view, FEAT_RESULTS search panel) were added.
MAX_VLINES  equ 1024
VIEW_ROWS   equ 23             ; text rows 1..23 (row 0 header, row 24 bar)
VIEW_TOP    equ 1              ; viewer content first row -- the full-screen pager
                              ; owns rows 0(header)..24(bar) regardless of the
                              ; panel's FIRST_ROW (which shifts under a menubar)
HEXW        equ 75             ; hex line width: 8 off + 2 + 16*3 + 1 + 16 ASCII
A_VHDR      equ 030h           ; black on cyan header
A_VTXT      equ 007h           ; grey on black text
A_VBAR      equ 030h           ; black on cyan bottom bar

%include "mod/viewer.inc"
%include "mod/harness.inc"
; ---- optional feature modules (gated by the build-profile feature set) ----
%ifdef FEAT_CLOCK
%include "mod/clock.inc"
%endif
%ifdef FEAT_SORT
%include "mod/sort.inc"
%endif
%ifdef FEAT_COLS
%include "mod/cols.inc"
%endif
%ifdef FEAT_FREE
%include "mod/free.inc"
%endif
%ifdef FEAT_WIDGETS
%include "mod/widgets.inc"
%endif
%ifdef FEAT_VIEWS
%include "mod/views.inc"
%endif
%ifdef FEAT_TREE
%include "mod/tree.inc"
%endif
%ifdef FEAT_SEARCH
%include "mod/search.inc"
%endif
%ifdef FEAT_MENUBAR
%include "mod/menubar.inc"
%elifdef FEAT_MENU
%include "mod/menu.inc"
%endif
%ifdef FEAT_TOOLS
%include "mod/tools.inc"
%endif
%ifdef FEAT_TOOLS_INI
%include "mod/toolsini.inc"
%endif
%ifdef FEAT_DISCOVER
%include "mod/discover.inc"
%endif
%ifdef FEAT_MASK
%include "mod/mask.inc"
%endif
%ifdef FEAT_EDIT
%include "mod/edit.inc"
%endif
%ifdef FEAT_FIND
%include "mod/find.inc"
%endif
%ifdef FEAT_RESULTS
%include "mod/results.inc"
%endif
%ifdef FEAT_GREP
%include "mod/grep.inc"
%endif
%ifdef FEAT_ATTR
%include "mod/attr.inc"
%endif
%ifdef FEAT_ZIP
%include "mod/zip.inc"
%endif
%ifdef FEAT_INI
%include "mod/ini.inc"
%endif
%ifdef FEAT_VFS
%include "mod/vfs.inc"
%endif
%ifdef FEAT_HELP
%include "mod/help.inc"
%endif
%ifdef FEAT_LANG
%include "mod/lang.inc"
%endif
%ifdef FEAT_LFN
%include "mod/lfn.inc"
%include "mod/lfnview.inc"
%endif

; ============================================================================
;  INITIALIZED DATA
; ============================================================================
; key dispatch table -- walked by dispatch:. Core bindings here; feature
; modules add their own KEYBIND_* rows before KEYBIND_END (see plan/m1_dispatch.md).
keytab:
        ; ---- extended keys (al==0, match scan in ah) ----
        KEYBIND_EXT 48h, key_up         ; Up
        KEYBIND_EXT 50h, key_down       ; Down
        KEYBIND_EXT 49h, key_pgup       ; PgUp
        KEYBIND_EXT 51h, key_pgdn       ; PgDn
%ifdef FEAT_VIEWS
        KEYBIND_EXT 4Bh, key_left       ; Left  -> col left (brief) / page up
        KEYBIND_EXT 4Dh, key_right      ; Right -> col right (brief) / page down
%else
        KEYBIND_EXT 4Bh, key_pgup       ; Left  -> page up   (alias)
        KEYBIND_EXT 4Dh, key_pgdn       ; Right -> page down (alias)
%endif
        KEYBIND_EXT 47h, key_home       ; Home
        KEYBIND_EXT 4Fh, key_end        ; End
%ifdef FEAT_HELP
        KEYBIND_EXT 3Bh, key_help       ; F1  Help (views cc.hlp)
%endif
        KEYBIND_EXT 3Dh, key_view       ; F3  View
%ifdef FEAT_EDIT
        KEYBIND_EXT 3Eh, key_edit       ; F4  Edit (launches CCEDIT.COM)
%endif
        KEYBIND_EXT 3Fh, key_copy       ; F5  Copy (to other panel, can rename)
        KEYBIND_EXT 40h, key_move       ; F6  Move  (to other panel, can rename)
        KEYBIND_EXT 59h, key_rename     ; Shift+F6  Rename in place
        KEYBIND_EXT 41h, key_mkdir      ; F7  MkDir
        KEYBIND_EXT 42h, key_delete     ; F8  Delete
        KEYBIND_EXT 52h, key_tag        ; Insert  tag
        KEYBIND_EXT 68h, key_drive_l    ; Alt+F1  left drive
        KEYBIND_EXT 69h, key_drive_r    ; Alt+F2  right drive
%ifdef FEAT_FIND
        KEYBIND_EXT 6Eh, key_find       ; Alt+F7  find files (CCFIND.COM)
%endif
%ifdef FEAT_GREP
        KEYBIND_EXT 6Fh, key_grep       ; Alt+F8  grep file contents (CCGREP.COM)
%endif
%ifdef FEAT_VFS
        KEYBIND_EXT 6Ch, key_pack       ; Alt+F5  pack tagged/cursor into archive
        KEYBIND_EXT 70h, key_unpackall  ; Alt+F9  extract-all the cursor archive
%endif
        KEYBIND_EXT 44h, key_quit       ; F10
        ; ---- ascii keys (al!=0, match ascii in al) ----
        KEYBIND_ASC 09h, key_tab        ; Tab
        KEYBIND_ASC 0Dh, on_enter       ; Enter
        KEYBIND_ASC 1Bh, on_esc         ; Esc -> clear command line
        KEYBIND_ASC 08h, on_bksp        ; Backspace
%ifdef FEAT_ATTR
        KEYBIND_ASC 01h, key_attr       ; Ctrl-A  edit file attributes
%endif
        ; printable 20h..7Eh -> cmd_addchar is the dispatch fallthrough, not a row
%ifdef FEAT_SORT
        ; --- mod/sort.inc : sort order (handlers in mod/sort.inc) ---
        KEYBIND_EXT 5Eh, sort_name      ; Ctrl-F1  by name
        KEYBIND_EXT 5Fh, sort_ext       ; Ctrl-F2  by extension
        KEYBIND_EXT 60h, sort_size      ; Ctrl-F3  by size
        KEYBIND_EXT 61h, sort_date      ; Ctrl-F4  by date (newest first)
%endif
%ifdef FEAT_COLS
        KEYBIND_EXT 62h, col_cycle      ; Ctrl-F5  cycle size/date/time column
%endif
%ifdef FEAT_SEARCH
        KEYBIND_EXT 63h, key_qsearch    ; Ctrl-F6  incremental quick-search
%endif
%ifdef FEAT_MENUBAR
        ; F9 (the pull-down bar) is owned by the menu-bar widget itself --
        ; see mb_key, claimed through the widgets_key seam. No keytab row.
%elifdef FEAT_MENU
        KEYBIND_EXT 43h, key_menu       ; F9  pop-up command menu
%endif
%ifdef FEAT_MASK
        KEYBIND_EXT 64h, key_mask_sel   ; Ctrl-F7  tag files by *.mask
        KEYBIND_EXT 65h, key_mask_unsel ; Ctrl-F8  untag files by *.mask
%endif
%ifdef FEAT_ZIP
        KEYBIND_EXT 66h, key_zip        ; Ctrl-F9  list archive (CCZIP.COM)
%endif
%ifdef FEAT_VIEWS
        KEYBIND_EXT 67h, key_view_toggle ; Ctrl-F10 toggle full / brief body view
        KEYBIND_EXT 6Ah, key_view_toggle ; Alt-F3   brief-view toggle (DOSBox-safe)
%endif
%ifdef FEAT_TREE
        KEYBIND_EXT 71h, key_tree       ; Alt-F10  modal directory-tree browser
%endif
        KEYBIND_END                     ; sentinel

; function-key bar: 10 labels, one per 8-column slot (drawn by draw_fkeys)
fk_tbl      dw fk0,fk1,fk2,fk3,fk4,fk5,fk6,fk7,fk8,fk9
fk0         db '1Help',0
fk1         db '2Menu',0
fk2         db '3View',0
fk3         db '4Edit',0
fk4         db '5Copy',0
fk5         db '6Move',0
fk6         db '7MkDir',0
fk7         db '8Del',0
fk8         db '9Menu',0
fk9         db '10Quit',0
str_dir     db '<DIR>',0
str_up      db '<UP>',0
dumpname    db 'CCDUMP.TXT',0
%ifdef FEAT_SNAP
snapname    db 'CCSNAP.BIN',0
%endif
keyname     db 'cc.key',0
dumpsep     db '==== FRAME ====',0Dh,0Ah
dumpsep_len equ $-dumpsep
dbg_cnt     db 'count=',0
s_comspec   db 'COMSPEC=',0
s_defcom    db 'COMMAND.COM',0
s_slashc    db ' /C ',0
s_exe       db 'EXE'
s_com       db 'COM'
s_bat       db 'BAT'
s_runmsg    db 0Dh,0Ah,'[Claude Commander] running command...',0Dh,0Ah,'$'
s_anykey    db 0Dh,0Ah,'Press any key to return to Claude Commander...',0Dh,0Ah,'$'
s_mkdir     db 'Create directory:',0
s_rename    db 'Rename/move current entry to:',0
%ifndef FEAT_RESULTS
s_drive     db 'Switch to drive (A-Z):',0
%endif
s_delconf   db 'Delete the current entry?',0
s_copyto    db 'Copy to other panel as:',0
s_moveto    db 'Move to other panel as:',0
s_copyconf  db 'Copy the tagged entries?',0
s_moveconf  db 'Move the tagged entries?',0
s_busy_copy db 'Copying, please wait...',0
s_busy_move db 'Moving, please wait...',0
s_busy_del  db 'Deleting, please wait...',0
s_btn_yes   db '[ Yes ]',0
s_btn_no    db '[ No ]',0
s_owmsg     db 'File exists - overwrite?',0
s_btn_ovr   db '[Overwrite]',0
s_btn_skp   db '[Skip]',0
s_btn_all   db '[All]',0
s_btn_can   db '[Cancel]',0
s_viewhdr   db '   [ View ]',0
s_viewbar   db ' Up/Dn PgUp/PgDn Home/End scroll   H hex   E edit   Esc/F3 quit',0
s_hexhdr    db '   [ Hex ]',0
s_hexbar    db ' Up/Dn PgUp/PgDn Home/End scroll   H text  E hex-edit   Esc/F3 quit',0
s_cchexed   db 'CCHEXED',0

active      dw 0
ppanel      dw 0
vseg        dw VIDEO        ; current draw target segment: VIDEO normally, the
                            ; off-screen buffer only during render_all's widget
                            ; pass (double-buffering: kills full-screen flicker)
bufseg      dw 0            ; allocated back-buffer segment (0 = none -> draw live)
quit_flag   db 0
test_mode   db 0
want_keys   db 0
count_dbg   db 0
%ifdef FEAT_SNAP
snap_mode   db 0
%endif
sort_mode   db 0            ; 0=name 1=ext 2=size 3=date (FEAT_SORT)
col_mode    db 0            ; right column: 0=size 1=date 2=time (FEAT_COLS)
orig_mode   db 3
pcx         db 0
pcw         db 0
tattr       db 0
rattr       db 0
_count      dw 0
keypos      dw 0
keylen      dw 0
dumph       dw 0FFFFh

; ============================================================================
;  RESERVED BUFFERS  (must stay LAST so the .COM emits no bytes for them)
; ============================================================================
KEYBUF_MAX  equ 512
section .bss
align 2
rowbuf      resb 84
numbuf      resb 16
%ifdef FEAT_FREE
footbuf     resb 48         ; mod/free.inc footer text scratch
%endif
%ifdef FEAT_SEARCH
qsbuf       resb 16         ; mod/search.inc quick-search prefix
qslen       resw 1
%endif
%ifdef FEAT_MENU
menu_n      resw 1          ; mod/menu.inc item count + selection
menu_sel    resw 1
%endif
%ifdef FEAT_MASK
mask_set    resb 1          ; mod/mask.inc: 1=tag, 0=untag
%endif
%ifdef FEAT_DISCOVER
present_tools resw 1        ; mod/discover.inc: bitmap of helper .COMs found
disc_pp     resw 1          ; env-walk position saved across scans
progdir_buf resb 80         ; cc's program directory (trailing '\')
disc_spec   resb 128        ; FindFirst spec being built ("<dir>\CC*.COM")
%endif
%ifdef FEAT_TOOLS_INI
utool_n     resw 1          ; mod/toolsini.inc: cc.ini [tools] entry count
utool_lbl   resw UTOOL_MAX  ; per-entry menu-label pointer (into utbuf)
utool_cmd   resw UTOOL_MAX  ; per-entry program-name pointer (into utbuf)
utool_key   resw UTOOL_MAX  ; per-entry parsed hotkey: lo=class, hi=code (0=none)
ut_pp       resw 1          ; write cursor within utbuf
utbuf       resb UTBUF_SZ   ; ASCIIZ storage for the labels + program names
tools_builtin_n resw 1      ; rows copied from the static mb_tools template
tools_menu_rt   resw (8+UTOOL_MAX+1)*2  ; runtime Tools drop-down (builtin + user)
ukey_n      resw 1          ; dynamically-registered user hotkey count
ukeytab     resb UTOOL_MAX*4 ; rows: db class, db code, dw utool-index (keytab-shaped)
%endif
%ifdef FEAT_INI
; cc.ini is read into the shared 12 KB viewbuf at startup (before any panel read
; or F3 view), so no dedicated scratch is reserved here -- see mod/ini.inc.
ini_n       resw 1
LNGMAX      equ 160
lngbuf      resb LNGMAX     ; mod/lang.inc cc.lng label text (repointed in place)
lng_n       resw 1
lfn_di      resw 1          ; mod/lfn.inc saved CMD_ROW draw position
attr_cur    resb 1          ; mod/attr.inc working attribute bits
openmap     resb OPENMAX*OPENROW ; [open] ext->helper map (ini.inc / vfs.inc)
open_n      resw 1
cur_sect    resb 1          ; ini parser: 0 none, 1 [open], 2 [view]
ext_tmp     resb 4
cur_map_base resw 1         ; ini parser: map being filled this section
cur_map_n   resw 1          ; ini parser: -> count word for that map
ml_base     resw 1          ; map_lookup: map base
ml_cnt      resw 1          ; map_lookup: entry count
%ifdef FEAT_VIEW
viewmap     resb OPENMAX*OPENROW ; [view] ext->viewer map (ini.inc / viewer.inc)
view_n      resw 1
%endif
%endif
%ifdef FEAT_VFS
vfs_pan     resw 1          ; the panel being (re)listed
vfs_helper  resw 1          ; -> helper name within openmap
vfs_end     resw 1          ; end of the listing text in viewbuf
vfs_lpath   resb 96         ; full path of the CCVFS.LST scratch file
vfs_cpath   resb 96         ; full path of the container being browsed
vfs_idx     resw 1          ; member index to extract (F5)
vfs_fidx    resw 1          ; running global file index while filtering a level
vfs_lsize   resd 1          ; size of the listing line being parsed
vfs_rcur    resw 1          ; listing read-cursor preserved across add helpers
vfs_comp    resb 16         ; one path component (file/sub-folder name) scratch
pack_fh     resw 1          ; scratch listfile handle (Alt-F5 pack)
pack_n      resw 1          ; # packable (non-dir) entries written to the list
packtarg    resb 96         ; full path of the archive being created
%endif
srchbuf     resb 80
%ifdef FEAT_VIEWS
brief_col   resw 1          ; mod/views.inc brief renderer scratch
brief_row   resw 1
brief_cw    resw 1
%endif
%ifdef FEAT_TREE
t_count     resw 1          ; mod/tree.inc modal-browser state
t_cur       resw 1
t_top       resw 1
t_depth     resw 1
tree_comp   resw MAX_DEPTH  ; ancestor name ptrs for cursor-path reconstruction
%endif
%ifdef FEAT_MENUBAR
mb_cur      resw 1          ; mod/menubar.inc pull-down state
mb_sel      resw 1
mb_n        resw 1
mb_col      resw 1
mb_items    resw 1
mb_active   resb 1          ; 1 while a menu is dropped down (bar highlights it)
%endif
sort_tmp    resb ENTSIZE
linebuf     resb 84
keybuf      resb KEYBUF_MAX
dta_buf     resb 64
cmdbuf      resb 192
cmdlen      resw 1
cmdtail     resb 132
comspec_buf resb 80
epb         resb 16
save_sp     resw 1
save_ss     resw 1
dlgbuf      resb 44
dlglen      resw 1
dlg_prompt  resw 1
targpath    resb 128
targpath2   resb 128
copybuf     resb 512
fh_src      resw 1
fh_dst      resw 1
; --- tagged-set + recursive copy/delete state ---
iter_i      resw 1
rdepth      resw 1
rsrc        resb 128
rdst        resb 128
dstroot     resb 128       ; top-level copy destination (skipped during the walk)
comefrom    resb 16        ; leaf name we left when going to a parent folder
findpat     resb 132
dta_stack   resb MAX_DEPTH*DTASZ
; --- mouse state ---
mouse_ok    resb 1
mouse_vis   resb 1         ; software cursor-shown flag (idempotent hide/show)
mouse_mode  resb 1         ; MM_BROWSER / MM_OFF / MM_CONFIRM / MM_OWRITE
dlg_focus   resb 1         ; confirm dialog: 0=Yes 1=No
ow_focus    resb 1         ; overwrite dialog: 0=Overwrite 1=Skip 2=All 3=Cancel
ow_mode     resb 1         ; 0=ask each time, 1=overwrite-all, 2=skip-all
ow_cancel   resb 1         ; set when the user cancels the whole operation
m_lb        resb 1
m_rb        resb 1
m_x         resw 1
m_y         resw 1
m_row       resw 1
m_col       resw 1
m_vis       resw 1
m_lasttick  resw 1
m_lastidx   resw 1
m_lastpan   resw 1
vlen        resw 1
vtop        resw 1
vnlines     resw 1
view_hex    resb 1             ; 0 = text pager, 1 = hex dump (toggled by H)
view_edit_req resb 1           ; E in the pager -> launch an editor, then reload
viewbuf     resb VIEW_MAX
lineoff     resw MAX_VLINES
%ifdef FEAT_SNAP
snapbuf     resb 4000
%endif
%ifdef FEAT_RESULTS
rl_end      resw 1             ; bytes read from FINDOUT.TXT into viewbuf
rl_path     resw 1             ; res_heap ptr of the path currently being parsed
rl_panel    resw 1             ; the panel being turned into a results list
rl_namebuf  resb 14            ; basename to land the cursor on after a jump
rl_grep     resb 1             ; 0 = find list (FINDOUT.TXT), 1 = grep list (GREPOUT.TXT)
rl_fname    resw 1             ; ptr to the input filename for results_load
rl_line     resw 1             ; parsed line number of the grep row being built
rl_lastpath resw 1             ; res_heap ptr of the last emitted file (grep dedup)
drv_cur     resb 1             ; drive number (1=A) while building the drives list
view_start_line resw 1         ; 1-based line to open the F3 viewer at (grep jump); 0 = top
res_heap    resb RESHEAP_MAX   ; packed ASCIIZ full paths (+ matched text for grep)
%endif
panelL      resb PANELSIZE
panelR      resb PANELSIZE
stackspace  resb 1024
stacktop:
prog_end:
