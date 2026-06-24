<#
  tools/measure.ps1 -- shared resident-size measurement for cc builds.

  Dot-source this (`. "$dir\tools\measure.ps1"`) to get Get-BssSize and
  Measure-Resident. build.ps1 keeps its own inlined copy of the same algorithm
  (it is the canonical builder and intentionally has no external dependency);
  configure.ps1 and run_configurator.ps1 use these so their numbers are derived
  by the identical method and therefore agree with build.ps1.

  The mechanism (see build.ps1's long comment): with `nasm -f bin` the .bss
  section is nobits and not emitted, so the .COM file length under-reports the
  true footprint. The resident image is 0x100 (PSP/org) + emitted bytes + the
  .bss size, where .bss size = max(addr + <res N>) over the .bss section in a
  NASM list file (-l). Verified against the `mov ax, prog_end` immediate.
#>

function Get-BssSize([string]$lstPath) {
    $inbss = $false; $lastEnd = 0
    foreach ($ln in [System.IO.File]::ReadLines($lstPath)) {
        if ($ln -match '^\s*\d+\s+section\s+\.bss\b') { $inbss = $true; continue }
        if ($inbss -and $ln -match '^\s*\d+\s+section\s+' -and $ln -notmatch '\.bss') { $inbss = $false }
        if (-not $inbss) { continue }
        if ($ln -match '^\s*\d+\s+([0-9A-Fa-f]{8})\b') {
            $addr = [Convert]::ToInt32($matches[1], 16); $size = 0
            if ($ln -match '<res ([0-9A-Fa-f]+)h?>') { $size = [Convert]::ToInt32($matches[1], 16) }
            $end = $addr + $size
            if ($end -gt $lastEnd) { $lastEnd = $end }
        }
    }
    return $lastEnd
}

# Trial-assemble cc.asm with the given NASM define args and return a hashtable
# @{ ok; code; resident; out }. The .COM is left at -Out (caller may keep or
# delete it). On NASM failure ok=$false and the rest are 0.
function Measure-Resident {
    param(
        [string]$Nasm,
        [string]$Dir,
        [string[]]$Defs,
        [string]$Out
    )
    $lst = [System.IO.Path]::ChangeExtension($Out, ".lst")
    & $Nasm -f bin @Defs "$Dir\cc.asm" -o $Out -l $lst 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        if (Test-Path $lst) { Remove-Item $lst -Force -ErrorAction SilentlyContinue }
        return @{ ok = $false; code = 0; resident = 0; out = $Out }
    }
    $code     = (Get-Item $Out).Length
    $bss      = Get-BssSize $lst
    $resident = 0x100 + $code + $bss
    Remove-Item $lst -Force -ErrorAction SilentlyContinue
    return @{ ok = $true; code = $code; resident = $resident; out = $Out }
}
