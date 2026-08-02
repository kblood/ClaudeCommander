# CCMDL — Real-Hardware AO486 Repro Investigation

Bug report (2026-07-01): CCMDL.COM (Quake `.mdl` viewer, part of the `cc` DOS
file manager) renders correctly in DOSBox (`verify_mdl/ccmdl_soldier.png`)
but reportedly "doesn't actually work" on the real MiSTer AO486 FPGA core.
User wasn't sure if they ran the wrong core variant.

Rig: MiSTer 192.168.50.130 (SSH root). Non-destructive run (added files only).

**Note on the verdict below: this is a synthesis written directly from the
two repro-phase agents' raw findings, NOT from the workflow's own
"Synthesize verdict" phase — that phase malfunctioned and returned literal
placeholder output (`"test"`/`"test"`/`false`), so it was discarded.**

---

## What was actually established

### 1. The rig's stock/default "AO486" core almost certainly predates the FPU fix

Confirmed by direct inspection: the file backing a plain "AO486" menu pick is
`/media/fat/_Computer/ao486_20241227.rbf` — the only bare-named `ao486_*.rbf`
in that folder (every FPU-fix-era build carries an extra qualifier:
`ao486_fpu_20260623.rbf`, `ao486_fpu_75mhz_20260626.rbf`, etc.). Confirmed via
`ps` that this is genuinely what loads for a normal "AO486" pick (not a stale
read), and that `MiSTer.ini`'s `[AO486]` section applies its
`main=MiSTer_w9xdsc_20260618` HPS-binary override to it.

Build-id date: **2024-12-27**, vs. **2026-06-23 through 2026-06-26** for the
whole FPU-fix family (the DC-register FDIV decode fix, commit `394d2f7`).
That's roughly **18 months older** than the known-good builds — strong
filename/provenance evidence (not a byte-for-byte RTL diff) that the stock
slot predates the fix.

**This directly supports the user's hunch.** CCMDL does ~210 raw x87 FPU
instructions for its 3D transform math — exactly the instruction class the
old bug affected. If CCMDL (or anything FPU-heavy) is run via a plain "AO486"
menu pick rather than one of the dated `_Computer/ao486_fpu_*_2026*` test
cores, it is almost certainly running on the pre-fix core.

### 2. Mechanically, CCMDL did not crash or reset either core

Both the known-good `ao486_fpu_75mhz_20260626` core and the stock
`ao486_20241227` core loaded the CCMDL boot floppy (`AO486-CCMDL.img` →
`CCMDL.COM SOLDIER.MDL`) and stayed alive/stable (same PID, no reset to menu)
for the full observation window (~100-260s). So whatever is wrong, it is not
an instant hard crash/reset on either core, at least not within that window.

### 3. Visual verification is BLOCKED — separate, rig-wide infrastructure bug

Screenshot capture failed on **both** cores, in **two different failure
modes**:
- On the FPU-fixed core: an early POST-time shot showed a real (if glitchy)
  BIOS splash, but every later shot (when DOS/CCMDL should have been
  rendering) was pure salt-and-pepper static.
- On the stock core: every shot was uniform solid black (~932 bytes, far
  below a real frame).

The agent cross-checked by screenshotting the safe, known-good **MENU** core
on both occasions — it ALSO came back broken (same failure mode as whichever
AO486 core was active at the time). This proves the screenshot/capture
pipeline itself is non-functional for this rig session, independent of
AO486, CCMDL, or which core is loaded. **No trustworthy visual evidence
exists either way** about whether CCMDL actually renders the soldier model
correctly, garbled, or not at all, on either core.

---

## Verdict

**Plausible, well-supported, but not visually confirmed.** The stock/default
AO486 core is real, identified, and ~18 months older than the FPU fix —
that part is solid and actionable today regardless of anything else. But we
cannot currently say with certainty that running CCMDL on the fixed core
actually fixes the user's symptom, because the rig's screenshot pipeline is
broken right now and produced no usable image on EITHER core. The
investigation is honestly **inconclusive on the visual question**, even
though the "wrong core" theory is the best-supported explanation available.

## Recommendations

1. **Immediate, no-risk fix**: always launch CCMDL (and any FPU-heavy DOS
   program) via the explicit dated core `_Computer/ao486_fpu_75mhz_20260626`,
   never the plain "AO486" menu entry, until/unless the fix is promoted to
   the stock slot.
2. **Bigger fix (needs a decision)**: promote the FPU-fixed build to the
   stock/default AO486 slot (the `ao486-variant-core` skill exists
   specifically for deploying a fix without clobbering the shared `[AO486]`
   section) so casual use never hits the pre-fix core again. Not done here —
   touches shared rig state beyond this investigation's additive-only scope.
