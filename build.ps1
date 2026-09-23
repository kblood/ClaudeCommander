param(
    [string[]]$Profile = @("std"),      # min|std|full|lfn; several: -Profile std,lfn
    [switch]$All
)
$ErrorActionPreference = "Stop"
$dir  = $PSScriptRoot                                       # works from any cwd
$nasm = "C:\Users\Caldor\AppData\Local\bin\NASM\nasm.exe"   # same path run_test.ps1 uses
if (-not (Test-Path $nasm)) { $nasm = "nasm" }              # fall back to PATH

# ----------------------------------------------------------------------------
#  Profile table.  Each profile selects NASM -d<FLAG> define(s) (the tier
#  block near the top of cc.asm maps FEAT_MIN/STD/FULL to a feature set) and
#  carries its own budget.
#
#  Budgets (ROADMAP.md section 4):
#    min  : emitted code <= 9 KB
#    std  : emitted code <= 19 KB AND resident < 63 KB   (default, -> cc.com)
#    full : resident < 63.5 KB (hard wall; leaves stack/PSP slack in the 64 KB seg)
#    lfn  : std + FEAT_LFN_FULL (-> cc-lfn.com): resident < 63 KB only.  The
#           std code budget exists to protect the resident budget (code is part
#           of the resident image); the extra LFN_FULL code is accounted for by
#           the resident check, so no separate code cap is enforced here.
#
#  Since the xseg change (2026-09) the big modal buffers -- the F3 pager text
#  (VIEW_MAX), its line table (MAX_VLINES words) and the results path heap
#  (RESHEAP_MAX) -- live in a separately DOS-allocated far segment reached via
#  FS (cc.asm "XSEG LAYOUT", placed before `section .bss` so the scan below
#  does not count it).  "resident" here is the 64 KB PROGRAM SEGMENT only; the
#  xseg block (13,312 B in std, 10,240 B in min) is extra conventional memory
#  that is not bounded by the 64 KB wall.  The std code cap is unchanged: it
#  still fits, and resident is now ~13 KB under the wall.
# ----------------------------------------------------------------------------
$KB = 1024
$profiles = @{
    min  = @{ Flags=@("FEAT_MIN");                 Out="ccmin.com";  CodeMax=(9*$KB);  ResMax=$null }
    std  = @{ Flags=@("FEAT_STD");                 Out="cc.com";     CodeMax=(19*$KB); ResMax=(63*$KB) }
    full = @{ Flags=@("FEAT_FULL");                Out="ccfull.com"; CodeMax=$null;    ResMax=(63.5*$KB) }
    lfn  = @{ Flags=@("FEAT_STD","FEAT_LFN_FULL"); Out="cc-lfn.com"; CodeMax=$null;    ResMax=(63*$KB) }
}

# Run NASM; echo its output; return its exit code.  Success is decided by the
# exit code ONLY: under Windows PowerShell 5.1, EAP=Stop + 2>&1 turns any
# stderr line (e.g. a harmless NASM warning) into a terminating error, so the
# preference is relaxed inside this function.
function Invoke-Nasm {
    $ErrorActionPreference = "Continue"
    $PSNativeCommandUseErrorActionPreference = $false
    & $nasm @args 2>&1 | ForEach-Object { Write-Host "  $_" }
    return $LASTEXITCODE
}

# ----------------------------------------------------------------------------
#  Resident-size mechanism (the key subtlety).
#
#  With `nasm -f bin`, the `.bss` section is `nobits` (resb/resw) and is NOT
#  emitted into the .COM file.  So (Get-Item cc.com).Length is ONLY the
#  code+initialized-data and badly under-reports the true resident footprint.
#  The real resident image is what `start` shrinks the PSP block to
#  (cc.asm, the entry point): `mov ax, prog_end`, where prog_end is the label
#  sitting after the whole .bss block (panels/view buffers/stack/...).
#
#  We recover that authoritative number from a NASM list file (-l):
#    resident = 0x100 (PSP/org)  +  emitted code/data bytes  +  .bss size
#  where .bss size = the running section-relative end of the .bss section.
#  In the listing every .bss line carries an 8-hex section-relative address;
#  large reservations also show `<res Nh>`.  Reservations are laid out
#  sequentially, so the .bss size = max(addr + res-size) over the section
#  (the final buffer fixes the end; stacktop/prog_end follow it immediately).
#  Cross-check: the result equals the immediate NASM bakes into
#  `mov ax, prog_end` (visible in a -l listing) -- re-verify that if the .bss
#  layout conventions ever change.
#
#  We don't use NASM's `[map]` (a source directive we may not add) nor read the
#  `mov ax, prog_end` immediate at a fixed file offset (fragile if code moves);
#  the list-file scan depends only on the .bss layout, not on instruction
#  placement.
# ----------------------------------------------------------------------------
function Get-BssSize([string]$lstPath) {
    $inbss = $false
    $lastEnd = 0
    foreach ($ln in [System.IO.File]::ReadLines($lstPath)) {
        if ($ln -match '^\s*\d+\s+section\s+\.bss\b') { $inbss = $true; continue }
        if ($inbss -and $ln -match '^\s*\d+\s+section\s+' -and $ln -notmatch '\.bss') { $inbss = $false }
        if (-not $inbss) { continue }
        if ($ln -match '^\s*\d+\s+([0-9A-Fa-f]{8})\b') {
            $addr = [Convert]::ToInt32($matches[1], 16)
            $size = 0
            if ($ln -match '<res ([0-9A-Fa-f]+)h?>') { $size = [Convert]::ToInt32($matches[1], 16) }
            $end = $addr + $size
            if ($end -gt $lastEnd) { $lastEnd = $end }
        }
    }
    return $lastEnd
}

