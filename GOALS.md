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

Last updated: 2026-06-23 — G1–G6 GREEN (ZIP, D64, T64, ARJ, RAR browse/extract); starting G7 ([view] framework).

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
- [x] **G4 — CCT64 (C64 tape archive).** DONE. New helper `ct64.asm` →
      `cct64.com` (1,006 B) with the L/X/XA contract. Parses the 64-byte T64
      header (max/used entries), walks the 32-byte directory records (skipping
      free slots), and extracts by absolute data offset. Because T64 data
      streams omit the 2-byte load address, the helper prepends it from the
      record (`+2`) so the output is a valid `.PRG`; the file length is
      `end-addr − load-addr` clamped to end-of-file (guards the well-known
      bad-end-addr T64 bug). `cc.ini` `[open]` gains `t64 = CCT64`. Verified
      against a hand-built T64 (a $0801/300-byte file + a $C000/50-byte file):
      standalone L/X/XA byte-exact, and cc /T browsed the archive and
      F5-extracted GAME.PRG byte-exact.
- [x] **G5 — CCARJ (ARJ archive).** DONE. New helper `carj.asm` →
      `ccarj.com` (1,067 B), L/X/XA contract. Walks the ARJ block chain
      (0x60 0xEA magic + basic-header size; skips the main header and any
      extended headers; stops at the size-0 end marker). Lists EVERY entry
      (original size + base name from header `+30`). Extracts method-0
      (STORED) members byte-for-byte; compressed members (ARJ's own
      LZ77+Huffman, methods 1–4) are listed but skipped on extract
      ("decompress best-effort" per the goal) — the walk stays aligned by
      skipping `compressed-size` (`+12`) bytes. `cc.ini` `[open]` gains
      `arj = CCARJ`. Verified against hand-built spec-valid ARJs (correct
      CRC-32s): standalone L/X/XA byte-exact, a mixed stored/compressed
      archive browses all 3 entries and extracts only the 2 stored ones with
      the parser staying aligned, and cc /T browsed + F5-extracted READ.ME
      byte-exact.
- [x] **G6 — CCRAR (RAR archive).** DONE. New helper `crar.asm` →
      `ccrar.com` (1,164 B), L/X/XA contract. Validates the RAR 4.x marker
      ("Rar!\x1a\x07\x00"), declines RAR5 (marker byte 6 = 0x01), then walks
      the block chain by base header (HEAD_TYPE/FLAGS/SIZE + optional
      LONG_BLOCK ADD_SIZE). Lists every FILE_HEAD (0x74) using UNP_SIZE and
      the path-stripped name (NAME_SIZE @+26, name @+32, +40 if LARGE); skips
      directory dict entries; stops at the end block (0x7b). Extracts METHOD
      0x30 (STORED, non-encrypted) members byte-for-byte; compressed methods
      are listed but skipped on extract (RAR LZ is proprietary). `cc.ini`
      `[open]` gains `rar = CCRAR`. Verified against a hand-built spec-valid
      RAR4 (correct header CRC-16 + file CRC-32): standalone L/X/XA byte-exact,
      a mixed stored/compressed archive lists all 3 entries and extracts the 2
      stored ones (parser staying aligned past the skipped compressed entry),
      and cc /T browsed + F5-extracted ALPHA.TXT byte-exact.

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
