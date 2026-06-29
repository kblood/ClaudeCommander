# build_dist.ps1 -- Produce 4 distribution zips in dist\
# Assumes CC.COM and CCPOP.COM already exist (built by build.ps1 / package.ps1).
# Builds cc-lfn.com with NASM if it does not already exist.

$ErrorActionPreference = "Stop"
$dir  = "C:\LLM\cc"
$nasm = "C:\Users\Caldor\AppData\Local\bin\NASM\nasm.exe"
if (-not (Test-Path $nasm)) { $nasm = "nasm" }
$dist = "$dir\dist"

# Ensure dist\ exists
if (-not (Test-Path $dist)) {
    New-Item -ItemType Directory -Path $dist | Out-Null
    Write-Host "Created $dist"
}

# ---- Build cc-lfn.com if not present ----
$lfnCom = "$dir\cc-lfn.com"
if (-not (Test-Path $lfnCom)) {
    Write-Host "Building cc-lfn.com (-dFEAT_STD -dFEAT_LFN_FULL) ..."
    & $nasm -f bin "$dir\cc.asm" -dFEAT_STD -dFEAT_LFN_FULL -o $lfnCom 2>&1 | Write-Host
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: NASM failed to build cc-lfn.com (exit $LASTEXITCODE)" -ForegroundColor Red
        exit 1
    }
    Write-Host ("  cc-lfn.com  {0:N0} B" -f (Get-Item $lfnCom).Length)
} else {
    Write-Host ("cc-lfn.com already exists ({0:N0} B) -- skipping build" -f (Get-Item $lfnCom).Length)
}

# ---- Write BUILDING.TXT ----
$buildingTxt = "$dir\BUILDING.TXT"
$buildingContent = @"
To build CC from source on DOS:
1. Install NASM for DOS on your PATH
2. Run INSTALL.BAT and answer the prompts
3. The built CC.COM (or CC-LFN.COM) will appear in the current directory
"@
Set-Content -Path $buildingTxt -Value $buildingContent -Encoding ASCII
Write-Host "Wrote BUILDING.TXT"

# ---- Helper function: build a zip from a list of source files ----
# Each entry is @{ Src = "absolute\path\to\file"; Name = "name-in-zip" }
# or just a string (absolute path; zip entry = filename only).
function New-DistZip([string]$zipPath, [array]$entries) {
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

    # Stage into a temp folder so Compress-Archive preserves flat structure
    $tmp = "$env:TEMP\cc_dist_stage_$([System.IO.Path]::GetFileNameWithoutExtension($zipPath))"
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    New-Item -ItemType Directory -Path $tmp | Out-Null

    $missing  = @()
    $included = @()
    foreach ($e in $entries) {
        if ($e -is [string]) {
            $src  = $e
            $name = [System.IO.Path]::GetFileName($src)
        } else {
            $src  = $e.Src
            $name = $e.Name
        }

        if (-not (Test-Path $src)) {
            $missing += $name
            continue
        }

        # Support subdirectory entries (e.g. wincc\*)
        $dest = "$tmp\$name"
        $destDir = [System.IO.Path]::GetDirectoryName($dest)
        if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir | Out-Null }
        Copy-Item $src $dest -Force
        $included += $name
    }

    Compress-Archive -Path "$tmp\*" -DestinationPath $zipPath -Force
    Remove-Item $tmp -Recurse -Force

    return @{ Included = $included; Missing = $missing }
}

# ---- Define file lists ----

# Helper .COMs that ship with both default and LFN builds
# (use names as they exist in $dir or $dist)
$helperComs = @(
    @{ Src = "$dir\ccfind.com"; Name = "CCFIND.COM" },
    @{ Src = "$dir\cczip.com";  Name = "CCZIP.COM"  },
    @{ Src = "$dir\ccgrep.com"; Name = "CCGREP.COM" },
    @{ Src = "$dir\cchex.com";  Name = "CCHEX.COM"  },
    @{ Src = "$dir\ccsum.com";  Name = "CCSUM.COM"  },
    @{ Src = "$dir\ccedit.com"; Name = "CCEDIT.COM" },
    @{ Src = "$dir\cchexed.com";Name = "CCHEXED.COM"},
    @{ Src = "$dir\ccdiff.com"; Name = "CCDIFF.COM" },
    @{ Src = "$dir\ccsplit.com";Name = "CCSPLIT.COM"},
    @{ Src = "$dir\ccjoin.com"; Name = "CCJOIN.COM" },
    @{ Src = "$dir\ccren.com";  Name = "CCREN.COM"  },
    @{ Src = "$dir\cctouch.com";Name = "CCTOUCH.COM"},
    @{ Src = "$dir\ccarj.com";  Name = "CCARJ.COM"  },
    @{ Src = "$dir\ccrar.com";  Name = "CCRAR.COM"  },
    @{ Src = "$dir\ccimg.com";  Name = "CCIMG.COM"  },
    @{ Src = "$dir\ccwav.com";  Name = "CCWAV.COM"  },
    @{ Src = "$dir\ccd64.com";  Name = "CCD64.COM"  },
    @{ Src = "$dir\cct64.com";  Name = "CCT64.COM"  }
)