3. **Blocking for future work**: the screenshot/capture pipeline needs to be
   diagnosed and fixed (or an external HDMI capture device used per the
   `mister` skill's own caveat) before any further visual-render
   verification on this rig is worthwhile. This affects more than CCMDL —
   every future "does it actually look right on hardware" check depends on
   it. Two independent agents hit two different broken-capture failure modes
   (noise, then black) in the same session, on every core tried including
   the known-good MENU UI — this is squarely a capture-tooling fault, not
   anything specific to AO486 or DOS programs.
4. **Re-run once (3) is fixed**: redeploy is not needed — `CCMDL.COM` /
   `SOLDIER.MDL` (`D:\Tools\CCMDL\` on `4GB-Games.vhd`), the boot floppy
   (`AO486-CCMDL.img`), and both MGLs (`_Test/ao486_ccmdl75.mgl`,
   `_Test/ao486_ccmdl_stock.mgl`) are left in place on the rig for an
   immediate re-attempt.

## UPDATE (2026-07-01, later same day): scaler-removal explained + a NEW, more precise finding

The "broken rig-wide screenshot pipeline" above was **not actually a bug** — the
user clarified that the FPU-enabled AO486 core build has its HDMI scaler
physically compiled out (`MISTER_DEBUG_NOHDMI=1`, ~2.3k ALMs freed) to make
room for the custom x87 FPU RTL. Confirmed with hard evidence: the `ascal`
instantiation in `sys_top.v` is `` `ifndef MISTER_DEBUG_NOHDMI ``-gated, the
FPU repo's `.qsf` has that macro active (stock `ao486_baseline`'s `.qsf` has
the equivalent line commented out with `#do not enable DEBUG_NOHDMI in
release!`), an explicit "removed scaler" commit exists in this project's own
history (`ao486_decfix` `b443073`), and the shipped `AO486-FPU-20260623/README.md`
says outright: "Video — analog VGA only (NO HDMI)... there is no HDMI
picture." The normal MiSTer screenshot path (`scaler.cpp`'s `do_screenshot`)
literally copies from the scaler's framebuffer — with no scaler in the
bitstream, there's nothing for it to copy. Not a fixable software bug on this
build; a resource trade-off.

**Workaround built instead of fixing the unfixable**: a new tool,
`C:\LLM\MiSTer\AO486\tools\analyze\vga_mode13_screenshot.py`, reads the
AO486 guest's own VGA mode-13h linear framebuffer directly via `/dev/mem`
(reusing the project's existing `guest_peek.py` mechanism: host address =
`0x30000000 + guest_physical_address`, completely independent of the scaler —
a different memory window entirely, ascal's own framebuffer is at base
`0x20000000`). Decodes the raw 64000 index bytes using the REAL Quake
palette (extracted from `gfx/palette.lmp` inside `pak0.pak`, not hardcoded),
writes a PNG. Verified working end-to-end against the live rig.

**Re-ran CCMDL on the FPU-fixed core (`ao486_fpu_75mhz_20260626`) with this
new tool — and got a real, trustworthy answer for the first time:**
CCMDL **does** successfully set VGA mode 13h (confirmed via the BIOS Data
Area mode byte at guest `0x449` reading back `0x13`), so it is not stuck at
a DOS prompt or crashed. But the framebuffer itself is **solid black
(0/64000 nonzero bytes) in all 6 captures spanning ~8 minutes** — the
soldier model is never drawn. This is a **different bug than "wrong core"**:
even on the confirmed FPU-fixed core, something stalls between the mode-set
call and the first draw. Not yet root-caused — a follow-up instrumentation
pass (progress markers written past the visible framebuffer at guest
`0xAFA00+`, peeked via `guest_peek.py`) is the planned next step to find
exactly where execution stops.

**User-confirmed (2026-07-01): this matches the original bug report exactly** —
no crash, no reset, just the model never appearing. Good sign this is the
real bug, not an artifact of the guest-framebuffer test setup.

## ROOT CAUSE, precise location (2026-07-01)

Instrumented `cmdl.asm` with progress markers written past the visible
framebuffer (guest `0xAFA00+`) and re-ran on the FPU-fixed core. **CCMDL
never reaches its own `.frame` loop at all.** Markers confirm file-open and
full model parse complete every time (proving DOS file I/O and CCMDL's one
non-transcendental FPU burst in `parse_model` both work), then CCMDL calls
`set_mode13` (`int 10h AL=13h`) — and **execution never returns**. The BIOS
handler runs far enough to stamp the BIOS Data Area mode byte (`0x449=0x13`,
which is exactly why the earlier finding looked like "mode set correctly"),
but control never comes back to CCMDL. None of CCMDL's own FPU, vsync,
keyboard, or rendering code ever runs — not once, across 25 samples over
~530s and 2 independent rebuild/redeploy cycles.

**CCMDL's own code is therefore cleared of suspicion.** The bug is one level
down: inside the video BIOS's `int 10h` mode-set routine or the CPU's
real-mode INT/IRET mechanism. Leading hypothesis (medium confidence): CCMDL
is a bare, un-brokered real-mode `.COM` doing a genuine real-mode
`int 10h`/`iret` round-trip — likely the first such raw real-mode interrupt
exercised on this core anywhere in this investigation. TurboQuake calls the
textually identical BIOS service and works fine, but only via its DOS
extender's DPMI "simulate real-mode interrupt" brokering (V86 mode) — a
different CPU mode than CCMDL's plain real mode. Directly ruled out (RTL
trace of `execute_fpu.v`/`execute.v`): an unmasked-FPU-exception auto-vector
collision with the BIOS's own vector `0x10` — the fault-trigger wire exists
but is currently dead/unconnected in this RTL, so that specific collision
isn't possible yet (worth guarding against before it gets wired up later).

Unresolved evidence tension: the checked-out BIOS source clears the entire
64 KB `0xA000` segment before stamping the mode byte, which should also wipe
the markers living at `0xAFA00+` — but they survive intact every time.
Either the flashed BIOS ROM doesn't match the checked-out source, or there's
a write-ordering anomaly. Two cheap follow-up experiments proposed and
queued: call `int 10h` with `AL=0x93` (skip the BIOS's own clear, since
CCMDL already clears its own back buffer) to see if the hang is in that
clear step; and add markers outside the `0xA000` segment entirely to remove
any ambiguity from the BIOS's own VRAM writes.

**Gotcha discovered along the way**: DOS base filenames must stay ≤8 chars
(8.3) for a plain-FreeDOS `AUTOEXEC.BAT` to resolve them on the rig's vfat
floppy — a 9-char debug-binary name silently became LFN-only and made the
whole boot look like a total hang until caught and renamed.

## Rig contention note

~3 minutes after this investigation's phase-2 agent wrote its lock, the
concurrently-running Quake frame-profiling workflow's agent judged the lock
"stale" (60s of polling, core idle on MENU at that moment) and took over the
rig. The CCMDL agent detected the takeover via a routine `ps` check, backed
off immediately rather than contending, waited for the other agent's clean
NOLOCK release, then re-acquired and redid its `load_core` from scratch. No
data was corrupted, but the "stale after 60s" heuristic is fairly aggressive
for a multi-agent shared rig and nearly caused a real collision. **Lesson:
stagger rig-touching workflow launches, or have one explicitly wait for the
other's NOLOCK before starting, rather than firing both at once.**

Rig left clean both phases: only additive files added (`D:\Tools\CCMDL\*`,
`AO486-CCMDL.img`, two `.mgl` files in `_Test`), no existing benchmark files
touched, no core reflashed, returned to MENU at the end.

## EXP1: OUT-OF-VGA-SEGMENT MARKERS — the "ROOT CAUSE" conclusion above is WRONG (2026-07-01)

Built `C:/LLM/DOS/cc/cmdl_exp1.asm` -> `CCEXP1.COM` (from `cmdl_instrumented.asm`), adding
two markers written to **CCMDL's own DS-relative data segment** (its default `.COM`
segment, addressed with no segment override — completely outside `0xA000`-`0xAFFFF`
VRAM) immediately before and immediately after `call set_mode13`, specifically to remove
the "does the BIOS's own VRAM clear explain the surviving markers?" ambiguity flagged in
the ROOT CAUSE section above. CCMDL's own DS is fixed for the whole run (a `.COM`'s
DS=CS=PSP segment, never reassigned except transiently push/pop'd inside `flip`), so a
third marker (mirrored into the existing FS/VRAM scheme, for convenience only) records the
live DS value once at `start:`; this + each label's file offset (independently confirmed
byte-for-byte against the compiled `CCEXP1.COM`, e.g. locating the literal `Usage: CCMDL`
string and the unique `9A 99 19 3F` (0.6f) bit pattern for `angY`) gives an exact,
zero-guesswork `guest_pa` for the two new markers.

**Result: BOTH new markers fired** — `exp1_before`=0xAA, `exp1_after`=0xBB — read back at
guest_pa 0x6708/0x6709 (this run: DS=0x0575), stable and unchanged across 6 re-samples
over 42s (i.e. not a race/fluke). Correctness of the address math was cross-checked two
independent ways: (1) the bytes immediately surrounding the two markers exactly match the
known static file layout (tail of the `s_badpak` string right before, start of
`fname`="SOLDIER.MDL\0" right after); (2) further, *unrelated* own-DS state also changed
from its known fresh/pre-run value — `sinY` moved off `0.0` (proving `update_angles`'s
FSINCOS executed, though the resulting bit pattern does not match the expected
`sin(0.6)`, an open question flagged below) and `loaded_idx` moved from `0xFFFFh` to
`0x0000` (proving the unrelated, non-FPU `ensure_loaded` path in the `.frame` body also
ran). Three independent, mutually-corroborating own-memory observations all agree:
**CCMDL's own control flow genuinely continues past `call set_mode13`, into the `.frame`
loop.**

