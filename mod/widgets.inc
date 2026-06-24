; @feature WIDGETS
; @title   status-widget seam marker (CLOCK, FREE, MENUBAR overlay rows)
; @cost    0
;
; mod/widgets.inc  --  FEAT_WIDGETS
; The widget seam is now the CORE descriptor table `wtab` and its three walkers
; (widgets_draw / widgets_tick / widgets_key) in cc.asm. Promoting it to a table
; (W3) made the two panels and the frame/command/fkey chrome ordinary rows too,
; so even a FEAT_MIN build renders through the same walker -- the seam can no
; longer live in an optional module.
;
; FEAT_WIDGETS therefore no longer carries code. It survives as the dependency
; the overlay widgets pull (CLOCK/FREE/MENUBAR each `%define FEAT_WIDGETS`) and
; as the catalog entry that documents the seam; each overlay contributes its own
; WIDGET row in cc.asm's wtab, gated by its own FEAT_. This file is intentionally
; code-free.
