# cc — feature goal loop

The standing mandate: implement every goal below, autonomously, committing each
as it tests GREEN. This file is the backlog **and** the loop protocol; any fresh
session (or a scheduled wake-up) continues from here.

## Loop protocol (do this every iteration)

1. Read this file + `HANDOFF.md`. Pick the **first unchecked goal** (top-down)
   unless a dependency note says otherwise.
2. Implement it end-to-end: code → `build.ps1` GREEN (under the 64 KB wall) →
   exercise it in DOSBox via the `/T` harness or a filesystem check.
3. Commit **only** when GREEN (`cc: <goal-id> <summary>`); never push.
4. Check the box here, add a one-line result note, bump "Last updated".
5. Continue to the next goal. Only stop to ask the user if a decision is
   genuinely ambiguous or irreversible.

Last updated: 2026-06-23 — framework + ZIP browse done; starting G1 (extract).

## Architecture recap (so each goal stays cheap)

- **Resident core stays small.** Format-specific work lives in external `.COM`
  helpers (Layer-3, zero resident cost) selected by a cc.ini map. Adding a
  format = a new helper + one cc.ini line.
- **`[open]` map** (done): Enter on a matching extension browses it as a folder;
  F5 will extract a member. **`[view]` map** (G6): F3 runs a per-type viewer.
- Resident headroom ~2.6 KB (snapbuf gated behind FEAT_SNAP).

## Goals

### Packer plugins
- [ ] **G1 — ZIP extract (F5 from a zip panel).** When the active panel is a
      container, F5 runs `CCZIP X <zip> <member-index> <destdir>` (→ other
      panel) instead of copy_one. CCZIP gains `X`: STORED = copy bytes at the
      local-header data offset; DEFLATED = a small INFLATE. Index matches `L`
      (dirs skipped). *This finishes the explicit "copy files out of a zip" ask.*
- [ ] **G2 — ZIP pack (Alt-F5).** NC-style: add the cursor/tagged files to a
      `.zip` (prompt for the archive name; STORED method = a valid zip, no
      compressor needed). CCZIP gains `A` (add). Also wire **Alt-F9** =
      extract-all the archive under the cursor to the other panel.
- [ ] **G3 — CCD64 (C64 1541 disk image).** `[open]` `d64=CCD64`. Browse the
      track-18 directory; extract a file as `.PRG`. No decompression.
- [ ] **G4 — CCT64 (C64 tape archive).** `[open]` `t64=CCT64`. Browse the T64
      directory; extract entries as `.PRG`. No decompression.
- [ ] **G5 — CCARJ (ARJ archive).** `[open]` `arj=CCARJ`. Browse + extract
      (STORED first; ARJ method-0). Decompress best-effort.
- [ ] **G6 — CCRAR (RAR archive).** `[open]` `rar=CCRAR`. Browse the headers;
      extract STORED entries (RAR compression is proprietary — browse-first).

### Lister plugins
- [ ] **G7 — `[view]` framework + F3 dispatch.** Parse a cc.ini `[view]`
      section (ext→viewer). On F3, if the cursor file's ext is mapped, run that
      viewer instead of the built-in text viewer.
- [ ] **G8 — CCIMG image viewer.** Render GIF/PCX/BMP in a VGA graphics mode,
      any-key to return. `[view]` `gif=CCIMG pcx=CCIMG bmp=CCIMG`.
- [ ] **G9 — audio/music players.** CCWAV (PCM via Sound Blaster) and/or CCMOD
      (tracker). `[view]` `wav=CCWAV mod=CCMOD`. Hardware-dependent; test on rig.

### External tools (free, no resident cost)
- [ ] **G10 — CCDIFF / CCREN / CCSPLIT / CCJOIN.** File compare, multi-rename,
      split/join. Same Layer-3 pattern as CCHEX/CCSUM.

## Done

- [x] Container framework + ZIP browse (commit 9594ef8) — Enter on a `.zip`
      browses it as a folder; Backspace exits; title shows the archive name.
- [x] F5/F6 copy & move with rename-in-destination (commit 6510e14).