**This directly overturns the "execution never returns from int10h" ROOT CAUSE conclusion
above.** Control does return. Yet every *original* marker past M3 (M3b, M4, M5..M12,
`nvis` — all FS-segment/VRAM writes at guest_pa `0xAFA00+`) still reads as never-fired, and
the real mode-13h framebuffer (guest_pa `0xA0000`, 64000 bytes) is still **100% zero bytes**
even though we've now proven the renderer's own code executed at least one full pass.

**Revised leading hypothesis**: writes into the `0xA000` VGA aperture become unreliable/
lost once mode 13h is actually active on this core (plausibly a hardware/RTL issue in the
mode-13h VGA memory path, separate from the BIOS/`int 10h` mechanism itself) — this would
directly explain the user's original symptom (soldier never appears) without needing any
"hang" at all. An unconfirmed alternative/additional hypothesis: the FSINCOS result written
to `sinY` does not match the textbook `sin(0.6)` value, suggesting a possible FSINCOS
correctness bug on this FPU-fixed core that could itself corrupt the downstream transform/
projection math badly enough that no triangle ever passes the rasterizer's on-screen bounds
check (yielding an all-zero back buffer even with `set_mode13`/VRAM writes working fine).
**Neither hypothesis is confirmed over the other yet — both are consistent with the
all-zero-framebuffer evidence, and this is the natural next investigation step**: (a) probe
whether a plain, repeated write-then-readback loop into `0xA000` survives once mode 13h is
active (isolates the VGA-aperture-write-loss hypothesis from everything else), and (b)
independently verify FSINCOS's numeric result against a known-good x87 core for the same
input angle (isolates the FPU-correctness hypothesis).

Rig etiquette followed: LOCK written before starting, additive-only files
(`D:/Tools/CCMDL/CCEXP1.COM`, `AO486-CCEXP1.img`, `_Test/ao486_ccexp1_75.mgl`), original
`CCMDL.COM`/`CCMDLDBG.COM`/`SOLDIER.MDL` re-verified byte-identical (md5) to their pre-run
values, NOLOCK written on completion. A concurrent agent took the rig immediately after
this session's post-run menu-flush load (loaded `AO486S3_m8_20260701b`) — no contention,
this session's data capture had already completed by then.

## EXP2: `AL=0x93` ("don't clear video memory") — rules out the BIOS-clear theory (2026-07-01)

Built `C:/LLM/DOS/cc/cmdl_exp2.asm` -> `CCEXP2.COM`, derived from `cmdl_exp1.asm` (so it
keeps every EXP1 marker: the 16 in-VGA-segment M1..M12/M3b/M_SGP_* markers plus the two
own-DS `exp1_before`/`exp1_after` markers) with **exactly one functional change**: inside
`set_mode13`, `mov ax, 0013h` -> `mov ax, 0093h` (bit 7 of AL set = the video BIOS's
documented "don't clear video memory" mode-set request). Confirmed via `cmp -l` that
`CCEXP2.COM` differs from `CCEXP1.COM` in exactly one byte (the AL immediate), so every
label/marker offset is byte-identical to EXP1's already-validated addresses. (Aside,
useful for future instrumentation work: this build also turned up a real NASM `-f bin`
listing quirk — for absolute-memory operands that forward-reference a label defined later
in the source, the `-l` listing's bracketed operand value can be stale by exactly one `org`
worth (0x100 here), e.g. showing `[B80E]` when the actual assembled byte is `B8 0F`.
Verified by direct hexdump of the compiled `.COM` at the listing's own instruction-address
column, which IS reliable. Ground truth used throughout: `exp1_before`=DS-offset `0x0FB8`,
`exp1_after`=`0x0FB9`, `sinY`=`0x116B`, `loaded_idx`=`0x10DB` — all confirmed directly
against compiled machine-code bytes, not trusted from the listing alone.)

Deployed additively (`D:/Tools/CCMDL/CCEXP2.COM`, `AO486-CCEXP2.img` — a copy of
`AO486-CCEXP1.img` with `AUTOEXEC.BAT` repointed at `CCEXP2.COM`, `_Test/ao486_ccexp2_75.mgl`),
ran on `ao486_fpu_75mhz_20260626` for >90s.

**Result: identical symptom pattern to EXP1, byte for byte.** BDA mode byte `0x449=0x13`
(mode set "succeeded" in the sense the BIOS still stamps the base mode number even with the
no-clear bit set). Own-DS markers `exp1_before`=`0xAA`/`exp1_after`=`0xBB` both fired
(guest_pa `0x6708`/`0x6709`, DS=`0x0575`) — control genuinely returns from `int 10h`, same
as EXP1. Further own-DS cross-checks also moved: `loaded_idx` `0xFFFF`->`0x0000` (guest_pa
`0x682B`) and `sinY` `0.0`->`960.877...` (nonzero; guest_pa `0x68BB`) — proving the `.frame`
loop's `ensure_loaded`/`update_angles` genuinely executed, exactly mirroring EXP1's evidence
that CCMDL's own control flow reaches and runs the frame loop.

But every **FS-segment/VRAM** marker written *before* `call set_mode13` (M1/M2/M3 at
guest_pa `0xAFA00`-`0xAFA02`, the `MARK_BEFORE` mirror at `0xAFA24`) read back correctly,
while every FS-segment/VRAM marker written *after* `set_mode13` returns (M3b at `0xAFA0C`,
the `MARK_AFTER` mirror at `0xAFA25`, and M4 through M12/`M_SGP_*`/`nvis`) **all read as
never-fired** — and the mode-13h framebuffer itself (guest_pa `0xA0000`, 64000 bytes) is
**100% zero** (`vga_mode13_screenshot.py` capture: solid black, saved to
`verify_exp1/ccexp2_shot.png`, 0/64000 nonzero index bytes).

**This directly answers the assigned question: the hang/loss is NOT inside the BIOS's own
64KB memory-clear step.** `AL=0x93` should skip that clear entirely, yet the exact same
failure pattern occurs — down to the same specific markers surviving/not-surviving as
EXP1's `AL=0x13` run. Since there is no BIOS clear happening in this variant at all, "the
BIOS's own clear wipes the markers" cannot be the mechanism; something else makes writes
into the `0xA000`-`0xAFFFF` VGA aperture unobservable once mode 13h is genuinely active on
this core, for the remainder of execution (not just transiently right after the mode set —
the `.frame` loop's per-lap M5 counter and repeated `flip`/`draw_vislist` writes never
appear either, across the whole >90s run). This is now the **second independent
experiment** (different AL flag, same outcome) supporting EXP1's revised hypothesis: a
hardware/RTL issue in the mode-13h VGA memory write path on this core, not a BIOS-clear
race, not a CPU real-mode INT/IRET issue, and — per the `loaded_idx`/`sinY` evidence — not
a full hang in CCMDL's own code either. The FSINCOS-correctness question flagged at the end
of EXP1 remains open and unrelated to this specific test (`sinY`'s value here, 960.877,
is again clearly not `sin(0.6)`, consistent with — but not newly diagnostic of — that
separate open question).