function Build-Profile([string]$name) {
    $p    = $profiles[$name]
    $defs = @($p.Flags | ForEach-Object { "-d$_" })
    $out  = Join-Path $dir $p.Out
    # Assemble to a temp file; it replaces $out only if NASM succeeds AND the
    # budgets pass, so a failed build never deletes or overwrites a good binary.
    $tmp  = Join-Path ([System.IO.Path]::GetTempPath()) ("cc_build_{0}_{1}.com" -f $name, $PID)
    $lst  = [System.IO.Path]::ChangeExtension($tmp, ".lst")

    Write-Host ("==== profile {0}  ({1} -> {2}) ====" -f $name, ($defs -join " "), $p.Out)

    # -i "$dir/" resolves cc.asm's mod/*.inc includes independent of the cwd.
    $rc = Invoke-Nasm -f bin -i "$dir/" @defs "$dir\cc.asm" -o $tmp -l $lst
    if ($rc -ne 0 -or -not (Test-Path $tmp)) {
        Write-Host ("  NASM FAILED (exit {0}) -- {1} left untouched" -f $rc, $p.Out)
        Remove-Item $tmp, $lst -Force -ErrorAction SilentlyContinue
        return $false
    }

    $code     = (Get-Item $tmp).Length            # emitted code+data (NOT resident)
    $bss      = Get-BssSize $lst                   # nobits reservations, parsed from -l
    $resident = 0x100 + $code + $bss               # PSP/org + emitted + .bss
    Remove-Item $lst -Force -ErrorAction SilentlyContinue

    $ok = $true
    Write-Host ("  emitted code : {0,7:N0} B  ({1:N1} KB)" -f $code, ($code/$KB))
    Write-Host ("  resident img : {0,7:N0} B  ({1:N1} KB)" -f $resident, ($resident/$KB))

    if ($null -ne $p.CodeMax) {
        if ($code -gt $p.CodeMax) { $ok = $false }
        Write-Host ("  code budget  : <= {0,6:N0} B  -> {1}" -f $p.CodeMax, $(if ($code -le $p.CodeMax){"PASS"}else{"FAIL"}))
    }
    if ($null -ne $p.ResMax) {
        if ($resident -ge $p.ResMax) { $ok = $false }
        Write-Host ("  resident bud : <  {0,6:N0} B  -> {1}" -f $p.ResMax, $(if ($resident -lt $p.ResMax){"PASS"}else{"FAIL"}))
    }

    if ($ok) {
        Move-Item $tmp $out -Force
    } else {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        Write-Host ("  over budget -- {0} left untouched" -f $p.Out)
    }
    Write-Host ("  RESULT       : {0}" -f $(if ($ok){"PASS"}else{"FAIL"}))
    return $ok
}

# (split on commas ourselves: `pwsh -File build.ps1 -Profile std,lfn` passes
#  one string, not an array)
$targets = if ($All) { @("min","std","full","lfn") } else {
    @($Profile | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
}
foreach ($t in $targets) {
    if (-not $profiles.ContainsKey($t)) { Write-Host "Unknown profile '$t' (valid: min, std, full, lfn)"; exit 1 }
}
$allOk = $true
foreach ($t in $targets) {
    if (-not (Build-Profile $t)) { $allOk = $false }
    Write-Host ""
}

if (-not $allOk) { Write-Host "BUILD FAILED (budget overflow or NASM error)"; exit 1 }
Write-Host "BUILD OK"
exit 0