# Also try dist\ as source for any helper not in $dir root
foreach ($h in $helperComs) {
    if (-not (Test-Path $h.Src)) {
        $fromDist = "$dist\$($h.Name)"
        if (Test-Path $fromDist) { $h.Src = $fromDist }
    }
}

$dataFiles = @(
    @{ Src = "$dir\cc.ini"; Name = "cc.ini" },
    @{ Src = "$dir\cc.lng"; Name = "cc.lng" },
    @{ Src = "$dir\cc.hlp"; Name = "cc.hlp" },
    @{ Src = "$dir\da.lng"; Name = "da.lng"  }
)

# ---- a) cc-default.zip ----
Write-Host "`n---- Building cc-default.zip ----"
$defaultEntries = @(
    @{ Src = "$dir\cc.com";   Name = "CC.COM"   },
    @{ Src = "$dir\ccpop.com";Name = "CCPOP.COM" }
) + $helperComs + $dataFiles

$r = New-DistZip "$dist\cc-default.zip" $defaultEntries
Write-Host "  Included: $($r.Included -join ', ')"
if ($r.Missing) { Write-Host "  Missing (skipped): $($r.Missing -join ', ')" -ForegroundColor Yellow }

# ---- b) cc-lfn.zip ----
Write-Host "`n---- Building cc-lfn.zip ----"
$lfnEntries = @(
    @{ Src = $lfnCom; Name = "cc-lfn.com" }
) + $helperComs + $dataFiles

$r = New-DistZip "$dist\cc-lfn.zip" $lfnEntries
Write-Host "  Included: $($r.Included -join ', ')"
if ($r.Missing) { Write-Host "  Missing (skipped): $($r.Missing -join ', ')" -ForegroundColor Yellow }

# ---- c) cc-installer.zip ----
Write-Host "`n---- Building cc-installer.zip ----"

# Gather *.asm from root
$asmFiles = Get-ChildItem "$dir\*.asm" | ForEach-Object {
    @{ Src = $_.FullName; Name = $_.Name }
}
# Gather mod\*.inc
$incFiles = Get-ChildItem "$dir\mod\*.inc" | ForEach-Object {
    @{ Src = $_.FullName; Name = "mod\$($_.Name)" }
}

$installerEntries = $asmFiles + $incFiles + @(
    @{ Src = "$dir\INSTALL.BAT";   Name = "INSTALL.BAT"   },
    @{ Src = "$dir\CCSETUP.BAT";   Name = "CCSETUP.BAT"   },
    @{ Src = "$dir\cc.ini";        Name = "cc.ini"         },
    @{ Src = "$dir\cc.lng";        Name = "cc.lng"         },
    @{ Src = "$dir\cc.hlp";        Name = "cc.hlp"         },
    @{ Src = "$dir\da.lng";        Name = "da.lng"         },
    @{ Src = $buildingTxt;         Name = "BUILDING.TXT"   }
)

$r = New-DistZip "$dist\cc-installer.zip" $installerEntries
Write-Host "  Included: $($r.Included -join ', ')"
if ($r.Missing) { Write-Host "  Missing (skipped): $($r.Missing -join ', ')" -ForegroundColor Yellow }

# ---- d) wincc.zip ----
Write-Host "`n---- Building wincc.zip ----"
$winccEntries = @(
    @{ Src = "$dir\wincc\cc.exe";   Name = "cc.exe"    },
    @{ Src = "$dir\wincc\cc.cmd";   Name = "cc.cmd"    },
    @{ Src = "$dir\wincc\cc.ps1";   Name = "cc.ps1"    },
    @{ Src = "$dir\wincc\README.md"; Name = "README.md" }
)

$r = New-DistZip "$dist\wincc.zip" $winccEntries
Write-Host "  Included: $($r.Included -join ', ')"
if ($r.Missing) { Write-Host "  Missing (skipped): $($r.Missing -join ', ')" -ForegroundColor Yellow }

# ---- Summary ----
Write-Host "`n==== Distribution zips in $dist ===="
Get-ChildItem "$dist\*.zip" | Sort-Object Name | ForEach-Object {
    "{0,-22}  {1,8:N0} B" -f $_.Name, $_.Length | Write-Host
}
Write-Host "`nbuild_dist.ps1 complete."