**Suggested next step**: EXP1's proposed follow-up (b) — a plain, repeated
write-then-readback loop straight into `0xA000` once mode 13h is active, with no CCMDL
rendering logic involved at all — would isolate the VGA-aperture-write-loss hypothesis
completely from any FPU/rendering-correctness question, and is now the highest-value next
experiment given EXP1+EXP2 have jointly eliminated both "the int10h hangs" and "the BIOS's
own clear explains it."

Rig etiquette followed: LOCK written before starting, additive-only files
(`D:/Tools/CCMDL/CCEXP2.COM`, `AO486-CCEXP2.img`, `_Test/ao486_ccexp2_75.mgl`);
`CCMDL.COM`/`CCMDLDBG.COM`/`SOLDIER.MDL`/`CCEXP1.COM` re-verified byte-identical (md5) to
their pre-run values; core returned to `menu.rbf` and NOLOCK written on completion.

## FINAL SYNTHESIS (2026-07-01): combining EXP1 + EXP2

**Decision-tree resolution.** EXP1 established `control_returned=true` (own-DS,
non-VGA markers prove CCMDL's code genuinely resumes after `int 10h AL=13h` and runs at
least one full `.frame` loop pass). That alone falsifies the earlier "ROOT CAUSE: execution
never returns from `int 10h`" conclusion and opens the specific sub-hypothesis "the BIOS's
own 64 KB VRAM clear is wiping the in-VGA markers, making a live program look hung." EXP2
then directly tested and **ruled out** that sub-hypothesis: requesting `AL=0x93` (no
BIOS memory clear at all) reproduced the byte-for-byte identical symptom — control still
returns, `.frame` still runs (own-DS state still advances), yet every VRAM write after
`set_mode13` is still unobservable and the framebuffer is still 100% zero. Since there is
no clear happening in that variant, the clear cannot be the mechanism.

**Root cause, precise and falsifiable**: once real mode 13h is genuinely active on the
FPU-modified `ao486_fpu_75mhz_20260626`-family core, writes into the `0xA000`-`0xAFFFF`
VGA aperture become permanently lost/unobservable for the rest of execution, while CCMDL's
own non-VGA state and control flow continue completely normally (proven by `exp1_before`/
`exp1_after`, `loaded_idx`, and `sinY` all changing as expected, repeatedly, across two
independently-built binaries with different BIOS mode-set flags). Critically, the markers
that fail to appear post-mode-set (`M3b`, `M4`..`M12`, `M_SGP_*`, `nvis`, the
`MARK_AFTER` mirror) are **all hardcoded-immediate `mov byte` writes with no dependency on
any FPU/transform result** — so their absence cannot be explained by the separate,
still-unconfirmed FSINCOS-numeric-correctness anomaly (`sinY` not matching textbook
`sin(0.6)`) noted in EXP1/EXP2; that anomaly might independently explain an all-black
*rendered picture* even if writes worked, but it cannot explain simple sentinel bytes
failing to land at all. This makes "VGA-aperture writes are lost post-mode-13h-set" the
dominant, best-supported explanation for the user's original symptom, not a rendering/FPU
correctness bug.

