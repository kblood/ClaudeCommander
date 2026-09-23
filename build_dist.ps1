# build_dist.ps1 -- Produce the distribution zips in dist\
#
#   cc-default.zip    CC.COM, CCPOP.COM, CCUSER.COM + helpers + data + README.TXT
#   cc-lfn.zip        CC-LFN.COM (std + FEAT_LFN_FULL) + helpers + data
#   cc-installer.zip  cc.asm + mod\*.inc + ccpop.asm + INSTALL.BAT (build CC on
#                     DOS with NASM) + the prebuilt helpers + data
#   wincc.zip         the Windows console port (wincc\cc.exe, rebuilt here)
#
# Everything is rebuilt from source on every run -- nothing is taken from
# leftover binaries in the repo root:
#   1. build.ps1 -Profile std,lfn   budget gate for CC.COM + fresh cc-lfn.com
#   2. package.ps1                  fresh dist\ (all .COMs, data, README.TXT)
#   3. wincc\build.ps1              fresh wincc\cc.exe (skip with -NoWinCC)
#   4. zips, from dist\ + cc-lfn.com + tracked sources only
# Any failure aborts with a non-zero exit code; each zip is written to a temp
# file first, so a failure never leaves a truncated zip in dist\.

param(
    [switch]$NoWinCC            # skip wincc.zip (e.g. no MinGW gcc on this box)
)
$ErrorActionPreference = "Stop"
$dir  = $PSScriptRoot                       # works from any cwd
$dist = "$dir\dist"

function Fail([string]$msg) {
    Write-Host "ERROR: $msg" -ForegroundColor Red
    Write-Host "build_dist.ps1 FAILED"
    exit 1
}
trap { Fail "$_" }

# ---- 1. budget gate + fresh CC-LFN.COM -------------------------------------
Write-Host "==== build.ps1 -Profile std,lfn ===="
& "$dir\build.ps1" -Profile std,lfn
if ($LASTEXITCODE -ne 0) { Fail "build.ps1 failed (NASM error or over budget)" }
$lfnCom = "$dir\cc-lfn.com"

# ---- 2. fresh dist\ ---------------------------------------------------------
Write-Host "`n==== package.ps1 ===="
& "$dir\package.ps1"
if ($LASTEXITCODE -ne 0) { Fail "package.ps1 failed" }

# ---- 3. fresh wincc\cc.exe --------------------------------------------------
if (-not $NoWinCC) {
    Write-Host "`n==== wincc\build.ps1 ===="
    & "$dir\wincc\build.ps1"            # throws on a gcc failure -> trap -> Fail
}

# ---- Helper: build a zip from an explicit list of files ---------------------
# Each entry is @{ Src = "absolute\path"; Name = "name-in-zip" } (Name may
# contain a subdirectory, e.g. "mod\ini.inc"). Every entry must exist -- a
# missing file is an error, never silently skipped. DOS text files (.BAT/.TXT)
# are written with CRLF line endings: COMMAND.COM cannot run LF-only batches.
function New-DistZip([string]$zipPath, [array]$entries) {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("cc_dist_stage_{0}_{1}" -f [System.IO.Path]::GetFileNameWithoutExtension($zipPath), $PID)
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    New-Item -ItemType Directory -Path $tmp | Out-Null

    $missing = @($entries | Where-Object { -not (Test-Path -LiteralPath $_.Src -PathType Leaf) } | ForEach-Object { "$($_.Name) ($($_.Src))" })
    if ($missing.Count -gt 0) {
        Remove-Item $tmp -Recurse -Force
        Fail ("{0}: missing {1}" -f (Split-Path $zipPath -Leaf), ($missing -join ", "))
    }

    $latin1 = [System.Text.Encoding]::GetEncoding(28591)   # byte-preserving
    foreach ($e in $entries) {
        $dest    = Join-Path $tmp $e.Name
        $destDir = [System.IO.Path]::GetDirectoryName($dest)
        if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir | Out-Null }
        if ($e.Name -match '\.(bat|txt)$') {
            $s = $latin1.GetString([System.IO.File]::ReadAllBytes($e.Src)) -replace "`r?`n", "`r`n"
            [System.IO.File]::WriteAllBytes($dest, $latin1.GetBytes($s))
        } else {
            Copy-Item -LiteralPath $e.Src $dest -Force
        }
    }

    $tmpZip = "$tmp.zip"
    if (Test-Path $tmpZip) { Remove-Item $tmpZip -Force }
    Compress-Archive -Path "$tmp\*" -DestinationPath $tmpZip -Force
    Remove-Item $tmp -Recurse -Force
    Move-Item $tmpZip $zipPath -Force

    Write-Host ("  {0} files: {1}" -f $entries.Count, (($entries | ForEach-Object { $_.Name }) -join ", "))
}

function Entry([string]$src, [string]$name) { @{ Src = $src; Name = $name } }

