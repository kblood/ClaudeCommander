<#
  configure.ps1 -- a-la-carte build configurator for Claude Commander (cc).

  cc is one flat 16-bit .COM; its "widgets" are compile-time modules gated by
  -dFEAT_* flags. This script lets you pick exactly the widgets you want and
  assembles a custom cc.com whose resident size scales with that set -- the
  build-time equivalent of an installer that drops in only chosen widgets.

  It does NOT edit cc.asm. It passes -dFEAT_CUSTOM (which makes cc.asm skip its
  tier defaults) plus one -dFEAT_X per selected feature. cc.asm then resolves
  hard dependencies itself (e.g. CLOCK pulls WIDGETS, VFS pulls INI), so any
  selection assembles cleanly.

  The widget CATALOG is not hard-coded here: it is scanned from the `@feature`
  manifest blocks at the top of each mod/*.inc, so the picker can never drift
  from the modules that actually exist. A module's manifest looks like:

      ; @feature CLOCK
      ; @title   live HH:MM:SS clock on the command row
      ; @needs   WIDGETS
      ; @cost    95            ; approx own resident bytes -- PREVIEW ONLY

  The @cost numbers feed a running size PREVIEW; the AUTHORITATIVE size is the
  trial assemble at the end (which also catches any missing dependency, since a
  bad selection simply fails to link).

  USAGE
    .\configure.ps1 -List                                   # show the catalog
    .\configure.ps1 -Base std -Remove CLOCK,LANG,GREP -Out cc-lean.com
    .\configure.ps1 -Base min -Add SORT,COLS,VIEWS,HELP -Out cc-min-plus.com
    .\configure.ps1 -Only WIDGETS,CLOCK,FREE,SORT,VIEWS -Out cc-tiny.com
#>
param(
    [ValidateSet("min","std")]
    [string]$Base = "std",
    [string[]]$Add    = @(),
    [string[]]$Remove = @(),
    [string[]]$Only   = @(),
    [string]$Out = "cc-custom.com",
    [switch]$List,
    [switch]$Quiet              # suppress chatter; used by run_configurator.ps1
)
$ErrorActionPreference = "Stop"
$dir  = "C:\LLM\cc"
$nasm = "C:\Users\Caldor\AppData\Local\bin\NASM\nasm.exe"
if (-not (Test-Path $nasm)) { $nasm = "nasm" }
. "$dir\tools\measure.ps1"
$KB = 1024
$RES_WALL = 63 * $KB        # same std resident wall build.ps1 enforces

function Say($m) { if (-not $Quiet) { Write-Host $m } }

# ---- scan the @feature manifests in mod/*.inc ------------------------------
# Builds: $catalog (NAME -> title), $deps (NAME -> @(needs)), $cost (NAME -> int).
$catalog = [ordered]@{}
$deps    = @{}
$cost    = @{}
foreach ($f in (Get-ChildItem (Join-Path $dir "mod") -Filter *.inc | Sort-Object Name)) {
    $name = $null; $title = ""; $need = @(); $c = 0; $have = $false
    foreach ($ln in [System.IO.File]::ReadLines($f.FullName)) {
        if ($ln -match '^\s*;\s*@feature\s+(\S+)')   { $name = $matches[1].ToUpper(); $have = $true; continue }
        if (-not $have) {
            # stop scanning a file once real (non-comment, non-blank) code starts,
            # so we only read the leading manifest block.
            if ($ln -match '^\s*;' -or $ln -match '^\s*$') { continue } else { break }
        }
        if ($ln -match '^\s*;\s*@title\s+(.+?)\s*$') { $title = $matches[1] }
        elseif ($ln -match '^\s*;\s*@needs\s+(.+?)\s*$') { $need = ($matches[1] -split '\s+') | ForEach-Object { $_.ToUpper() } }
        elseif ($ln -match '^\s*;\s*@cost\s+(\d+)')  { $c = [int]$matches[1] }
        elseif ($ln -notmatch '^\s*;' -and $ln -notmatch '^\s*$') { break }   # end of manifest block
    }
    if ($have) {
        $catalog[$name] = $title
        if ($need.Count -gt 0) { $deps[$name] = $need }
        $cost[$name] = $c
    }
}
if ($catalog.Count -eq 0) { Write-Host "ERROR: no @feature manifests found under mod/."; exit 1 }

$stdSet = @($catalog.Keys)     # STD = every selectable feature; MIN = none.

if ($List) {
    Write-Host "Claude Commander widget catalog (scanned from mod/*.inc):`n"
    foreach ($k in $catalog.Keys) {
        $d = if ($deps.ContainsKey($k)) { "  (needs: " + ($deps[$k] -join ", ") + ")" } else { "" }
        Write-Host ("  {0,-8} ~{1,5} B  {2}{3}" -f $k, $cost[$k], $catalog[$k], $d)
    }
    Write-Host "`nExample: .\configure.ps1 -Base min -Add SORT,COLS,VIEWS,HELP -Out cc-tiny.com"
    exit 0
}

# ---- resolve the requested feature set -------------------------------------
function Norm([string[]]$xs) { $xs | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.ToUpper().Trim() -replace '^FEAT_','' } | Where-Object { $_ } }

if ($Only.Count -gt 0) {
    $set = [System.Collections.Generic.HashSet[string]]::new()
    Norm $Only | ForEach-Object { [void]$set.Add($_) }
} else {
    $start = if ($Base -eq "std") { $stdSet } else { @() }
    $set = [System.Collections.Generic.HashSet[string]]::new()
    $start | ForEach-Object { [void]$set.Add($_) }
    Norm $Add    | ForEach-Object { [void]$set.Add($_) }
    Norm $Remove | ForEach-Object { [void]$set.Remove($_) }
}

# validate names
$bad = @($set | Where-Object { -not $catalog.Contains($_) })
if ($bad.Count -gt 0) {
    Write-Host ("Unknown feature(s): {0}" -f ($bad -join ", "))
    Write-Host "Run  .\configure.ps1 -List  to see valid names."
    exit 1
}

# apply dependency closure (so the report and preview match what cc.asm builds)
$pulled = [System.Collections.Generic.List[string]]::new()
$changed = $true
while ($changed) {
    $changed = $false
    foreach ($f in @($set)) {
        if ($deps.ContainsKey($f)) {
            foreach ($need in $deps[$f]) {
                if (-not $set.Contains($need)) { [void]$set.Add($need); $pulled.Add("$need (for $f)"); $changed = $true }
            }
        }
    }
}

$selected = @($catalog.Keys | Where-Object { $set.Contains($_) })   # in catalog order
Say ("Selected {0} widget(s): {1}" -f $selected.Count, ($selected -join ", "))
if ($pulled.Count -gt 0) { Say ("  + auto-added dependencies: {0}" -f ($pulled -join ", ")) }

# ---- size PREVIEW from @cost (hint only; trial assemble below is the truth) -
$preview = 0x100 + 52928   # PSP + the MIN/core resident floor (CUSTOM-empty)
foreach ($f in $selected) { $preview += $cost[$f] }
$preview -= 0x100          # 52928 already includes PSP/core; avoid double count
Say ("`n  size preview : ~{0,7:N0} B resident  (sum of @cost hints over core floor)" -f $preview)

# ---- assemble (AUTHORITATIVE) ----------------------------------------------
$outPath = if ([System.IO.Path]::IsPathRooted($Out)) { $Out } else { Join-Path $dir $Out }
$defs = @("-dFEAT_CUSTOM") + ($selected | ForEach-Object { "-dFEAT_$_" })

Say ("`nnasm {0} cc.asm -> {1}" -f ($defs -join " "), (Split-Path $outPath -Leaf))
$m = Measure-Resident -Nasm $nasm -Dir $dir -Defs $defs -Out $outPath
if (-not $m.ok) {
    Write-Host "NASM FAILED -- this feature selection does not link."
    Write-Host "(a dependency may be missing from a module's @needs; the trial"
    Write-Host " assemble is exactly the gate that catches that.)"
    exit 1
}

Say ""
Say ("  output       : {0}" -f $outPath)
Say ("  emitted code : {0,7:N0} B  ({1:N1} KB)" -f $m.code, ($m.code/$KB))
Say ("  resident img : {0,7:N0} B  ({1:N1} KB)  <- authoritative" -f $m.resident, ($m.resident/$KB))
$fits = $m.resident -lt $RES_WALL
Say ("  fits 63 KB   : {0}  ({1:N0} B {2})" -f $(if($fits){"YES"}else{"NO"}), [math]::Abs($RES_WALL-$m.resident), $(if($fits){"to spare"}else{"OVER"}))
if (-not $fits) { Say "  (still loads if it stays under the 64 KB segment, but trim widgets to be safe)" }
Say ("`nDone. Run it with:  $((Split-Path $outPath -Leaf))")
exit 0