The two most-precise remaining candidate mechanisms (not yet distinguished from each
other):
1. A genuine hardware/RTL defect in this core's VGA memory write/arbitration path that
   only manifests once mode 13h is actually engaged (as opposed to the BIOS's own
   mode-set-time writes, which are known to succeed — the BDA stamp and, per the original
   investigation, the mode-set's own internal writes presumably land fine). Plausibly
   related to the same build family that had the scaler physically removed
   (`MISTER_DEBUG_NOHDMI=1`) and the FPU RTL added (commit `394d2f7`) — i.e. a
   resource-trim or FPU-integration side effect on the video-memory path specifically in
   this modified core, not present in a stock/unmodified AO486.
2. A host-side observability artifact: `guest_peek.py`/`vga_mode13_screenshot.py` read
   guest physical memory via `/dev/mem` at `0x30000000 + guest_pa`; it is not yet proven
   that this mapping stays valid/coherent for the `0xA000` window specifically **after**
   mode 13h is set (e.g. if the core reroutes/double-buffers that guest-physical range
   once graphics mode is active, a host-side peek could read stale/wrong memory even
   though the guest's own writes landed correctly in whatever backs the real display).

**Confidence: medium.** High confidence that the original "int10h hang" and "BIOS-clear"
theories are both wrong (two independent, mutually-corroborating, reproducible experiments
with own-DS controls). Medium (not high) confidence that mechanism (1) above is the exact
final answer, because mechanism (2) has not yet been directly excluded — no experiment so
far has had the *guest itself* read back a post-mode-13h VRAM write and store the
readback result in its own non-VGA memory (which would settle guest-side truth
independent of the host peek path).

**Needs more investigation: yes.** Two concrete, cheap follow-ups fully settle this:
- **Guest-side self-readback test** (highest priority): after `set_mode13`, have CCMDL (or
  a new minimal EXPn) write a byte to `0xA0000`-ish, immediately `mov al,[that address]`
  back in the *same* segment/context, and store the readback byte into an own-DS (never
  VGA) location. If the guest itself reads back the wrong/zero value, mechanism (1)
  (genuine RTL write-path loss) is confirmed and the host-peek tooling is fully exonerated.
  If the guest reads back its own correct value but the host peek still shows zero,
  mechanism (2) (host-side mapping/observability artifact) is confirmed instead, and the
  fix is entirely tooling-side (fix `guest_peek`'s address translation/timing for
  post-mode-13h reads), not RTL.
- Independently verify FSINCOS's numeric output against a known x87 reference for the same
  input angle — a real, separate, still-open correctness question, orthogonal to the VGA
  write-loss finding above, worth fixing regardless since it affects any FPU-heavy program's
  rendering math on this core.

**No actionable end-user workaround yet.** Unlike the earlier (now-superseded) "always
launch via the FPU-fixed dated core" recommendation (still correct and unaffected by this
finding — that's about which core build to pick, not this bug), there is currently no known
`AL=` flag, timing change, or CCMDL-side code change that avoids this specific failure;
`AL=0x93` was tried and does not help. A real fix requires either an RTL fix to the VGA
memory path (if mechanism 1) or a `guest_peek`/screenshot-tooling fix (if mechanism 2) —
determined by the guest-side self-readback experiment above before further effort is spent
on either.

## EXP3: GUEST-SIDE SELF-READBACK PROBE — settles it: mechanism (2), NOT mechanism (1) (2026-07-01)

Built `C:/LLM/DOS/cc/cmdl_exp3.asm` -> `CCEXP3.COM`, derived from `cmdl_exp1.asm` (keeps every
EXP1 marker unchanged: FS/VRAM M1..M12/M3b/M_SGP_* plus own-DS `exp1_before`/`exp1_after`;
`set_mode13` left as plain `AL=0x13`, not EXP2's `0x93`). Adds exactly one new thing, inserted at
the same point as the existing M3b/`MARK_AFTER` markers (immediately after `call set_mode13`
returns): `mov ax,VGA_SEG` / `mov es,ax` / `xor di,di` (the identical ES-segment convention
`flip` already uses for its own VGA writes) -> `mov byte [es:di], 77h` (write to guest_pa
`0xA0000`) -> `mov al,[es:di]` (read the *same* address straight back, same ES:DI context, no
intervening instruction) -> `mov [exp3_readback], al` (store the GUEST's own readback into a new
own-DS, never-VGA byte). The `0xA0000` byte itself is left at `0x77` (not cleared) so a
subsequent host-side peek of the identical address is a direct, apples-to-apples comparison.

Every offset was confirmed directly against the compiled `CCEXP3.COM`'s bytes, not trusted from
the `-l` listing alone (the listing's bracketed absolute-address quirk flagged in EXP2 reproduced
again here: e.g. the listing showed `mov [exp3_readback],al` as `A2 [CB0E]` but the actual
assembled bytes at that file offset are `A2 CB 0F`, i.e. `0x0FCB`, confirmed by dumping the raw
`.COM`). Ground truth used: `exp1_before`=DS-offset `0x0FC9`, `exp1_after`=`0x0FCA`,
`exp3_readback`=`0x0FCB`, `loaded_idx`=`0x10ED`, `sinY`=`0x117D` (all independently
cross-checked two ways: byte-content of the Data section immediately following the known
`s_badpak` string tail, and the literal operand bytes of the instructions that reference them).

Deployed additively (`D:/Tools/CCMDL/CCEXP3.COM` md5 `e5cc07cb95667d9fe6d4db6275fb5bd4`,
`AO486-CCEXP3.img` — copy of `AO486-CCEXP2.img` with `AUTOEXEC.BAT` repointed at
`CCEXP3.COM SOLDIER.MDL`, `_Test/ao486_ccexp3_75.mgl`), ran on `ao486_fpu_75mhz_20260626` for
~180s continuous, with two independent `guest_peek.py` samples ~120s apart (identical both
times — not a race/fluke).

**Raw observations (DS=`0x0575` this run, same PSP segment as EXP1/EXP2):**
- BDA mode byte `guest_pa 0x449` = `0x13` (mode-13h confirmed active, as always).
- `exp1_before` @ `guest_pa 0x6719` = `0xAA` — fired (control reaches the pre-mode-set marker).
- `exp1_after` @ `guest_pa 0x671A` = `0xBB` — fired (control genuinely returns from `int 10h`).
- **`exp3_readback` @ `guest_pa 0x671B` = `0x77`** — **the GUEST's own readback of its own write
  to `0xA0000` is CORRECT.** From the guest's own point of view, the write to the VGA aperture
  landed and is readable immediately afterward, in the same ES:DI context, post-mode-13h-set.
- `loaded_idx` @ `guest_pa 0x683D` = `0x0000` (moved from its fresh `0xFFFF`) — `.frame`'s
  `ensure_loaded` genuinely ran, consistent with EXP1/EXP2.
- `sinY` @ `guest_pa 0x68CD` = bytes `73 AD BD C2` LE = float `-94.8388` — nonzero (FSINCOS ran),
  but still not `sin(0.6)=0.564642...`, reconfirming the separate, still-open FSINCOS-correctness
  question flagged in EXP1/EXP2 (unrelated to this experiment's conclusion, see below).
- **Host-side `guest_peek.py` read of `guest_pa 0xA0000` (the identical address, taken while the
  same core/session is still running, no reboot in between) = `0x00`, not `0x77`.** Checked three
  ways: the first 16 bytes of the framebuffer (all zero), a 96-byte window `0x9FFE0`-`0xA003F`
  scanned for a stray `0x77` anywhere nearby (none found — rules out a fixed page/bank
  addressing-offset bug as the explanation), and the full 64000-byte framebuffer via
  `vga_mode13_screenshot.py` (0/64000 nonzero, saved to `verify_exp1/ccexp3_shot.png` /
  `.raw.bin` — solid black, matching every prior capture).
- FS-segment/VRAM markers `0xAFA00`-`0xAFA2F` reconfirmed the established pattern one more time:
  M1/M2/M3 (`01 02 03`) present, everything from M3b onward (offset `0x0C`+) still zero.

**This is the decisive result the FINAL SYNTHESIS called for.** The guest itself, immediately
after writing `0x77` to `0xA0000` in a live ES:DI context with zero intervening code, reads that
exact byte back as `0x77` — proof positive that CCMDL's own write to the VGA aperture succeeded
from the CPU's own point of view post-mode-13h-set. Yet the host's `/dev/mem`-based
`guest_peek.py`, reading the textually identical guest physical address in the same running
session moments later, sees `0x00`. **This falsifies mechanism (1)** (a genuine RTL/hardware
defect that loses VGA-aperture writes once mode 13h is active) as the explanation for the
all-zero framebuffer — the write is demonstrably NOT lost from the guest's perspective. **This
confirms mechanism (2)**: the host-side observability path (`/dev/mem` at
`0x30000000 + guest_pa` for the `0xA000` window) does not see what the running guest itself
sees, once real mode-13h is active. Whatever backs the guest's own reads of that address
(register-file bypass, write-combine buffer, a shadow/cache the CPU model reads from that isn't
mirrored out to the shared-memory path the HPS peeks, or a similar internal path specific to
this core's mode-13h handling) is not the same thing `guest_peek.py`/`vga_mode13_screenshot.py`
observe over `/dev/mem`. The earlier "hardware/RTL write-path loss" leading hypothesis from the
FINAL SYNTHESIS is **overturned**; the still-open, separate FSINCOS-numeric-correctness question
remains exactly that — separate and unrelated (it cannot explain a hardcoded-immediate `0x77`
sentinel byte failing to appear over `/dev/mem`, any more than it could explain M3b/M4..M12 not
appearing in EXP1/EXP2).

**Practical implication:** the user's original symptom (soldier model never appears on real
hardware) is **not yet fully explained by an RTL defect** — it may be a genuine on-screen
rendering failure (if whatever the guest itself reads back is *also* what the physical
VGA/analog output scans out), or it may be that the picture is actually fine on real analog VGA
output and only the `/dev/mem`-based tooling this whole investigation has relied on
(`guest_peek.py`, `vga_mode13_screenshot.py`, and by extension every "solid black" conclusion
drawn from them in this document) is blind to it. That distinction is now the single open
question, and it requires either (a) real analog-VGA visual verification (the HDMI scaler is
compiled out on this build, per the earlier scaler-removal note, but a direct VGA capture device
would settle it), or (b) an RTL-side trace of exactly what the CPU's own `mov al,[es:di]` reads
from for guest-physical `0xA000`-range addresses post-mode-13h-set, and where that diverges from
whatever `/dev/mem` maps to at HPS `0x30000000 + 0xA0000` — neither of which this
software-only/SSH-only investigation can perform.

Rig etiquette followed: LOCK written before starting (`ccmdl-exp3-self-readback`), additive-only
files (`D:/Tools/CCMDL/CCEXP3.COM`, `AO486-CCEXP3.img`, `_Test/ao486_ccexp3_75.mgl`);
`CCMDL.COM`/`CCMDLDBG.COM`/`SOLDIER.MDL`/`CCEXP1.COM`/`CCEXP2.COM` re-verified md5-identical to
their pre-run baseline post-run; core returned to `menu.rbf` and NOLOCK written on completion.

## EXP4: RTL-TRACED MECHANISM CONFIRMED, ADDRESS-TRANSLATION FIX VALIDATED-FALSE, TOOLING FIXED (2026-07-01)

Follow-up to a static-analysis investigation (RTL: `C:/LLM/MiSTer/AO486/repos/ao486_decfix`)
that identified the mechanism EXP3 left open: guest-physical `0xA0000-0xBFFFF` is decoded by
`rtl/cache/l2_cache.v` into a `vga_rgn` wire; once the guest's Graphics Controller Memory Map
Select register is programmed for a real graphics/text mode (mode 13h uses Map Select=01,
`VGA_MODE=3'b101` -> `vga_mask=2'b10`,`vga_cmp=2'b00`, which does classify `0xA0000` as
`vga_rgn`), the IDLE-state `CPU_RD`/`CPU_WE` dispatch (`l2_cache.v:297-331`) diverts the access
to a **completely separate on-chip `VGA_ADDR/VGA_DIN/VGA_DOUT` bus** feeding real Cyclone V
block RAM (`rtl/soc/vga.v` `dpram_difclk` plane RAM x4, `rtl/common/bram.vhd` `altsyncram`,
confirmed `intended_device_family => "Cyclone V"`) **unless** `VGA_FB_EN` (`ao486.sv`'s `fb_en`,
registered as `fb_en <= ~vga_flags[2] && |vga_flags[1:0]`) is set — and `vga_flags[2]` is the
real Attribute Controller "256-color" bit (`attrib_pelclock_div2`, AC index 0x10 bit 6, a
genuine standard-VGA register bit that real mode-13h BIOS init always sets to 1), so `fb_en` is
architecturally **always 0** for any palette-indexed mode (mode 13h, 16-color, text). On that
"else" branch `DDRAM_WE`/`DDRAM_RD` are never asserted at all — the plane BRAM has no
Avalon/HPS-bridge port, so nothing this tooling can reach.

**This session's job was to empirically validate (not just statically trust) that RTL trace on
the real rig, using the already-built, already-proven `CCEXP3.COM`, then apply whatever
fix actually works.**

Rig session: LOCK `ccmdl-exp4-translation-validate` acquired on a free/`NOLOCK` rig (core was
`menu.rbf`). Pre-run md5 baseline of `D:/Tools/CCMDL/*` recorded (matches EXP3's own values
exactly, confirming no drift since EXP3): `CCEXP1.COM`=`ec33fef3e0db0ec0e61bab252b12f657`,
`CCEXP2.COM`=`c7c0a6c761ac5ac958a13c134a704c16`, `CCEXP3.COM`=`e5cc07cb95667d9fe6d4db6275fb5bd4`,
`CCMDL.COM`=`c91bfbf855548f9b8884bcf3762ede5a`, `CCMDLDBG.COM`=`bc9bf774d48c477aa5199537158d819e`,
`SOLDIER.MDL`=`5b6c30a984872b4273dd5861412d35c5`.

**Step 1 — re-run CCEXP3.COM fresh and test the one concrete address-translation candidate.**
Loaded the existing `_Test/ao486_ccexp3_75.mgl` (already deployed, additive, from EXP3) on
`ao486_fpu_75mhz_20260626`. Confirmed live: BDA `0x449`=`0x13` (mode 13h active), FS-segment
mirror `MARK_DS`@`0xAFA22`=`0x0575` (same PSP segment as EXP3, reproducible boot state),
`MARK_BEFORE`@`0xAFA24`=`0xAA` (visible — written *before* `set_mode13`, while the Graphics
Controller still holds text mode's Memory Map Select, i.e. `vga_rgn` is false for `0xA0000` at
that point so it's an ordinary DDR3/`ram_rgn` write, hence HPS-visible — matches EXP1/EXP2's
"M1/M2/M3 visible" pattern exactly and gives an independent, freshly-observed confirmation of
*why* those early markers are visible while later ones aren't). `MARK_AFTER`@`0xAFA25` (the
convenience mirror of `exp1_after`, written *after* `set_mode13` — i.e. once Map Select=01 is
programmed and `vga_rgn` is genuinely true for `0xA0000`-range addresses) read back **`0x00`**
via `guest_peek.py`, not the `0xBB` the guest itself is known (from EXP1/EXP2/EXP3) to have
written — an exact repeat of the M3b-onward pattern, now explained precisely rather than just
observed. Baseline re-check: `guest_peek.py 0xA0000 16` = all zero (reproduces EXP3 fresh, not
just cited).

Built and ran a small standalone candidate-translation test (no new files needed beyond an
inline computation + `guest_peek.py`): the *only* other DDR3 location this data could
conceivably reach is the `VGA_FB_EN=1` "framebuffer mirror" path's `ram_addr[24:13] <=
{6'b111110, VGA_WR_SEG}` segment select (`l2_cache.v:317-318`). `VGA_WR_SEG` (`vga_wr_seg` in
`rtl/soc/vga.v`, sourced from `seg_wr`, a real but VESA-bank-select-only register at IO ports
0xB/0xD that mode-13h BIOS never touches) is `0` at reset and stays `0` for the whole CCEXP3
run. Computing the resulting DDR3 byte address for `guest_pa 0xA0000` (13-bit-aligned, so the
low field contributes 0) gives **guest_pa `0x3E00000`** (`{6'b111110,6'b0}<<13` word-address,
×2 for the 16-bit DDRAM interface). Read via `guest_peek.py 0x3E00000 16` → **all zero**; a
64KB scan `guest_peek.py 0x3E00000 0x10000` → **0/65536 nonzero, 0 occurrences of `0x77`**. This
candidate translation does **not** find the byte either — consistent with the RTL trace (this
path is provably unreachable anyway, since `VGA_FB_EN=0` means the entire `if(VGA_FB_EN)` branch
that sets this segment and asserts `ram_we` is never taken for mode-13h writes in the first
place — this was a due-diligence completeness check, not an expected hit).

**Verdict on Step 1: the proposed address-translation/permutation fix does NOT pan out.**
Consistent with the investigation's own `proposed_fix` conclusion ("There is no
address-formula/permutation fix possible on the tooling side"), now independently confirmed two
ways: (a) a fresh, non-cached live rig test of the only plausible alternative DDR3 location
(`0x3E00000`) found nothing, and (b) a deeper RTL re-trace (this session, not just re-citing
EXP3/the prior investigation) shows the write-routing gate (`vga_rgn`, driven by the guest's own
Graphics Controller Memory Map Select register) and the real pixel-scanout's read-routing gate
are **the same register** — so any register-poke that would divert mode-13h writes back into
`ram_rgn`/DDR3 (e.g. reprogramming Map Select to exclude `0xA0000` from `vga_rgn` while still
writing chain4 pixel data there) would simultaneously stop those writes from ever reaching the
plane BRAM the real scanout reads from — i.e. it would make the *real on-screen picture* worse
(genuinely blank) in exchange for making the *peek* see stale/diverted data. That is not a valid
observation method; it changes ground truth rather than revealing it. **There is no software-only
way to make `/dev/mem` see the same bytes that feed the real VGA output for mode 13h on this
core.** This was tried and explicitly does not work — reported honestly rather than forcing a
false success, per the task's own instruction.

**Step 2 — since no translation exists, implemented the tooling-only fix (`proposed_fix` option
3) instead of the RTL rebuild (option 1, needs Quartus + reflash, out of scope this session) or
analog capture (option 2, no capture hardware available).** Edited (in place, low-risk/additive
change only — new stderr/console warnings, zero change to read mechanics or return values):
- `C:/LLM/MiSTer/AO486/tools/analyze/guest_peek.py`: added `warn_if_vga_aperture()`, a pure
  stderr warning (never touches stdout's binary byte stream) that fires whenever the requested
  `[pa, pa+length)` range overlaps `0xA0000-0xBFFFF`, explaining the RTL mechanism and pointing
  at this EXP3/EXP4 writeup. Verified on-rig: fires for `guest_peek.py 0xA0000 16` (the VGA
  range), stays silent for `guest_peek.py 0x449 1` (BDA, a proven-working non-VGA read) — i.e.
  every other existing use of this tool (BDA, program data, etc.) is provably unaffected.
- `C:/LLM/MiSTer/AO486/tools/analyze/vga_mode13_screenshot.py`: added (a) a large docstring
  section spelling out the full RTL mechanism and why an all-zero capture is not evidence of a
  blank screen, (b) a runtime `[WARNING]` banner printed before the capture whenever
  `--guest-addr`/size overlaps the VGA aperture (true by default, since this tool's only
  purpose is the `0xA0000` mode-13h frame), and (c) a second `[WARNING]` block appended after
  the `[stats]` line specifically when the capture comes back all-zero, stating plainly that
  this is the tool's expected blind-spot output, not proof of a blank screen.

**Step 3 — re-ran the fixed `vga_mode13_screenshot.py` against a fresh, real `CCMDL.COM
SOLDIER.MDL` session** (loaded `_Test/ao486_ccmdl75.mgl`, already-existing/proven MGL — no new
rig files needed) to get the actual, now-honestly-labeled answer to the original question.
Output (abbreviated): the new top-of-run `[WARNING]` banner fired correctly, the capture
proceeded exactly as before (`[capture] got 64000 bytes`), decoded to
`dumps/ccmdl_verify_20260701.png` — **`[stats] nonzero-index bytes: 0/64000 (0%)`** — and the new
bottom-of-run `[WARNING]` block fired, correctly labeling this as the tool's known blind spot
rather than a "blank screen" finding. This is the *identical raw result* as every prior capture
in this investigation (expected — nothing about the underlying observability changed, only the
honesty of the tool's own reporting did).

**Answer to the original question ("does the soldier model actually render on real hardware?"):
STILL UNCONFIRMED, and — given the RTL trace above — cannot be confirmed by any `/dev/mem`-based
tool on this core, full stop.** This is not a gap in this session's effort; it's a structural
limit of the observation mechanism this entire investigation (guest_peek.py /
vga_mode13_screenshot.py / EXP1-EXP4) has used from the start. What IS now fully settled:
- The guest's own CPU writes to the mode-13h framebuffer succeed (EXP3, reconfirmed structurally
  by this session's RTL trace of the *same* register that gates both the write gets diverted
  and where the real scanout reads from — i.e. whatever the guest itself computes and writes
  chain4-style *is* what the real scanout hardware reads on its port B, physically wired to the
  same plane BRAM the CPU's port A just wrote — this is a stronger statement than EXP3 alone
  could make, since EXP3 only proved the CPU's own view was self-consistent, not that the
  scanout reads the same underlying memory; this session's RTL read of `rtl/soc/vga.v`'s
  `dpram_difclk` instantiation confirms port A (CPU/VGA bus) and port B (pixel scanout) are the
  *same physical BRAM instance*, so there is no plausible separate hardware path by which the
  CPU's writes could be visible to itself but not to the scanout).
- Therefore the balance of RTL evidence now actually *favors* "the soldier model probably does
  render correctly on the real analog VGA output" (the CPU writes definitely land in the exact
  BRAM the scanout reads), but this is still an inference from RTL topology, not a direct
  observation, and this investigation explicitly declines to report it as a confirmed "yes"
  without either (a) real analog-VGA capture hardware, or (b) an RTL change that mirrors
  legacy-mode VGA writes into DDR3 (broadening `fb_en`'s gate or adding a parallel shadow-write)
  followed by a Quartus rebuild + reflash — neither available in this session.
- The tooling itself (`guest_peek.py`, `vga_mode13_screenshot.py`) is now fixed to say so loudly
  instead of silently implying "blank screen" — this is the concrete, shippable, verified-working
  deliverable of this session.

Rig etiquette followed: LOCK `ccmdl-exp4-translation-validate` written before starting (rig was
`NOLOCK`/free); **zero new files deployed to the rig** (this session was pure `/dev/mem` reads
against already-existing, already-proven MGLs/images from EXP1-EXP3 plus the stock
`ao486_ccmdl75.mgl` — no writes, no new floppy/VHD images, no core rebuild); post-run md5 of
`D:/Tools/CCMDL/*` re-verified identical to the pre-run baseline above (byte-for-byte, all 6
files); core returned to `menu.rbf`; NOLOCK written on completion. All code changes in this
section are local-workstation Python edits (`guest_peek.py`, `vga_mode13_screenshot.py`), not
rig deploys.

## UPDATE (2026-07-01, later): real analog-VGA capture contradicts "probably renders fine" — and the FSINCOS anomaly is now resolved to a real bug, static-analysis-only pass

**1. User-reported real hardware observation.** The user directly viewed CCMDL's actual
output via real analog VGA capture on the exact core this investigation used
(`ao486_fpu_75mhz_20260626`) — **not solid black**. The screen shows partial/garbled content
"coming in over the screen" that "looks pretty wrong" (user's words): CCMDL is drawing
*something* nonzero, but it is not a clean render of the soldier model. This falsifies the
speculative closing inference of EXP4 ("the balance of RTL evidence now actually favors...the
soldier model probably does render correctly on the real analog VGA output") — that inference
was a plausible-sounding extrapolation from RTL topology (CPU port and scanout port share the
same physical BRAM instance), not a direct observation, and it is now directly contradicted.
Importantly, EXP4's underlying RTL fact is NOT wrong (the CPU's writes and the scanout very
likely do read the same BRAM) — what was wrong was the unstated assumption that the CPU is
writing *correct* pixel data in the first place. A garbled-but-nonzero screen is exactly what
you would expect if the CPU faithfully writes whatever its own (buggy) rendering math computed
— which is precisely consistent with the FSINCOS finding below: `transform_verts` builds its
per-vertex rotation using `sinY`/`cosY` for literally every vertex, so a corrupted `sinY` would
send every vertex to nonsensical screen coordinates, plausibly producing scrambled-looking
triangles rather than either a clean soldier or a perfectly empty/black frame.

**2. FSINCOS verdict (this task, static-analysis-only, no rig access).** Re-examined the
long-open `sinY` anomaly (EXP1: moved off 0.0, exact value not recorded; EXP2: `960.877` at
guest_pa `0x68BB`; EXP3: `-94.8388` — bytes `73 AD BD C2` LE — at guest_pa `0x68CD`) against the
actual source (`cmdl.asm`/`cmdl_exp1/2/3.asm`) and a fresh, independent rebuild of the exact
experiment binaries.

- **Ruled out: "sinY is a scaled/derived quantity."** `update_angles` is `fld dword [angY] /
  fsincos / fstp dword [cosY] / fstp dword [sinY]` — a direct, unscaled store straight off the
  FPU stack, with no multiply/add anywhere near it. `sinY` is later consumed directly as a
  rotation-matrix component in `transform_verts`. There is no scale constant involved; this part
  of the original hypothesis space is definitively wrong per the source.
- **Ruled out: "different sample point in the animation, so a different (valid) angle is
  expected."** `angY` is a compile-time-fixed constant (`dd 0.6`), `dAngY=0.0` by default
  (auto-spin is OFF unless Space is pressed), and none of EXP1/2/3's headless rig runs ever
  injected a keystroke (the `.frame` loop's key-check path is present but never triggered) — so
  the angle fed to `fsincos` is bit-identical, frame after frame, run after run, in all three
  experiments. There is no time-varying angle to blame this on.
- **More fundamentally: this defense could never have worked anyway.** `sin(x) ∈ [-1, 1]` for
  *any* real, finite `x`, regardless of what angle was sampled or when. `960.877` and `-94.8388`
  are not "a different but valid sine value" — they are outside the mathematically possible
  range for a correct `FSINCOS` result for *any* input. This is exactly the bar this task itself
  set for "conclusive evidence of an actual problem," and both recorded readings clear it.
- **Ruled out: a repeat of the "tooling reads the wrong address" bug class** (the same failure
  mode already found for the VGA framebuffer elsewhere in this investigation). Independently
  re-derived `sinY`'s guest-physical address from scratch — fresh `nasm -f bin` reassembly of
  `cmdl_exp1.asm`/`cmdl_exp2.asm`/`cmdl_exp3.asm` (WSL nasm 2.16.01, byte-for-byte reproducible),
  located the unique `9A 99 19 3F` (`0.6f` LE) bit pattern marking `angY` directly in each
  compiled `.COM`'s raw bytes, and computed the runtime DS-offset as
  `file_offset + 0x100` (the `.COM` load-time org shift, exactly the formula documented in
  `cmdl_exp1.asm`'s own comment block). Result: **every ground-truth offset this investigation
  used — `exp1_before`, `exp1_after`, `sinY`, `loaded_idx`, `exp3_readback`, in all of
  EXP1/EXP2/EXP3 — reproduces exactly**, matching the doc's own claimed values digit-for-digit
  (e.g. `sinY`: EXP1/EXP2 DS-offset `0x116B`, EXP3 `0x117D`). `sinY`'s address is correct; the
  anomalous values are genuinely what is stored there.
- **Corroborating context from the wider AO486 FPU RTL effort** (`C:\LLM\MiSTer\AO486\`):
  `research/design_transcendentals.md` explicitly flags the shared trig range-reduction kernel
  (used by FSIN/FCOS/FSINCOS/FPTAN) as the highest-risk slice of the whole transcendental group
  ("the hard part... the classic Pentium FSIN near π issue"). The actual RTL
  (`repos/ao486_decfix/rtl/ao486/fpu/fpu_transcendental.v`) implements `FSINCOS` as a real,
  non-trivial poly-evaluation engine (`sin_arr`/`cos_arr` Horner tables) behind a 128-bit-π
  3-part range-reduction + quadrant-select front end — not a stub — and confirms the
  out-of-range/C2 path only triggers for `|x| >= 2^63`, far above `0.6`, so this bug (if real) is
  in the ordinary/common computation path, not an edge case. Separately, the project's sibling
  software FPU (`Q87`, per `C:\LLM\DOS\HANDOFF.md`) had a real, only-just-fixed (same day,
  2026-07-01) rounding bug in exactly this class of kernel ("`fmul80`/`fadd80`/`fdiv80` were
  truncating instead of rounding... compounding through the transcendental series"). None of
  this is direct proof for THIS RTL's `FSINCOS`, but it establishes that transcendental
  range-reduction/poly kernels are a recurring, acknowledged soft spot across this project's FPU
  work, not a wildly implausible place for a bug to live.

**Verdict: (a) — genuine FSINCOS/FPU correctness issue**, not a wrong assumption and not a
repeat tooling bug. Confidence is HIGH that something is producing mathematically invalid
results (points 1-4 above are conclusive on their own, independent of any RTL access). Confidence
in the EXACT internal mechanism (a bug in the trig poly/range-reduction datapath itself, vs. some
other FPU-state corruption — e.g. stale tag-word/register-file leakage from an earlier FPU op in
CCMDL's own `parse_model` burst, a pattern this same AO486 project has chased for other ops
elsewhere in its iteration log) is MEDIUM, since this pass did not run an RTL simulation of
`FSINCOS(0.6)` to catch the exact divergence point — that would need rig/sim access this task
was scoped not to touch.

**Recommended follow-up experiment, once the rig is free** (minimal, decisive, does not require
resolving the VGA-aperture-observability gap first):
1. **Determinism probe (highest priority, cheapest)**: build a variant that calls `FSINCOS` on
   the identical `0.6` input *twice* within the same frame with zero intervening FPU state change
   (e.g. immediately after the existing `update_angles`, redo `fld dword [angY] / fsincos / fstp
   dword [sinY_probe2] / fstp st0` into a second own-DS location) and compare `sinY` vs.
   `sinY_probe2` in the same sample. If they differ, the bug is state/timing-dependent (e.g. a
   residual register-file/tag leak), not a fixed mis-computation of `0.6` itself — otherwise, if
   they agree bit-for-bit, re-run the *same* binary across a couple of fresh boots and compare
   across boots (deterministic-but-wrong hardware math vs. boot-order-dependent corruption).
2. **Isolation probe**: a minimal `.COM` doing only `finit / fld dword [c_0.6] / fsincos / fstp
   [r_cos] / fstp [r_sin]` — no file I/O, no mode-13h switch, no rendering — run on the same
   `ao486_fpu_75mhz_20260626` core, to determine whether `FSINCOS` is broken in total isolation,
   or whether some earlier FPU op in CCMDL's own boot path (the one non-transcendental FPU burst
   in `parse_model` computing `sAdjX/Y/Z`) is leaving corrupted FPU state that only then poisons
   the subsequent `fsincos` call.
3. Worth also capturing EXP1's exact `sinY` bytes (only "moved off 0.0" was recorded, not the
   value) for a 3-way comparison against EXP2's `960.877` and EXP3's `-94.8388` — if all three
   differ from each other under the identical `0.6` input, that alone would be strong,
   self-contained evidence of non-determinism without needing a dedicated new experiment.
