# package.ps1 -- build a self-contained Claude Commander distribution in dist\
# Assembles cc.com + every external helper under the exact names cc launches,
# copies the runtime data files, and writes a short README. The result is a
# folder you can MOUNT as a DOS drive (DOSBox or real hardware) and run.
#
# Everything is built into a staging folder (dist.new\) first; dist\ is only
# replaced once every step has succeeded, so a failed build exits non-zero and
# leaves the previous dist\ intact.
#
# Optional Gold Box helpers (see below): -GoldBoxSrc / $env:CC_GOLDBOX_SRC is
# the .asm source tree, -GoldBoxPrebuilt / $env:CC_GOLDBOX_PREBUILT a folder
# of prebuilt .COMs used as a fallback (with a WARNING).

param(
    [string]$GoldBoxSrc      = $(if ($env:CC_GOLDBOX_SRC)      { $env:CC_GOLDBOX_SRC }      else { "C:\Modding\GoldBox\native\src" }),
    [string]$GoldBoxPrebuilt = $(if ($env:CC_GOLDBOX_PREBUILT) { $env:CC_GOLDBOX_PREBUILT } else { "C:\LLM\cc-goldbox" })
)
$ErrorActionPreference = "Stop"
$dir  = $PSScriptRoot                                   # works from any cwd
$nasm = "C:\Users\Caldor\AppData\Local\bin\NASM\nasm.exe"
if (-not (Test-Path $nasm)) { $nasm = "nasm" }
$final = "$dir\dist"
$out   = "$dir\dist.new"          # staging; swapped into dist\ at the very end

# Run NASM; echo its output; return its exit code.  Success is decided by the
# exit code ONLY (under Windows PowerShell 5.1, EAP=Stop + 2>&1 would turn a
# mere NASM warning on stderr into a terminating error).
function Invoke-Nasm {
    $ErrorActionPreference = "Continue"
    $PSNativeCommandUseErrorActionPreference = $false
    & $nasm @args 2>&1 | ForEach-Object { Write-Host "  $_" }
    return $LASTEXITCODE
}

# Abort: drop the half-built staging folder, keep the old dist\, exit non-zero.
function Fail([string]$msg) {
    Write-Host "  FAILED: $msg" -ForegroundColor Red
    Write-Host "package.ps1 aborted -- $final left unchanged."
    if (Test-Path $out) { Remove-Item $out -Recurse -Force -ErrorAction SilentlyContinue }
    exit 1
}
trap { Fail "$_" }

# source .asm -> output .COM name that cc (and the user) invoke
$bins = @(
    @{ src = "cc.asm";    com = "CC.COM"     ; std = $true },
    @{ src = "cce.asm";   com = "CCEDIT.COM" },
    @{ src = "cfind.asm"; com = "CCFIND.COM" },
    @{ src = "czip.asm";  com = "CCZIP.COM"  },
    @{ src = "cpak.asm";  com = "CCPAK.COM"  },
    @{ src = "cmdl.asm";  com = "CCMDL.COM"  },
    @{ src = "cgrep.asm"; com = "CCGREP.COM" },
    @{ src = "chex.asm";  com = "CCHEX.COM"  },
    @{ src = "chexed.asm";com = "CCHEXED.COM"},
    @{ src = "csum.asm";  com = "CCSUM.COM"  },
    @{ src = "cd64.asm";  com = "CCD64.COM"  },
    @{ src = "ct64.asm";  com = "CCT64.COM"  },
    @{ src = "carj.asm";  com = "CCARJ.COM"  },
    @{ src = "crar.asm";  com = "CCRAR.COM"  },
    @{ src = "cimg.asm";  com = "CCIMG.COM"  },
    @{ src = "cwav.asm";  com = "CCWAV.COM"  },
    @{ src = "cdiff.asm"; com = "CCDIFF.COM" },
    @{ src = "csplit.asm";com = "CCSPLIT.COM"},
    @{ src = "cjoin.asm"; com = "CCJOIN.COM" },
    @{ src = "cren.asm";  com = "CCREN.COM"  },
    @{ src = "ctouch.asm";com = "CCTOUCH.COM"}
)
$data = @("cc.ini", "cc.hlp", "da.lng")

# fresh staging folder (dist\ itself is not touched until the end)
if (Test-Path $out) { Remove-Item $out -Recurse -Force }
New-Item -ItemType Directory -Path $out | Out-Null

Write-Host "Assembling binaries ->" $out
foreach ($b in $bins) {
    $target = "$out\$($b.com)"
    $rc = Invoke-Nasm -f bin -i "$dir/" "$dir\$($b.src)" -o $target
    if ($rc -ne 0 -or -not (Test-Path $target)) { Fail "$($b.src) (nasm exit $rc)" }
    $sz = (Get-Item $target).Length
    "{0,-12} {1,7:N0} B  <- {2}" -f $b.com, $sz, $b.src | Write-Host
}

