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
```

- `-Base std` starts from the full widget set; `-Base min` from the bare core.
- `-Add` / `-Remove` adjust that base; `-Only` specifies the whole set explicitly.
- Hard dependencies are pulled in automatically (e.g. `CLOCK` needs `WIDGETS`,
  `VFS`/`VIEW` need `INI`), so any selection links.

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

Each `@cost` feeds a running **preview** total. The **authoritative** number is
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
distribution is just **cc's sources + NASM**. NASM ships a 16-bit DOS build, so
the configurator concept works on the target itself: drop the `mod/` tree,
`cc.asm`, and `nasm.exe` (DOS) on the machine and rebuild a tailored `cc.com`
in place. On the dev host, `configure.ps1` drives the same NASM you already use.
