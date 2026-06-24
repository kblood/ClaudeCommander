# Widget & plugin architecture — the unified component model

Status: **W3a + W1 + W2 + W3 SHIPPED (commits e98abf2, e72ce71, dacc9b2,
c4802ce); W4–W5 pending.** Last updated 2026-06-24. Target: `cc.asm` +
`mod/*.inc`. Extends ROADMAP.md (the four-layer hybrid) and the M1 dispatch seam
(`plan/m1_dispatch.md`). This doc records the architecture for making *every*
visible part of cc — clock, file panels, menu bar, and external tools — a
swappable component on a common model, with a minimal default that runs alone.

The user's ask (2026-06-24): "another thing to have as widgets is the file
panels themselves … a minimal default to have a minimal file manager, but
otherwise a system for these external plugins to work with CC, the same way as
the clock, the file panels, the dropdown menu. Would this be possible?"

**Answer: yes — but not as a single mechanism, because DOS physics forbids it.**
There is one hard line, and the whole design is organised around it.

---

## 0. The one hard boundary (read this first)

A flat `.COM` is **one 64 KB segment, no dynamic linking** (ROADMAP §1). DOS has
exactly two ways to "add code":

1. **Compile it in** — `%include` at assemble time. Runs inside cc's frame loop,
   shares the screen and the event loop. *Cannot be discovered or loaded at
   runtime.* The clock, panels, menu bar, footer are all this kind.
2. **EXEC a child program** — a separate `CC*.COM` that takes over the screen,
   runs to completion, and returns (`run_command`/`run_helper`, already built).
   *This is the only runtime-pluggable mechanism DOS offers a `.COM`.*

So "make everything a widget the same way" cannot mean *one* registry, because a
clock is machine code in the image and a plugin is a separate program on disk.
What it **can** mean — and what this plan delivers — is **two parallel seams that
share concepts and meet at data contracts**, so that to the *user* the boundary
is invisible:

- **In-process widget seam** (the clock/panel/menu kind) — a descriptor table:
  each widget registers `{draw, tick, key, region}`. This is the completion of
  the work already started in `mod/widgets.inc` (draw + tick + the new `key`
  hook). §2.
- **Out-of-process plugin seam** (the tool kind) — a folder scan + a `cc.ini`
  registry: each external `CC*.COM` declares which **contract** it speaks
  (action / list-producer / viewer-by-ext / container-by-ext) and which
  menu/key slot it occupies. Present on disk → its feature lights up. §3.

They **meet** at two shared surfaces, which is what makes the two seams feel like
one system (§4):

- **The panel-source contract** — how a producer plugin's *output* becomes
  native panel data (real dir today, container `P_VFS` today, **search/grep
  results next**). This is "panels as widgets," data side.
- **The menu/keytab surface** — a present plugin contributes an in-process menu
  item + keybinding, which is itself an in-process widget. So dropping in a
  `.COM` makes a real cc menu entry appear.