# Alternate build: the classic single pop-up command menu instead of the
# always-on pull-down bar (= the std feature set minus FEAT_MENUBAR).
Write-Host "`nAlternate pop-up-menu build (CCPOP.COM)"
$popDefs = @(
    "-dFEAT_CUSTOM","-dFEAT_WIDGETS","-dFEAT_CLOCK","-dFEAT_FREE","-dFEAT_VIEWS",
    "-dFEAT_TREE","-dFEAT_SORT","-dFEAT_COLS","-dFEAT_SEARCH","-dFEAT_MASK",
    "-dFEAT_MENU","-dFEAT_HELP","-dFEAT_EDIT","-dFEAT_FIND","-dFEAT_GREP",
    "-dFEAT_ZIP","-dFEAT_ATTR","-dFEAT_VFS","-dFEAT_VIEW","-dFEAT_INI",
    "-dFEAT_LANG","-dFEAT_LFN"
)
$rc = Invoke-Nasm -f bin -i "$dir/" @popDefs "$dir\cc.asm" -o "$out\CCPOP.COM"
if ($rc -ne 0 -or -not (Test-Path "$out\CCPOP.COM")) { Fail "CCPOP.COM (nasm exit $rc)" }
"{0,-12} {1,7:N0} B  <- cc.asm (pop-up menu)" -f "CCPOP.COM", (Get-Item "$out\CCPOP.COM").Length | Write-Host

# ccpop.asm is the same build as a %define wrapper, so INSTALL.BAT can build
# it on DOS with a short (<127 char) command line. Keep the two in lock-step:
# the wrapper must produce a byte-identical binary (also with -dFEAT_LFN_FULL,
# which INSTALL.BAT uses for its LFN + pop-up-menu choice).
$chk = Join-Path ([System.IO.Path]::GetTempPath()) "cc_pkg_chk_$PID"
New-Item -ItemType Directory -Path $chk -Force | Out-Null
foreach ($extra in @(@(), @("-dFEAT_LFN_FULL"))) {
    $ra = Invoke-Nasm -f bin -i "$dir/" @popDefs @extra "$dir\cc.asm"   -o "$chk\a.com"
    $rb = Invoke-Nasm -f bin -i "$dir/" @extra          "$dir\ccpop.asm" -o "$chk\b.com"
    $same = ($ra -eq 0) -and ($rb -eq 0) -and (Test-Path "$chk\a.com") -and (Test-Path "$chk\b.com") -and
            ((Get-FileHash "$chk\a.com").Hash -eq (Get-FileHash "$chk\b.com").Hash)
    if (-not $same) {
        Remove-Item $chk -Recurse -Force -ErrorAction SilentlyContinue
        Fail "ccpop.asm $($extra -join ' ') is not byte-identical to the `$popDefs build -- sync ccpop.asm with package.ps1"
    }
}
Remove-Item $chk -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "  ccpop.asm wrapper == `$popDefs build (with and without -dFEAT_LFN_FULL)"

# User-tools build: enables cc.ini [tools] rows while trimming optional resident
# features enough to stay under the 63 KB wall. This is the build to use with
# TOOLSAMP\*.BAT examples.
Write-Host "`nAlternate user-tools build (CCUSER.COM)"
$userDefs = @(
    "-dFEAT_CUSTOM","-dFEAT_WIDGETS","-dFEAT_CLOCK","-dFEAT_FREE","-dFEAT_VIEWS",
    "-dFEAT_TREE","-dFEAT_SORT","-dFEAT_COLS","-dFEAT_SEARCH","-dFEAT_MASK",
    "-dFEAT_MENU","-dFEAT_MENUBAR","-dFEAT_HELP","-dFEAT_EDIT","-dFEAT_FIND",
    "-dFEAT_GREP","-dFEAT_ZIP","-dFEAT_ATTR","-dFEAT_VFS","-dFEAT_VIEW",
    "-dFEAT_INI","-dFEAT_TOOLS","-dFEAT_TOOLS_INI"
)
$rc = Invoke-Nasm -f bin -i "$dir/" @userDefs "$dir\cc.asm" -o "$out\CCUSER.COM"
if ($rc -ne 0 -or -not (Test-Path "$out\CCUSER.COM")) { Fail "CCUSER.COM (nasm exit $rc)" }
"{0,-12} {1,7:N0} B  <- cc.asm ([tools] menu build)" -f "CCUSER.COM", (Get-Item "$out\CCUSER.COM").Length | Write-Host

