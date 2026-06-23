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

Last updated: 2026-06-23 — G1/G2/G3 GREEN (ZIP extract/pack/all, D64 browse+extract); starting G4 (CCT64).

## Architecture recap (so each goal stays cheap)

- **Resident core stays small.** Format-specific work lives in external `.COM`
  helpers (Layer-3, zero resident cost) selected by a cc.ini map. Adding a
  format = a new helper + one cc.ini line.
- **`[open]` map** (done): Enter on a matching extension browses it as a folder;
  F5 will extract a member. **`[view]` map** (G6): F3 runs a per-type viewer.
- Resident headroom ~2.6 KB (snapbuf gated behind FEAT_SNAP).

## Goals

### Packer plugins
- [x] **G1 — ZIP extract (F5 from a zip panel).** DONE. CCZIP gained an `X`
      mode: walks the central dir to the Nth FILE member, resolves the local
      header data offset, writes `<destdir>\<basename>` — STORED = byte copy,
      DEFLATE = a full streaming RFC-1951 INFLATE (fixed + dynamic Huffman,
      32 KB circular window reusing cdbuf). cc's F5 in a P_VFS panel calls
      `vfs_extract` → `<helper> X <container> <cursor-1> <other-path>` via
      run_helper, then refresh_panels. Verified: standalone DOSBox extract of a
      stored + a deflated member byte-exact (SHA1); cc /T harness F5 extracted
      HELLO.TXT into the other panel. resident 62,105 B.
- [x] **G2 — ZIP pack (Alt-F5) + extract-all (Alt-F9).** DONE. CCZIP gained
      `A <zip> @<list>` (create a fresh STORED zip with real CRC-32s, local
      headers, central dir + EOCD) and `XA <zip> <dest>` (extract every
      member). cc: Alt-F5 prompts a name, writes the tagged/cursor full paths
      to a scratch CCPACK.LST, runs `<helper> A <other\name> @<list>`;
      Alt-F9 runs `<helper> XA <cursor-zip> <other-path>`. Both pick the
      helper from the target extension via the [open] map. Fixed a real
      DOS .COM bug: stale .bss mode flags survived between EXECs (X then XA
      mis-dispatched) — all flags now zeroed at startup. Verified: cc Alt-F5
      makes a .NET-valid zip (byte-exact round-trip); cc Alt-F9 extracts a
      stored + a deflated member. resident 62,756 B.
- [x] **G3 — CCD64 (C64 1541 disk image).** DONE. New helper `cd64.asm` →
      `ccd64.com` (1,027 B) implements `L` (machine listing), `X <img> <n>
      <dir>` (extract the Nth file) and `XA <img> <dir>` (extract all),
      following the 1541 format: 35-track / 683-sector geometry, track-18
      directory chain, per-file sector chains (254 data bytes per non-final
      sector; final sector's byte 1 = last valid index). Names are sanitised
      to `<NAME>.PRG`, load address preserved. `cc.ini` `[open]` gains
      `d64 = CCD64` — no cc.asm change, the VFS framework drives browse/F5/
      Alt-F9 generically. Verified against a hand-built canonical D64
      (a 2-sector chained file + a 1-sector file): standalone L/X/XA all
      byte-exact (SHA1), and the cc /T harness browsed the image (members
      listed) and F5-extracted HELLO.PRG into the other panel byte-exact.
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
