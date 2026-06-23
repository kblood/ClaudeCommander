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

  USAGE
    # start from the full widget set and drop a few:
    .\configure.ps1 -Base std -Remove CLOCK,LANG,GREP -Out cc-lean.com

    # start from bare core and add exactly what you want:
    .\configure.ps1 -Base min -Add SORT,COLS,VIEWS,HELP -Out cc-min-plus.com

    # specify the entire set explicitly:
    .\configure.ps1 -Only WIDGETS,CLOCK,FREE,SORT,VIEWS -Out cc-tiny.com

    # just list the catalog and exit:
    .\configure.ps1 -List
#>
param(
    [ValidateSet("min","std")]
    [string]$Base = "std",
    [string[]]$Add    = @(),
    [string[]]$Remove = @(),
    [string[]]$Only   = @(),
    [string]$Out = "cc-custom.com",
    [switch]$List
)
$ErrorActionPreference = "Stop"
$dir  = "C:\LLM\cc"
$nasm = "C:\Users\Caldor\AppData\Local\bin\NASM\nasm.exe"
if (-not (Test-Path $nasm)) { $nasm = "nasm" }
$KB = 1024
$RES_WALL = 63 * $KB        # same std resident wall build.ps1 enforces

# ---- the widget catalog (label -> one-line description) --------------------
# Order = display order. "core" features (panel browser) need no flag and are
# always present; only the optional widgets below are selectable.
$catalog = [ordered]@{
    WIDGETS = "status-widget draw/tick seam (needed by CLOCK and FREE)"
    CLOCK   = "live HH:MM:SS clock on the command row"
    FREE    = "panel footer: file count / free space / tagged size"
    VIEWS   = "panel body view modes (brief 3-column; Ctrl-F10)"
    TREE    = "Alt-F10 modal directory-tree browser"
    SORT    = "sort by name/ext/size/date (Ctrl-F1..F4)"
    COLS    = "cycle the right column: size/date/time/attrs (Ctrl-F5)"
    SEARCH  = "incremental quick-search (Ctrl-F6)"
    MASK    = "tag/untag files by *.mask (Ctrl-F7/F8)"
    MENU    = "pop-up command menu (F9)"
    MENUBAR = "NC-style pull-down menu bar (F9; supersedes the MENU pop-up)"
    HELP    = "built-in help pager (F1, reads cc.hlp)"
    EDIT    = "F4 launches the CCEDIT external editor"
    FIND    = "Alt-F7 find files (CCFIND)"
    GREP    = "Alt-F8 search file contents (CCGREP)"
    ZIP     = "Ctrl-F9 list archive contents (CCZIP)"
    ATTR    = "Ctrl-A edit file attributes"
    VFS     = "browse archives (.zip/.d64/...) as folders"
    VIEW    = "[view] map: per-extension external viewers (F3)"
    INI     = "cc.ini / cc.lng config parsing (needed by several below)"
    LANG    = "translatable F-key bar (cc.lng)"
    LFN     = "long-filename display when an LFN provider is active"
}
# hard dependencies (mirror of the closure in cc.asm) -- used only to TELL the
# user what got pulled in; cc.asm enforces them regardless.
$deps = @{
    CLOCK = @("WIDGETS"); FREE = @("WIDGETS")
    VFS = @("INI"); VIEW = @("INI"); LANG = @("INI"); LFN = @("INI"); ATTR = @("INI")
}
# the STD set (everything); MIN = nothing optional.
$stdSet = @($catalog.Keys)

if ($List) {
    Write-Host "Claude Commander widget catalog:`n"
    foreach ($k in $catalog.Keys) {
        $d = if ($deps.ContainsKey($k)) { "  (needs: " + ($deps[$k] -join ", ") + ")" } else { "" }
        Write-Host ("  {0,-8} {1}{2}" -f $k, $catalog[$k], $d)
    }
    Write-Host "`nExample: .\configure.ps1 -Base min -Add SORT,COLS,VIEWS,HELP -Out cc-tiny.com"
    exit 0
}

# ---- resolve the requested feature set -------------------------------------
function Norm([string[]]$xs) { $xs | ForEach-Object { $_.ToUpper().Trim() -replace '^FEAT_','' } | Where-Object { $_ } }

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

# apply dependency closure (so the report matches what cc.asm will build)
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
Write-Host ("Selected {0} widget(s): {1}" -f $selected.Count, ($selected -join ", "))
if ($pulled.Count -gt 0) { Write-Host ("  + auto-added dependencies: {0}" -f ($pulled -join ", ")) }

# ---- assemble --------------------------------------------------------------
$outPath = if ([System.IO.Path]::IsPathRooted($Out)) { $Out } else { Join-Path $dir $Out }
$lst = Join-Path $dir "_configure.lst"
$defs = @("-dFEAT_CUSTOM") + ($selected | ForEach-Object { "-dFEAT_$_" })

Write-Host ("`nnasm {0} cc.asm -> {1}" -f ($defs -join " "), (Split-Path $outPath -Leaf))
& $nasm -f bin @defs "$dir\cc.asm" -o $outPath -l $lst 2>&1 | Write-Host
if ($LASTEXITCODE -ne 0) {
    Write-Host ("NASM FAILED (exit {0})" -f $LASTEXITCODE)
    if (Test-Path $lst) { Remove-Item $lst -Force -ErrorAction SilentlyContinue }
    exit 1
}

# ---- resident size (PSP + emitted + .bss), same method as build.ps1 --------
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
$code     = (Get-Item $outPath).Length
$bss      = Get-BssSize $lst
$resident = 0x100 + $code + $bss
Remove-Item $lst -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host ("  output       : {0}" -f $outPath)
Write-Host ("  emitted code : {0,7:N0} B  ({1:N1} KB)" -f $code, ($code/$KB))
Write-Host ("  resident img : {0,7:N0} B  ({1:N1} KB)" -f $resident, ($resident/$KB))
$fits = $resident -lt $RES_WALL
Write-Host ("  fits 63 KB   : {0}  ({1:N0} B {2})" -f $(if($fits){"YES"}else{"NO"}), [math]::Abs($RES_WALL-$resident), $(if($fits){"to spare"}else{"OVER"}))
if (-not $fits) { Write-Host "  (still loads if it stays under the 64 KB segment, but trim widgets to be safe)" }
Write-Host "`nDone. Run it with:  $((Split-Path $outPath -Leaf))"
exit 0
