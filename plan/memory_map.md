# Breaking the 64 KB wall — memory map & plan

Status: **step 1 (far data segment) done 2026-09-23** — STD resident
63,637 → 50,448 B (headroom 875 B → 14 KB), LFN_FULL 64,456 → 51,267 B
(56 B → 13 KB); total conventional memory used went *down* 48 B.
Steps 2–3 are designs, not yet built.

## Why there is a wall

`cc.com` is a flat `.COM`: code, initialised data, `.bss` and the stack all
live in one 64 KB segment (`CS = DS = ES = SS` at start). DOS itself has far
more memory available — typically 500–600 KB of conventional memory above cc —
but anything in the single segment competes for the same 65,536 bytes.

STD build, 2026-09-23 (before step 1):

| Region | Bytes | Share |
|---|---:|---:|
| PSP + code + initialised data | ~19,000 | 30 % |
| `panelL` + `panelR` (2 × (156 + 512 × 24)) | 24,888 | 39 % |
| `viewbuf` (F3 pager / cc.ini / help / listing scratch) | 8,192 | 13 % |
| `res_heap` (results-panel full paths) | 3,072 | 5 % |
| `lineoff` (pager line table) | 2,048 | 3 % |
| `dta_stack` (recursive copy/delete) | 1,536 | 2 % |
| stack | 1,024 | 2 % |
| everything else (paths, maps, small vars) | ~3,900 | 6 % |
| **resident total** | **63,637** | limit 64,512 |

The wall is ~70 % *data*, not code, so the cheapest fix is to move data out.

## Tools we have

- **More DOS blocks.** `INT 21h/48h` allocates conventional memory outside the
  segment; cc already does this for the 4,000-byte screen back-buffer
  (`bufseg`). DOS frees every block the program owns when it exits.
- **Spare segment registers.** The target is 386+ (`cpu 386`), so `FS` and
  `GS` are free: a far buffer costs one `fs:` prefix byte per access instead
  of a `push ds / mov ds,… / pop ds` dance.
- **Total memory is unchanged.** Whatever moves out of the `.bss` is returned
  by the `AH=4Ah` shrink at startup, so the program segment + far blocks use
  the same conventional memory as before — child programs launched from cc see
  the same free memory.

## Step 1 — far data segment for the big scratch buffers (done)

Move `viewbuf`, `lineoff` and `res_heap` (~13 KB, ~50 references) into one
block (`xseg`) allocated at startup and addressed through `FS`.

- Layout declared once with `[absolute 0]` so code keeps symbolic names.
- `FS` is loaded at startup and **reloaded after every EXEC** (a child may
  clobber it). Interrupt handlers never touch `FS`.
- DOS calls that take `DS:DX` (file reads into `viewbuf`) switch `DS` to
  `xseg` just around the `int 21h`.
- `stos`/`movs` write through `ES:DI` (not overridable) — writes into `xseg`
  via string ops must set `ES` temporarily (ES is usually the video/back
  buffer while drawing).

Expected result: ~13 KB of headroom in both the STD and `FEAT_LFN_FULL`
builds (was 875 B / 56 B).

## Step 2 — panel entry arrays out of the segment (design)

The panels are the biggest single item (25 KB) and the only thing that caps a
directory at `MAX_FILES = 512` entries.

- Keep the 156-byte panel *headers* (`P_PATH`, `P_COUNT`, `P_CUR`, …) in
  `DS`; move only the entry arrays (`P_ENTRIES…`) to a far block — one block
  per panel, or both in one block addressed by a per-panel base.
- `entry_ptr` / `cur_entry_ptr` become the single place that yields a far
  pointer (`GS:SI`); the 175 `[si+E_*]` accesses gain a `gs:` prefix
  (≈ +175 bytes of code, −24.9 KB of `.bss`).
- Hot spots that need real thought, not just prefixes: the sort (swaps
  entries through `sort_tmp`), name copies into DS path buffers
  (`lodsb` → `gs lodsb`), the directory reader filling entries from the DTA,
  and the archive/results loaders that build entries.
- Payoff beyond headroom: `MAX_FILES` can rise to ~2,700 per panel with a
  64 KB block each (`ENTSIZE = 24`), fixing silently truncated big folders.

## Step 3 — code overlays ("load and reload") (design, not needed yet)

Only worth it once code approaches ~40 KB; it is ~19 KB today, so after
steps 1–2 there is more room than the code is likely to need. Design for
when it is:

- **One assembly, many overlays.** NASM can emit several sections that all
  *run* at the same address: `section ovl_tree vstart=OVL_WIN`,
  `section ovl_attr vstart=OVL_WIN`, … Because it is one assembly, calls from
  an overlay into resident code (and back) resolve normally — no linker.
- **Resident overlay window** (`OVL_WIN`, sized to the largest overlay) in the
  program segment, plus a tiny resident loader: `ovl_call <id>, <entry>`
  copies overlay *id* into the window if it is not already there, then calls
  the entry.
- **Where the overlay images live:** the build script cuts the overlay
  sections out of the `.COM` into `CC.OVL`. At startup cc reads the whole file
  into one far block (`INT 21h/48h`), so "swapping" an overlay is a
  `rep movsb` from far memory — no disk access, works from a floppy that has
  since been removed. (Optional later: keep them in XMS/EMS instead.)
- **Good candidates** (self-contained, modal, rarely used together): the tree
  browser, attribute editor, help, the configurator-facing parsers, the zip /
  pack command builders, menu-bar drawing. The main loop, panel rendering,
  file ops and the keytab stay resident.
- Rules: an overlay may call resident code but never another overlay; no
  overlay code may be on the stack when another overlay is loaded (so no
  overlay → EXEC → overlay re-entry); pointers into overlay data must not
  outlive the call.

## What is *not* worth doing

- **Converting to `.EXE` / multiple segments via a linker:** the whole code
  base assumes `CS = DS`, near pointers and `org 100h`; steps 1–2 get the same
  benefit with a fraction of the churn.
- **EMS/XMS for the panels:** paging windows add complexity everywhere an
  entry is touched; plain conventional memory is plentiful for a file manager.
