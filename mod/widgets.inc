; mod/widgets.inc  --  FEAT_WIDGETS
; The status-widget seam. render_all calls widgets_draw once per frame; the idle
; poll loop in get_key calls widgets_tick. Each fans out to whatever status
; widgets are compiled in (the clock, the panel footer, ...). This is the single
; place that knows the set of widgets, so adding one is its own FEAT_ module plus
; one line here -- the core render/input code never changes.
;
; Geometry/placement stays WITH each widget (e.g. the clock owns its row/col),
; so a widget can later be repositioned from cc.ini without touching this seam.
; Drawn last (after the command row + fkey row) so a widget that paints on the
; command row -- the clock -- overwrites it rather than being overwritten.

widgets_draw:
%ifdef FEAT_FREE
        call    draw_foot
%endif
%ifdef FEAT_CLOCK
        call    draw_clock
%endif
        ret

; Idle refresh: called repeatedly while waiting for a key, so widgets that track
; wall-clock time (the clock) can update without a keystroke. Widgets that only
; change on user action contribute nothing here.
widgets_tick:
%ifdef FEAT_CLOCK
        call    clock_tick
%endif
        ret