# Gold Box (SSI D&D) game-data helpers. Their .asm sources live in the GoldBox
# modding project (not on main); the cc.ini [open]/[view] routing references
# them by name. Prefer building them from that source tree (-GoldBoxSrc /
# $env:CC_GOLDBOX_SRC); fall back to prebuilt .COMs (-GoldBoxPrebuilt /
# $env:CC_GOLDBOX_PREBUILT) with a WARNING, since those may be stale; else skip
# (cc ignores absent helpers, so a build with neither present still works --
# just without Gold Box support).
$gbSrc   = $GoldBoxSrc
$gbWork  = $GoldBoxPrebuilt
$gbTools = @(
    @{ src = "ccglb.asm";  com = "CCGLB.COM"  },
    @{ src = "ccgeo.asm";  com = "CCGEO.COM"  },
    @{ src = "cchlib.asm"; com = "CCHLIB.COM" },
    @{ src = "ccdaa.asm";  com = "CCDAA.COM"  },
    @{ src = "ccsnd.asm";  com = "CCSND.COM"  },
    @{ src = "cgb.asm";    com = "CCGB.COM"   },
    @{ src = "cgbc.asm";   com = "CCGBC.COM"  }
)
Write-Host "`nGold Box helpers (source: $gbSrc ; prebuilt fallback: $gbWork)"
foreach ($g in $gbTools) {
    $target = "$out\$($g.com)"
    $srcf   = if ($gbSrc) { Join-Path $gbSrc $g.src } else { $null }
    if ($srcf -and (Test-Path $srcf)) {
        $rc = Invoke-Nasm -f bin -i "$gbSrc/" $srcf -o $target
        if ($rc -eq 0 -and (Test-Path $target)) {
            "{0,-12} {1,7:N0} B  <- {2} (built)" -f $g.com, (Get-Item $target).Length, $g.src | Write-Host
            continue
        }
        Write-Host "  WARNING: build failed for $($g.src) (nasm exit $rc); trying prebuilt" -ForegroundColor Yellow
    }
    $pre = if ($gbWork) { Join-Path $gbWork $g.com } else { $null }
    if ($pre -and (Test-Path $pre)) {
        Copy-Item $pre $target -Force
        $pi = Get-Item $pre
        "{0,-12} {1,7:N0} B  <- PREBUILT {2}" -f $g.com, $pi.Length, $pi.FullName | Write-Host
        Write-Host ("  WARNING: {0} not built from source -- shipping a prebuilt copy dated {1:yyyy-MM-dd}, which may be stale." -f $g.com, $pi.LastWriteTime) -ForegroundColor Yellow
        Write-Host  "           Point -GoldBoxSrc / `$env:CC_GOLDBOX_SRC at the Gold Box .asm tree to rebuild it." -ForegroundColor Yellow
    } else {
        Write-Host "  (skipped $($g.com): no source or prebuilt)"
    }
}

Write-Host "`nCopying data files"
foreach ($d in $data) {
    if (-not (Test-Path "$dir\$d")) { Fail "missing data file $d" }
    Copy-Item "$dir\$d" "$out\$d" -Force
    "{0,-12} {1,7:N0} B" -f $d, (Get-Item "$out\$d").Length | Write-Host
}

$sampleSrc = Join-Path $dir "toolsamp"
if (Test-Path $sampleSrc) {
    $sampleOut = Join-Path $out "TOOLSAMP"
    Copy-Item $sampleSrc $sampleOut -Recurse -Force
    Write-Host "`nCopied user-tool batch samples -> TOOLSAMP\"
}

# short user note inside the distribution
$readme = @"
Claude Commander (cc) -- portable distribution
==============================================

Run CC.COM to start the file manager. Press F1 inside for the key reference.

CC.COM shows a Norton-style pull-down MENU BAR across the top row
(Files / Commands / Options / Tools) -- press F9 to drop a menu down,
Left/Right to switch menus, Up/Down + Enter to run an item, Esc to close.
If you'd rather have the classic single pop-up menu (and one extra file
row), run CCPOP.COM.
If you want cc.ini [tools] rows that append your own .BAT/.COM tools to the
Tools menu, run CCUSER.COM. It trims language/LFN/results-panel features to make
room for the runtime user-tools registry.

The Tools menu runs the bundled helpers on the cursor / panel files so they
feel built in: Hex dump (the F3 viewer in hex mode), Checksum, Compare,
Split file and Wildcard rename. The F3 viewer itself has a built-in HEX
mode -- open any file with F3 and press H to toggle text <-> hex, or press
E to edit it (text editor in text mode, CCHEXED hex editor in hex mode).

