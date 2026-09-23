# Building a custom Claude Commander (the configurator)

`cc` is one flat 16-bit real-mode `.COM`. There is no runtime plugin loader —
DOS has no DLLs in the single 64 KB segment a `.COM` lives in. Instead, every
optional "widget" is a compile-time module (`mod/*.inc`) gated by a `-dFEAT_*`
NASM define. **The way you add or remove a widget is to re-assemble** with a
different feature set. `configure.ps1` is the picker that does this for you, and
the resident size scales with exactly what you choose.

## Quick start

```powershell
.\configure.ps1 -List                                  # show every widget + its cost
.\configure.ps1 -Base std -Remove CLOCK,LANG -Out cc-lean.com
.\configure.ps1 -Base min -Add SORT,COLS,VIEWS,HELP -Out cc-tiny.com
.\configure.ps1 -Only WIDGETS,CLOCK,FREE,SORT,VIEWS  -Out cc-bare.com
.\configure.ps1 -Base std -Add TOOLS_INI -Remove LANG,LFN,RESULTS -Out ccuser.com
```

- `-Base std` starts from the STD tier (every widget except the opt-in ones,
  e.g. `DISCOVER`, `TOOLS_INI`); `-Base min` from the bare core.
- `-Add` / `-Remove` adjust that base; `-Only` specifies the whole set explicitly.
- Hard dependencies are pulled in automatically (e.g. `CLOCK` needs `WIDGETS`,
  `VFS`/`VIEW` need `INI`), so any selection links.
- `TOOLS_INI` adds runtime `[tools]` rows to the Tools menu, but the full STD
  set plus `TOOLS_INI` is over the resident wall. The example above trims
  language/LFN/results-panel support to make room for user batch tools.

## Where the catalogue comes from

The picker is **not** a hand-maintained list. It scans the `@feature` manifest
block at the top of each `mod/*.inc`:

```asm
; @feature CLOCK
; @title   live HH:MM:SS clock on the command row
; @needs   WIDGETS
; @cost    95            ; approx own resident bytes -- PREVIEW ONLY
```

So the picker can never drift from the modules that actually exist. To add a new
widget, drop a `mod/foo.inc` with a manifest header and a `%ifdef FEAT_FOO`
`%include` in `cc.asm`; it appears in the picker automatically.

## The size budget

Each `@cost` feeds a running **preview** total on top of the measured core
floor (a trial assemble with no widgets). The **authoritative** number is
the trial assemble the configurator does at the end: it reports the real resident
image (`0x100` PSP + emitted bytes + `.bss`) and whether it fits the 63 KB wall.
Never trust `@cost` for the gate — it is a hint; the trial assemble is the truth,
and it also catches any missing dependency (a bad set simply fails to link).

## Self-test

`run_configurator.ps1` proves the picker can't silently diverge from the
canonical builds: it reproduces the MIN / STD / FULL tiers (defined in `cc.asm`)
and the CCPOP variant (defined in `package.ps1`) and asserts each is
**byte-identical** to the configurator's output, then `/T`-smokes each binary.
Run it after touching `configure.ps1`, a manifest, or the tier block.

```powershell
.\run_configurator.ps1            # byte-equality + DOSBox /T smoke
.\run_configurator.ps1 -NoSmoke   # byte-equality only (no DOSBox)
```

## Shipping it as a "compiler installation"

Because customizing `cc` means re-assembling, a self-contained customizable
distribution is just **cc's sources + NASM**. NASM's DOS build is a 32-bit
DJGPP program (it needs a 386+ and a DPMI host such as `CWSDPMI.EXE`), but the
`.COM` it produces is the same, so the concept works on the target itself: drop
the `mod/` tree, `cc.asm`, and `nasm.exe` (DOS) on the machine and rebuild a
tailored `cc.com` in place. That is what `cc-installer.zip` (made by
`build_dist.ps1`) ships, with `INSTALL.BAT` choosing between the canonical
variants — see `BUILDING.TXT`.

`configure.ps1` itself is PowerShell and runs on the dev host only. On DOS,
remember that COMMAND.COM caps a command line at 127 characters, so a long
`-dFEAT_CUSTOM -dFEAT_X ...` list will not fit: put the `%define FEAT_X` lines
in a small wrapper that ends in `%include "cc.asm"` (as `ccpop.asm` does) and
assemble the wrapper instead.