# ---- File lists (all binaries come from the fresh dist\) --------------------
# Helper .COMs: every helper package.ps1 builds from this repo. CCPAK/CCMDL are
# routed by cc.ini ([open] pak=, [view] mdl=), so they must ship.
$helperNames = @(
    "CCEDIT.COM","CCFIND.COM","CCZIP.COM","CCPAK.COM","CCMDL.COM","CCGREP.COM",
    "CCHEX.COM","CCHEXED.COM","CCSUM.COM","CCD64.COM","CCT64.COM","CCARJ.COM",
    "CCRAR.COM","CCIMG.COM","CCWAV.COM","CCDIFF.COM","CCSPLIT.COM","CCJOIN.COM",
    "CCREN.COM","CCTOUCH.COM"
)
$helperComs = @($helperNames | ForEach-Object { Entry "$dist\$_" $_ })

# Gold Box helpers (cc.ini routes .dax/.daa/.tlb/.glb/.gbi/.hti/.geo/.dai to
# them) are optional in package.ps1 -- ship whichever it bundled.
$gbNames = @("CCGLB.COM","CCGEO.COM","CCHLIB.COM","CCDAA.COM","CCSND.COM","CCGB.COM","CCGBC.COM")
$gbHave  = @($gbNames | Where-Object { Test-Path "$dist\$_" })
$gbMiss  = @($gbNames | Where-Object { -not (Test-Path "$dist\$_") })
if ($gbMiss.Count -gt 0) {
    Write-Host ("WARNING: Gold Box helpers not bundled by package.ps1: {0}" -f ($gbMiss -join ", ")) -ForegroundColor Yellow
}
$helperComs += @($gbHave | ForEach-Object { Entry "$dist\$_" $_ })

# Runtime data (cc.lng is the user's own opt-in copy of da.lng; not shipped)
$dataFiles = @(
    (Entry "$dist\cc.ini" "cc.ini"),
    (Entry "$dist\cc.hlp" "cc.hlp"),
    (Entry "$dist\da.lng" "da.lng")
)

# ---- a) cc-default.zip ------------------------------------------------------
Write-Host "`n---- Building cc-default.zip ----"
$defaultEntries = @(
    (Entry "$dist\CC.COM"     "CC.COM"),
    (Entry "$dist\CCPOP.COM"  "CCPOP.COM"),
    (Entry "$dist\CCUSER.COM" "CCUSER.COM"),
    (Entry "$dist\README.TXT" "README.TXT")
) + $helperComs + $dataFiles
# TOOLSAMP\ (example .BATs for CCUSER.COM) if package.ps1 bundled it
if (Test-Path "$dist\TOOLSAMP") {
    $defaultEntries += @(Get-ChildItem "$dist\TOOLSAMP" -File | ForEach-Object { Entry $_.FullName "TOOLSAMP\$($_.Name)" })
}
New-DistZip "$dist\cc-default.zip" $defaultEntries

# ---- b) cc-lfn.zip ----------------------------------------------------------
Write-Host "`n---- Building cc-lfn.zip ----"
$lfnEntries = @( (Entry $lfnCom "CC-LFN.COM") ) + $helperComs + $dataFiles
New-DistZip "$dist\cc-lfn.zip" $lfnEntries

# ---- c) cc-installer.zip ----------------------------------------------------
# Explicit source list (NOT a *.asm glob: the root also holds _*.asm scratch
# and cmdl_exp*.asm experiments that are not 8.3-distinct). INSTALL.BAT builds
# only CC.COM / CC-LFN.COM (from cc.asm or the ccpop.asm wrapper); the helper
# .COMs ship prebuilt (see BUILDING.TXT).
Write-Host "`n---- Building cc-installer.zip ----"
$incFiles = @(Get-ChildItem "$dir\mod\*.inc" | Sort-Object Name | ForEach-Object { Entry $_.FullName "mod\$($_.Name)" })
if ($incFiles.Count -eq 0) { Fail "no mod\*.inc found" }
$installerEntries = @(
    (Entry "$dir\cc.asm"       "cc.asm"),
    (Entry "$dir\ccpop.asm"    "ccpop.asm"),
    (Entry "$dir\INSTALL.BAT"  "INSTALL.BAT"),
    (Entry "$dir\CCSETUP.BAT"  "CCSETUP.BAT"),
    (Entry "$dir\BUILDING.TXT" "BUILDING.TXT")
) + $incFiles + $helperComs + $dataFiles
New-DistZip "$dist\cc-installer.zip" $installerEntries

# ---- d) wincc.zip -----------------------------------------------------------
if ($NoWinCC) {
    Write-Host "`n---- Skipping wincc.zip (-NoWinCC) ----"
    if (Test-Path "$dist\wincc.zip") { Remove-Item "$dist\wincc.zip" -Force }   # never ship a stale one
} else {
    Write-Host "`n---- Building wincc.zip ----"
    $winccEntries = @(
        (Entry "$dir\wincc\cc.exe"    "cc.exe"),
        (Entry "$dir\wincc\cc.cmd"    "cc.cmd"),
        (Entry "$dir\wincc\cc.ps1"    "cc.ps1"),
        (Entry "$dir\wincc\README.md" "README.md")
    )
    New-DistZip "$dist\wincc.zip" $winccEntries
}

# ---- Summary ----------------------------------------------------------------
Write-Host "`n==== Distribution zips in $dist ===="
Get-ChildItem "$dist\*.zip" | Sort-Object Name | ForEach-Object {
    "{0,-22}  {1,8:N0} B" -f $_.Name, $_.Length | Write-Host
}
Write-Host "`nbuild_dist.ps1 complete."
exit 0