Files:
  CC.COM      the file manager (run this) -- top pull-down menu bar on F9
  CCPOP.COM   same, but with the classic single pop-up menu on F9
  CCUSER.COM  user-tools build: cc.ini [tools] rows add Tools-menu commands
  CCEDIT.COM  text editor       (F4, or type CCEDIT <file>)
  CCFIND.COM  find by name      (Alt-F7, or CCFIND <pattern> [dir])
  CCZIP.COM   list a ZIP        (Ctrl-F9, or CCZIP <zip>)
  CCGREP.COM  search contents   (Alt-F8, or CCGREP <word> [dir] [mask])
  CCHEX.COM   hex dump a file   (type CCHEX <file>)
  CCHEXED.COM hex EDITOR        (F3 hex view E key, editor=CCHEXED, or
                                 CCHEXED <file>; F2 saves, Esc quits)
  CCSUM.COM   CRC-32 + size     (type CCSUM <file>)
  CCD64.COM   browse C64 .d64   (Enter on a .d64; F5 extracts a file)
  CCT64.COM   browse C64 .t64   (Enter on a .t64; F5 extracts a file)
  CCARJ.COM   browse .arj       (Enter on a .arj; F5 extracts STORED)
  CCRAR.COM   browse .rar 4.x   (Enter on a .rar; F5 extracts STORED)
  CCPAK.COM   browse Quake .pak (Enter on a .pak; F5 extracts a member)
  CCIMG.COM   view BMP/PCX/GIF  (F3 on a mapped image; VGA mode 13h)
  CCWAV.COM   play a PCM .wav   (F3 on a .wav; Sound Blaster, ESC stops)
  CCMDL.COM   view Quake .mdl   (F3 on a .mdl, or in place from a .pak)
  CCDIFF.COM  byte-compare      (type CCDIFF <file1> <file2>)
  CCSPLIT.COM split a file      (type CCSPLIT <file> <size>[K])
  CCJOIN.COM  rejoin parts      (type CCJOIN <output> <base>)
  CCREN.COM   wildcard rename   (type CCREN <srcmask> <dstmask>)
  CCTOUCH.COM set file date/time(CCTOUCH <file> [YYYY-MM-DD [HH:MM[:SS]]])
  -- Gold Box (SSI D&D) game-data helpers (if bundled) --
  CCGLB.COM   browse .glb master lib (Enter; dispatches by chunk: sound/img/map)
  CCGEO.COM   view .geo area maps     (F3 on a .geo / GEO members in a .glb)
  CCHLIB.COM  view .tlb/.hti image master  (Enter on .tlb / F3 on .hti)
  CCDAA.COM   .daa/.dai data          (Enter on .daa / F3 on .dai)
  CCSND.COM   play DIG4 digitized sound (dispatched from CCGLB)
  CCGB.COM    view .gbi image         (F3 on a .gbi)
  CCGBC.COM   browse .dax container   (Enter on a .dax)
  cc.ini      startup options (sort=, columns=)
  cc.hlp      F1 help text
  da.lng      Danish F-key bar sample -- copy to cc.lng to use it
  TOOLSAMP\   example .BAT tools for CCUSER.COM; selected file is %1

To run on real DOS / MiSTer ao486: copy this whole folder somewhere on the
DOS drive and run CC. In DOSBox: MOUNT C <thisfolder> then C: then CC.
"@
# CRLF line endings: this is read on DOS
Set-Content -Path "$out\README.TXT" -Value ($readme -replace "`r?`n", "`r`n") -Encoding ASCII -NoNewline

# ---- swap the finished staging folder into dist\ ---------------------------
# Rename-swap when possible; if dist\ is locked (e.g. mounted in a running
# DOSBox) fall back to replacing its contents in place.
$old = "$dir\dist.old"
if (Test-Path $old) { Remove-Item $old -Recurse -Force }
$swapped = $false
try {
    if (Test-Path $final) { Rename-Item $final $old }
    Rename-Item $out $final
    $swapped = $true
} catch {
    if ((-not (Test-Path $final)) -and (Test-Path $old)) { Rename-Item $old $final }   # undo half a swap
}
if (-not $swapped) {
    Write-Host "  (dist\ is in use -- replacing its contents in place)"
    if (-not (Test-Path $final)) { New-Item -ItemType Directory -Path $final | Out-Null }
    Get-ChildItem $final -Force | Remove-Item -Recurse -Force
    Copy-Item "$out\*" $final -Recurse -Force
    Remove-Item $out -Recurse -Force
}
if (Test-Path $old) { Remove-Item $old -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host "`nDistribution ready:" $final
Get-ChildItem $final | Sort-Object Name | Format-Table Name, Length -AutoSize
exit 0
