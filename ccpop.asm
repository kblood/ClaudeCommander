; ccpop.asm -- CCPOP.COM build wrapper: the classic single pop-up command menu
; instead of the always-on pull-down bar (= the STD feature set minus
; FEAT_MENUBAR and the menu-bar-only Tools/Results panes).
;
; This exists so DOS-side builds (INSTALL.BAT) need only a short command line
; -- COMMAND.COM caps a line at 127 chars and has no ^ continuation:
;
;     NASM -f bin CCPOP.ASM -o CCPOP.COM                  (pop-up menu)
;     NASM -f bin CCPOP.ASM -dFEAT_LFN_FULL -o CC-LFN.COM (+ full LFN)
;
; The flag list MUST stay identical to $popDefs in package.ps1; package.ps1
; assembles this wrapper as well and fails if the two binaries differ.

%define FEAT_CUSTOM
%define FEAT_WIDGETS
%define FEAT_CLOCK
%define FEAT_FREE
%define FEAT_VIEWS
%define FEAT_TREE
%define FEAT_SORT
%define FEAT_COLS
%define FEAT_SEARCH
%define FEAT_MASK
%define FEAT_MENU
%define FEAT_HELP
%define FEAT_EDIT
%define FEAT_FIND
%define FEAT_GREP
%define FEAT_ZIP
%define FEAT_ATTR
%define FEAT_VFS
%define FEAT_VIEW
%define FEAT_INI
%define FEAT_LANG
%define FEAT_LFN

%include "cc.asm"
