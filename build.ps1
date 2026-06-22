param(
    [ValidateSet("min","std","full")]
    [string]$Profile = "std",
    [switch]$All
)
$ErrorActionPreference = "Stop"
$dir  = "C:\LLM\cc"
$nasm = "C:\Users\Caldor\AppData\Local\bin\NASM\nasm.exe"   # same path run_test.ps1 uses
if (-not (Test-Path $nasm)) { $nasm = "nasm" }              # fall back to PATH

# ----------------------------------------------------------------------------
#  Profile table.  Each profile selects a NASM -d<FLAG> define and carries its
#  own budget.  The FEAT_* flags don't exist in cc.asm yet (added in a later
#  M1 step); passing -dFEAT_x to a file that never references it is harmless,
#  so this script builds and reports sizes today regardless.
#
#  Budgets (ROADMAP.md section 4):
#    min  : emitted code <= 5 KB
#    std  : emitted code <= 13 KB  AND  resident < 60 KB   (default, -> cc.com)
#    full : resident < 63 KB  (hard wall; leaves stack/PSP slack in the 64 KB seg)
# ----------------------------------------------------------------------------
$KB = 1024
$profiles = @{
    min  = @{ Flag="FEAT_MIN";  Out="ccmin.com";  CodeMax=(5*$KB);  ResMax=$null }
    std  = @{ Flag="FEAT_STD";  Out="cc.com";     CodeMax=(13*$KB); ResMax=(60*$KB) }
    full = @{ Flag="FEAT_FULL"; Out="ccfull.com"; CodeMax=$null;    ResMax=(63*$KB) }
}

# ----------------------------------------------------------------------------
#  Resident-size mechanism (the key subtlety).
#
#  With `nasm -f bin`, the `.bss` section is `nobits` (resb/resw) and is NOT
#  emitted into the .COM file.  So (Get-Item cc.com).Length is ONLY the
#  code+initialized-data and badly under-reports the true resident footprint.
#  The real resident image is what `start` shrinks the PSP block to
#  (cc.asm ~line 128): `mov ax, prog_end`, where prog_end is the label sitting
#  after the whole .bss block (panelL/panelR/viewbuf/snapbuf/stack/...).
#
#  We recover that authoritative number from a NASM list file (-l):
#    resident = 0x100 (PSP/org)  +  emitted code/data bytes  +  .bss size
#  where .bss size = the running section-relative end of the .bss section.
#  In the listing every .bss line carries an 8-hex section-relative address;
#  large reservations also show `<res Nh>`.  Reservations are laid out
#  sequentially, so the .bss size = max(addr + res-size) over the section
#  (the final buffer fixes the end; stacktop/prog_end follow it immediately).
#  Verified against the immediate NASM bakes into `mov ax, prog_end`
#  (0xED2A = 60714) on the current cc.asm — they match exactly.
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
    $flag = $p.Flag
    $out  = Join-Path $dir $p.Out
    $lst  = Join-Path $dir ("_build_{0}.lst" -f $name)

    Write-Host ("==== profile {0}  (-d{1} -> {2}) ====" -f $name, $flag, $p.Out)

    & $nasm -f bin "-d$flag" "$dir\cc.asm" -o $out -l $lst 2>&1 | Write-Host
    if ($LASTEXITCODE -ne 0) {
        Write-Host ("  NASM FAILED (exit {0})" -f $LASTEXITCODE)
        return $false
    }

    $code     = (Get-Item $out).Length            # emitted code+data (NOT resident)
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

    Write-Host ("  RESULT       : {0}" -f $(if ($ok){"PASS"}else{"FAIL"}))
    return $ok
}

$targets = if ($All) { @("min","std","full") } else { @($Profile) }
$allOk = $true
foreach ($t in $targets) {
    if (-not (Build-Profile $t)) { $allOk = $false }
    Write-Host ""
}

if (-not $allOk) { Write-Host "BUILD FAILED (budget overflow or NASM error)"; exit 1 }
Write-Host "BUILD OK"
exit 0