Locked decision (extends ROADMAP's "Hybrid, no runtime overlay yet"): **no
Layer-4 overlay loader.** Runtime pluggability = EXEC + data contracts, not code
injection. The widget seam stays compile-time; the plugin seam stays
out-of-process. This is the maximum integration DOS allows without an overlay,
and it is enough for everything the user described.

**Decision (2026-06-24): the modularity vehicle is a compile-time CONFIGURATOR,
not a runtime/launch-time code loader.** We considered a DOS-overlay ("DLL for
DOS", INT 21h 4B03h) system to load widget code at launch and break the 64 KB
wall; it was **rejected as the primary path** because it fights the project's
core "smallest possible, single self-contained `.COM`" identity (adds a loader,
a far-call host ABI, multiple `.OVL` artifacts, no memory protection). Instead we
productize the *existing* `%ifdef FEAT_*` system into a feature picker that emits
a custom, still-tiny single `.COM` (§7). Overlays remain documented only as the
deferred escape hatch for the one case the configurator cannot serve — needing
**>64 KB of features resident simultaneously** (§7.4). The widget/keybind seam
and the data contracts below are the framework in *both* worlds, so none of that
work is overlay-specific or wasted.

---

## 1. What already exists (so we extend, not rebuild)

| Capability | Today | Becomes |
|---|---|---|
| In-process draw seam | `widgets_draw` fans out to footer/clock/menubar | one entry in the widget descriptor table (§2) |
| In-process idle seam | `widgets_tick` (clock) | the `tick` column of the table |
| In-process input seam | `widgets_key` → `mb_key` (just added, commit 452fd26) | the `key` column of the table |
| Panel "source" flag | `P_VFS` byte: 0 = real dir, 1 = container | widen to `P_SRC` enum: dir / container / **results** (§4) |
| Container browse | `vfs_relist`: helper `L`-mode → `CCVFS.LST` → panel entries | the template for *every* producer plugin |
| Extension → tool maps | `cc.ini [view]` (viewers) + `[open]` (containers) | two of the four plugin contract kinds (§3) |
| External EXEC | `run_command` (visible) / `run_helper` (silent + redirect) | the transport for all plugin contracts |
| Key registration | `KEYBIND_*` rows + `keytab` walk (`plan/m1_dispatch.md`) | how a present plugin gets a hotkey (§4) |

The two seams are **already half-built**. This plan finishes them and connects
them. Nothing here is greenfield; the riskiest mechanisms (silent EXEC + listing
parse + virtual panel) are proven by the VFS.

---

## 2. In-process widget seam — the descriptor table

Today `widgets.inc` hard-codes three `%ifdef`/`call` blocks per hook (draw, tick,
key). That is fine for 4 widgets; it does not generalise to "panels are widgets
too" because a panel needs all three hooks *plus a screen region*. Promote the
seam to a **descriptor table**, one row per in-process widget:

```
; widget descriptor (8 bytes):
;   dw draw_fn     ; paint this widget (es=VIDEO). 0 = none.
;   dw tick_fn     ; idle refresh (clock). 0 = none.
;   dw key_fn      ; offered each key BEFORE keytab; CF=1 = claimed. 0 = none.
;   db region      ; WR_* screen-region id (for layout/repaint). 
;   db flags       ; reserved (e.g. WF_MODAL)
```

The three fan-outs (`widgets_draw`/`widgets_tick`/`widgets_key`) become **one
walker each** over the same table, calling the non-zero column. Adding a widget
= one descriptor row + its functions, gated by its `FEAT_`; **no edit to the
walkers**. This is the exact analogue of what `KEYBIND`/`keytab` did for keys.

Registration mirrors the keytab's "host-anchored, module-contributed" pattern
(`plan/m1_dispatch.md` §5): `wtab:` start label in the host, module rows spliced
by `%include` between it and a `WTAB_END` sentinel.

### Widgets that move onto the table

| Widget | draw | tick | key | region | FEAT |
|---|---|---|---|---|---|
| Free-space/tag footer | `draw_foot` | — | — | `WR_FOOT` | FEAT_FREE |
| Clock | `draw_clock` | `clock_tick` | — | `WR_CMD` | FEAT_CLOCK |
| Menu bar | `mb_bar_draw` | — | `mb_key` | `WR_TOP` | FEAT_MENUBAR |
| **Left panel** | `panel_draw` L | — | — | `WR_PANL` | core |
| **Right panel** | `panel_draw` R | — | — | `WR_PANR` | core |

The panels become **two ordinary widget rows** that happen to be in the minimal
core (always present), drawing into the left/right regions. Their content comes
from the panel-source contract (§4), not from the widget row — the row only says
"paint a panel here." This is exactly the split the user wants: **layout is a
compile-time widget; content is a runtime-pluggable source.**

### "Minimal default file manager"

The `FEAT_MIN` build's widget table is just the two panel rows. No clock, no
footer, no menu bar, no results source — a bare two-pane browser with
navigation + core file ops + the built-in text pager. Everything else is a row
you add by compiling its module in. That is the minimal default the user asked
for, expressed as "the smallest widget table."

### Cost / risk

- Table walk is a few bytes more code than the current 3 `%ifdef` blocks, but
  removes per-hook growth — net neutral by ~3 widgets, a win past that. Counts
  against the ~4.7 KB resident wall (ROADMAP §1); the table itself is 8 B/widget.
- `region` is initially advisory (used for nothing but documentation + future
  partial-repaint). Do **not** gate this milestone on a repaint optimiser.
- Modal widgets (the menu bar's drop-down) keep owning their own key loop via
  `key_fn` returning CF=1 then running to completion — unchanged from `mb_key`.

---

## 3. Out-of-process plugin seam — discovery + contracts

A plugin is an external `CC*.COM`. Two questions: **is it here?** (discovery) and
**how does cc talk to it?** (contract).

### 3.1 Discovery — folder scan at startup

At startup, after `cc.ini` is read, `FindFirst CC*.COM` in cc's own program
directory (the path in PSP/`argv0`) and build a small **present-tools bitmap**.
Menu items and keybindings for a tool are gated on its bit:

- present → the item shows / the key fires.
- absent → the row is silently skipped (no "Bad command" surprise).

This is the "give you the features it found" behaviour. It is read-only and
cheap (one `FindFirst/FindNext` loop into a bitmap), and it does not change the
EXEC path that already works.

### 3.2 The four contracts

Each plugin speaks exactly one contract. The contract is what makes its I/O
"work with cc" instead of being an opaque takeover:

| Contract | Transport | Output → cc | Examples |
|---|---|---|---|
| **Action** | `run_command` (visible) | none (owns screen, returns) | CCEDIT, CCIMG, CCWAV, CCHEXED |
| **Viewer-by-ext** | `run_view_helper` | none (owns screen) | `[view]` map: CCIMG, CCWAV |
| **Container-by-ext** | `run_helper` `L`-mode + redirect | **panel source = container** | `[open]` map: CCZIP, CCD64… |
| **Producer (list)** | `run_helper` `L`-mode + redirect | **panel source = results** | **CCFIND, CCGREP (next)** |

The first two exist. The third exists (VFS). **The fourth is the new work** and
is the user's "search-results panel." It reuses the container transport almost
verbatim — the only difference is the *source type* the listing loads into (§4).

### 3.3 The registry (the closest thing to a plugin manifest)

A `cc.ini [tools]` section lets a *present* tool declare its menu slot, hotkey,
and contract — so a brand-new helper appears in cc's UI by existing + one line,
with no rebuild:

```ini
[tools]
; label              ; program      ; key    ; contract  ; menu
Find files         = CCFIND.COM     Alt-F7   producer    Commands
Grep contents      = CCGREP.COM     Alt-F8   producer    Commands
Checksum           = CCSUM.COM      -        action      Tools
My converter       = CONV.COM       -        action      Tools
```

`[view]` and `[open]` already are per-extension registries for two of the
contracts; `[tools]` generalises the idea to menu/key-driven tools. The in-process
menu (a widget, §2) reads this table to build its rows — that is the **meeting
point** of the two seams (§4).

---

## 4. Where the seams meet — panel sources + the menu surface

This is the heart of "make it feel like one system."

### 4.1 Panel source = the data contract (panels as widgets, content side)

Generalise the `P_VFS` boolean into a **source enum** on the panel struct:

```
P_SRC   equ 74      ; (reuses the P_VFS byte slot)
  SRC_DIR     = 0   ; real DOS directory (read_dir)         -- core
  SRC_VFS     = 1   ; container listing  (vfs_relist)       -- FEAT_VFS (today)
  SRC_RESULT  = 2   ; result list        (results_load)     -- FEAT_RESULTS (new)
```

`read_dir` / `render_panel` / `go_parent` already branch on `P_VFS`; they switch
to a 3-way branch on `P_SRC`. A `SRC_RESULT` panel:

- is populated by `results_load`, which parses a listing file (`CCFIND.LST`,
  same `<size> <name>` line shape the VFS parser already reads — for find the
  "name" is a **full path**) into the entry array, with a synthetic `..` that
  restores the previous real directory on Backspace.
- on **Enter**: jump the panel to that file's folder with the cursor on it (or,
  for grep hits, open the F3 viewer at the recorded line — store the line in the
  `E_TIME`/`E_DATE` slots, which are meaningless for a results row).
- repaints through the **same panel widget** (§2) — a results panel is not a new
  renderer, just a different source feeding the existing one.

So a producer plugin's output becomes a first-class, navigable cc panel. The
tool stays external; its *results* are native. This is the integration the user
wanted for find/grep, and it is the same mechanism that already integrates
containers — only the `P_SRC` value differs.

### 4.2 The menu surface = the control contract

The in-process menu (a widget, §2) and the keytab (`plan/m1_dispatch.md`) build
their rows partly from the `[tools]` registry (§3.3), gated by the present-tools
bitmap (§3.1). So:

```
drop CCFIND.COM in the folder
   → discovery bitmap sets its bit
   → menu widget emits a "Find files" row (because [tools] lists it + it's present)
   → Alt-F7 keybinding becomes live
   → invoking it runs the producer contract (silent EXEC + redirect)
   → results_load turns CCFIND.LST into a SRC_RESULT panel
```

Every arrow is an existing mechanism except `results_load` + `SRC_RESULT`. That
single new piece is what turns "external tool" into "a tool whose I/O works with
cc," and it generalises to any future producer.

---

## 5. Milestone sequence (slots into ROADMAP M2/M5)

Ordered so each step ships a visible win and de-risks the next. Each is its own
GREEN-then-commit unit per the project's autonomy rule.

**W1 — Producer contract + search-results panel (the visible win). ✅ SHIPPED
(commit e72ce71, 2026-06-24).** `mod/results.inc` (`FEAT_RESULTS`, opt-in):
`results_show`/`results_load`/`results_enter`. `P_SRC` enum (SRC_DIR/VFS/RESULT)
aliased over `P_VFS`; full paths in `res_heap`, entries carry basename +
`E_RES_OFF` (over `E_TIME`). Alt-F7 runs `CCFIND` via `run_helper` → `FINDOUT.TXT`
→ inactive panel; Enter jumps to the file's folder with the cursor on it.
`read_dir` no-ops on `SRC_RESULT` (refresh-clobber fix); F3 views the real path;
copy disabled from a results panel. `/T` harness `run_results.ps1` GREEN.

**W2 — Grep hits as results. ✅ SHIPPED (commit dacc9b2, 2026-06-24).** Both
design forks resolved by the user as "Full". `CCGREP` now emits the new contract
`path:lineno:text` (a LF counter + `emit_dec_di` in `cgrep.asm`). Under
`FEAT_RESULTS`, Alt-F8 redirects to `GREPOUT.TXT` and loads it as a `SRC_RESULT`
panel; grep rows show the **matched line text** in the name field and the **line
number** in the size field (`format_entry_grep`, gated in core `format_entry` by
`P_SRC==SRC_RESULT && E_RES_TEXT!=0`). `E_RES_TEXT` (= `E_SIZE` low word) holds a
near offset to the matched text in `res_heap` and is the find-vs-grep row
discriminator; `E_RES_LINE` (= `E_DATE`) holds the line number. Enter on a grep
row opens the F3 built-in pager scrolled to the line (`results_view_at_line` +
`view_start_line`); find rows keep their folder-jump (`E_RES_LINE=0`). The pager
is core, so no `FEAT_VIEW` dependency. A malformed grep line degrades to a
find-style row. `measure.ps1` gained `-i "$Dir/"` so the configurator's trial
assemble is cwd-independent. GREEN: `-Only GREP,RESULTS,VIEW` fits (63,496 B);
`run_grepresults.ps1` witnesses text+line# in the panel and the viewer landing on
the line; `run_results.ps1` + the configurator self-test still pass.

**W3 — Widget descriptor table. ✅ SHIPPED (commit c4802ce, 2026-06-24).**
`widgets_draw/tick/key` are now one walker each over a single 8-byte-per-row
`wtab` (draw_fn, tick_fn, key_fn, region, flags), listed in draw order so the
table *is* the render sequence; `render_all` = `clear_bg` + `widgets_draw`. The
two panels are ordinary rows (`draw_panelL/draw_panelR`), and — to reproduce the
exact old order with a single walker (frames must paint *after* the panels) —
the frame/command/fkey chrome are core rows too. That makes the seam core: even
a `FEAT_MIN` build renders through `wtab`, so the `FEAT_MIN` table is the panel
rows + chrome (not literally "2 rows", but the same observable bare browser).
`FEAT_WIDGETS` keeps only its dependency/catalog role; `mod/widgets.inc` is a
code-free stub. Acceptance met: `run_w3_diff.ps1` proves the post-W3 `/T` dump
is byte-identical to pre-W3 across 8 frames (panels/frames/cmd/fkey/footer/menu-
bar dropdown); self-test + W1/W2 harnesses still pass.

**W4 — Tool discovery + present-tools gating.** Startup `FindFirst CC*.COM`
bitmap; gate existing menu items / keybinds on presence. No new UI, just "absent
tool ⇒ hidden, not broken."

**W5 — `[tools]` registry.** Menu widget + keytab read `cc.ini [tools]` (§3.3),
so arbitrary dropped-in helpers become menu entries. The full "drop a `.COM`, get
a feature" loop.

W1–W2 deliver the user's "search results panel" and the find/grep integration.
W3 delivers "panels are widgets" and the minimal default. W4–W5 deliver "the
system discovers and registers plugins." Together they are the unified component
model, within DOS's limits.

---

## 6. Risks / decisions to respect

1. **The hard boundary (§0) is non-negotiable.** Do not promise a runtime that
   loads the clock/panel/menu kind of widget from disk — they are image code. If
   that is ever truly needed it is a Layer-4 overlay (ROADMAP §3 rule 4), out of
   scope here and explicitly deferred.
2. **Resident wall — there is NO headroom in the default build.** ROADMAP §0
   (authoritative, 2026-06-23) records `FEAT_STD` at **64,504 B, ~8 B free** —
   the ~4.7 KB figure in ROADMAP §1 is stale planning math, superseded. So the
   widget table (W3) and `results_load` (W1) **cannot** be added to the default
   image as-is; each requires an explicit reclaim (shrink `viewbuf`/`MAX_FILES`
   under a flag) OR lives only in a tier the user opts into. This is not a
   footnote — it is *the* reason the configurator exists (§7): you cannot "add
   everything," you must choose a subset that fits. `build.ps1` enforces the
   wall. See §8.1.
3. **`P_SRC` reuses the `P_VFS` byte** (value 0/1 stay identical), so existing
   `cmp byte [bx+P_VFS],0` sites keep working as "is this a real dir"; only the
   handful that need the 3-way distinction read `P_SRC`. Audit every `P_VFS`
   read when widening (grep shows ~10 sites).
4. **Results listings can exceed `MAX_FILES` (512).** A find across a big tree
   may return more hits than a panel holds. Decision: **cap at MAX_FILES and
   show a "(truncated, N more)" footer row** rather than silently dropping —
   silent truncation reads as "that's all of them." (Matches the project's
   "no silent caps" instinct.)
5. **Discovery path = cc's *own* directory**, not the cwd. Derive it from the
   PSP environment / `argv0`, not from `[active]` panel path (the user may be
   browsing elsewhere). The helpers live with `cc.com`.
6. **Behavioural-identity bar for W3.** Like the M1 dispatch port, the widget
   table changes emitted bytes; acceptance is "`/T` dumps unchanged," not
   "byte-identical `.com`."
7. **Grep line in `E_TIME/E_DATE`** is a deliberate slot reuse for `SRC_RESULT`
   rows only; document it loudly so a future date-column change doesn't assume
   those fields are real dates on a results panel.

---

## 7. The configurator — the chosen modularity vehicle (decision 2026-06-24)

The framework the user is reaching for ("a system plugins plug into") is, for
cc, **the compile-time feature seam + a configurator that composes it** — not a
runtime loader. cc is already ~80% of the way there: `%ifdef FEAT_*` modules,
the `FEAT_MIN/STD/FULL` tiers, the `CCPOP` variant, and `configure.ps1` emitting
`-dFEAT_X`. This section productizes that into "the compiler installation."

### 7.1 What a "plugin" is in this model

A plugin = **a `mod/<name>.inc` that conforms to two seams it already has:**

1. the **widget ABI** (`{draw, tick, key, region}` descriptor row, §2), and/or
2. the **keytab ABI** (`KEYBIND_*` rows, `plan/m1_dispatch.md`),

plus a small **manifest header** (§7.2) so the configurator can discover and
cost it. Writing a plugin is writing one `.inc` against published seams; *adding*
it to a build is ticking a box in the configurator. No core edits — that is the
whole point of the seams. (External `CC*.COM` tools, §3, are the *other* kind of
plugin and compose via the `cc.ini [tools]` registry, also no rebuild needed.)

### 7.2 The feature manifest header

Each `mod/*.inc` gains a machine-readable header comment so the picker is
data-driven, not a hard-coded list:

```
; @feature   FEAT_CLOCK
; @title     Clock (top-right HH:MM:SS)
; @cost      ~300            ; resident bytes, for the budget meter
; @needs     FEAT_WIDGETS    ; dependency FEAT flags (the %define chains today)
; @summary   Ticks once a second on the command row.
```

These mirror the implicit dependency chains that already exist in `cc.asm`
(`FEAT_TOOLS`→`FEAT_MENUBAR`→`FEAT_WIDGETS`). Making them explicit lets the
configurator validate selections and show running cost.

### 7.3 The configurator itself

Evolve `configure.ps1` into an interactive picker (and keep a non-interactive
flag mode for scripts/CI):

1. Scan `mod/*.inc`, parse the `@feature` manifests → the feature catalogue.
2. Present toggles grouped by area, each showing its `@cost`; maintain a
   **running resident total against the budget** (the same math `build.ps1`
   uses — the 64 KB segment wall; the default `FEAT_STD` is already at it,
   64,504 B / ~8 B free per ROADMAP §0). The `@cost` numbers are a *preview*
   estimate only; the authoritative size is the **actual trial assemble** the
   configurator runs per selection (§8.5) — never trust the annotation.
3. Enforce `@needs` dependencies and the mutual exclusions (e.g. menubar vs
   pop-up) so an invalid set can't be chosen.
4. Refuse / warn when the selection exceeds budget — the configurator is where
   the 64 KB ceiling is explained to the user, not a cryptic linker error.
5. Call NASM with the resolved `-dFEAT_*` set; emit a named custom `CC.COM` and
   a one-line report of what's in and the final size.

"Compiler installation" = ship this picker **plus a bundled NASM**. NASM has a
DOS build, so the configurator can optionally target rebuilding on the
ao486/real hardware itself — fully in-spirit with a DOS file manager that can
recompile itself. Default to the Windows NASM for the cross-build-then-copy flow.

### 7.4 Considered and deferred: the overlay ("DLL") loader

Recorded so the trade-off isn't relitigated. A DOS-overlay system (INT 21h
4B03h: load a flat `org 0` blob into its own segment, patch a **host-services
vector table** into it, far-call its registered widgets) is genuinely possible
and would (a) break the 64 KB wall and (b) allow adding *in-loop widget code* at
launch by dropping a `CC*.OVL` file. It is **deferred, not adopted**, because it
costs the single-file smallness the project is built around (resident loader +
far-call ABI + per-overlay artifacts + no memory protection + an append-only
host ABI). **The only thing it uniquely enables is >64 KB of features resident
at once** — a need cc does not currently have, since any sensible subset fits in
one segment and the configurator lets the user choose that subset. If that need
ever materialises (a true kitchen-sink build), the overlay loader is the
escape hatch, and the widget descriptor table (§2) is already the right shape to
extend with a far-pointer bit. Until then: don't build it.

### 7.5 Milestone — slots before/with W3

**W3a — Configurator + manifests. ✅ SHIPPED (commit e98abf2, 2026-06-24).**
`@feature` manifests (`@title`/`@needs`/`@cost`/`@optin`) on all 23 selectable
modules + `@core` on the 6 always-in ones; `configure.ps1` scans them into the
catalogue (no hard-coded list), validates the dependency closure, and shows an
`@cost` size preview backed by an authoritative trial assemble (shared
`tools/measure.ps1`). `run_configurator.ps1` reproduces MIN/STD/FULL/CCPOP
**byte-for-byte** vs the canonical builds and `/T`-smokes each. Fixed a latent
gap: `FEAT_VIEW` needs `FEAT_VFS` (uses `vfs_cat`). `CONFIGURE.md` documents it,
incl. the "ship sources + DOS NASM = on-target configurator" packaging note.

---

## 8. Review refinements (codex + gemini, 2026-06-24)

Two independent outside reviews (OpenAI Codex, Google Gemini) read §§0–8. Both
validated the configurator-over-overlay decision and the compile-time/EXEC
boundary. These are the concrete amendments their critique forces; where they
agreed it is noted, since agreement = high confidence.

### 8.1 Budget reality — the riskiest assumption, corrected (codex)
The default build has ~8 B free, not ~4.7 KB (§6.2). Consequence baked into the
milestones: **W1 and W3 do not target `FEAT_STD` as-is.** Each new resident
piece (`results_load`, `SRC_RESULT` branching, the `wtab` walker, discovery,
registry plumbing) must declare its reclaim: either it lives behind a `FEAT_`
the user opts into *and* trades a buffer (`viewbuf` 16 KB / `MAX_FILES` 24.7 KB)
under that flag, or it does not ship resident. The configurator is what makes
this a *choice* rather than a wall. No milestone is "done" until `build.ps1`
shows it fits the tier it claims.

### 8.2 Results data model — do NOT store full paths in entries (codex)
`E_NAME` is 14 B (8.3); a find result is a full path (≤ ~80 B). So
`results_load` is **not** a straight `vfs_load` clone. Design:
- a **results path heap** (a flat buffer of NUL-terminated full paths, appended
  as the `.LST` is parsed) carved under `FEAT_RESULTS` (counts against §8.1);
- each panel entry stores a **display string** (basename, or a right-truncated
  path) in `E_NAME` plus a **word offset into the path heap** (reuse a spare
  entry slot, symbolically named — §8.4) for the real path used on Enter;
- if the heap fills before `MAX_FILES`, that is the truncation trigger (§8.3),
  whichever comes first.

### 8.3 Truncation is metadata, not a fake file (codex + gemini, agreed)
When a result set exceeds `MAX_FILES` or the path heap, show a **non-selectable
trailing status row** ("… N more, refine the search") rendered by the panel but
flagged so Enter/sort/tag skip it. Never a silent cap; never a row that Enter
can act on as if it were a file.

### 8.4 Source-aware operations, not scattered 3-way tests (codex + gemini)
`P_SRC` widening is brittle if every op sprouts a `cmp P_SRC` ladder. Introduce a
tiny **source-operation dispatch**: a per-source descriptor of `{enter, parent,
can_sort, can_tag, relist}` so `SRC_RESULT` cleanly **disables file-centric ops**
(sort by size/date, column cycle, tag-by-mask) that are meaningless for results,
and `SRC_DIR`/`SRC_VFS` keep today's behaviour. The grep-line slot reuse gets
**symbolic aliases** `E_RES_LINE_LO/HI` (= the `E_TIME/E_DATE` offsets) used
*only* on `SRC_RESULT`, so a future date/column change can grep the alias and
see the hazard. Both reviewers flagged the raw slot reuse as the top fragility.

### 8.5 Configurator must be thin and self-testing (gemini's riskiest point)
Gemini's single riskiest assumption: the configurator becomes an opaque, fragile
meta-build whose failure breaks everything. Mitigations, mandatory:
- it is a **thin wrapper** over the `-dFEAT_*` flags that already work
  (`configure.ps1` today), not a reimplementation of the build;
- its **acceptance self-test** is "reproduce MIN/STD/FULL/CCPOP byte-for-byte"
  (or behaviourally + `/T` green) from the manifest-driven selection — a
  regression guard that lives in the repo and runs in CI alongside the harnesses;
- size is decided by an **actual trial assemble**, not `@cost` annotations
  (§7.3); `@cost` is a UI preview only.

### 8.6 Panel-as-widget needs a context (codex)
A single `panel_draw` pointer can't serve both panels. Decision: the widget
descriptor gains an **optional context word** (the panel pointer for panel rows;
0/ignored for stateless widgets like the clock), passed in a register to
`draw/tick/key`. Chosen over two `panel_draw_L/R` thunks because it generalises
(any future multi-instance widget reuses it) at the cost of one word per row.
The descriptor stays **near pointers only** — far-pointer columns are deferred
with overlays (§7.4), both reviewers explicitly warned against adding them now.

### 8.7 [tools] registry — prefer build-time table generation (codex)
Parsing hotkeys/contracts/menu-names from `cc.ini [tools]` in *resident* code
costs bytes the default build (§8.1) does not have. Given the configurator
exists, lean toward **generating the menu/key tables at build time** from the
manifest + `[tools]`, and keep the *runtime* step to the cheap folder-scan that
only flips present/absent bits (§3.1). Full runtime `[tools]` parsing becomes an
opt-in `FEAT_TOOLS_INI` for users who want drop-in-without-rebuild and can spare
the bytes. (Gemini considered runtime `[tools]` clean; the budget, not
cleanliness, is why we bias to build-time.)

### 8.8 Descriptor extensibility (gemini, minor)
Adding a new global hook later shouldn't break every widget. The descriptor's
hook columns are already **all-optional (0 = none)**, so a new column is
additive; reserve the `flags` byte for this. Not a blocker; just don't pack the
struct so tight that growth forces a rewrite.

---

## 9. One-paragraph answer for the user

Yes, it's possible — and cc is already most of the way there. The clock, panels,
and menu bar are *in-process* widgets: machine code compiled into `cc.com`, which
DOS cannot load from disk at runtime, so they stay a compile-time set — but we
unify them under one descriptor table so panels become just two more widget rows
and the minimal build is "the smallest table." External tools are the *other*
kind of component: separate `CC*.COM` programs that DOS *can* discover at runtime,
which integrate not by being linked in but by speaking a data contract — and the
container browser already proves a tool can be external yet fully integrated (its
listing becomes a real cc panel). We extend that same contract so find/grep
results land in a "search-results panel," scan the folder to light up whatever
tools are present, and let a `cc.ini [tools]` line turn any dropped-in helper
into a menu entry. The two kinds can't be *one* mechanism (image code vs separate
program is a DOS fact), but they share one model — register a draw/key seam for
the resident kind, a contract + discovery for the external kind — and they meet
at the panel-source and menu surfaces, so to the user it's one component system.
