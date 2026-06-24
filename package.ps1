# package.ps1 -- build a self-contained Claude Commander distribution in dist\
# Assembles cc.com + every external helper under the exact names cc launches,
# copies the runtime data files, and writes a short README. The result is a
# folder you can MOUNT as a DOS drive (DOSBox or real hardware) and run.

$ErrorActionPreference = "Stop"
$dir  = "C:\LLM\cc"
$nasm = "C:\Users\Caldor\AppData\Local\bin\NASM\nasm.exe"
if (-not (Test-Path $nasm)) { $nasm = "nasm" }
$out  = "$dir\dist"

# source .asm -> output .COM name that cc (and the user) invoke
$bins = @(
    @{ src = "cc.asm";    com = "CC.COM"     ; std = $true },
    @{ src = "cce.asm";   com = "CCEDIT.COM" },
    @{ src = "cfind.asm"; com = "CCFIND.COM" },
    @{ src = "czip.asm";  com = "CCZIP.COM"  },
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
    @{ src = "cren.asm";  com = "CCREN.COM"  }
)
$data = @("cc.ini", "cc.hlp", "da.lng")

# clean dist
if (Test-Path $out) { Remove-Item $out -Recurse -Force }
New-Item -ItemType Directory -Path $out | Out-Null

Write-Host "Assembling binaries ->" $out
foreach ($b in $bins) {
    $target = "$out\$($b.com)"
    & $nasm -f bin -i "$dir/" "$dir\$($b.src)" -o $target 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Host "  FAILED: $($b.src)"; exit 1 }
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
& $nasm -f bin -i "$dir/" @popDefs "$dir\cc.asm" -o "$out\CCPOP.COM" 2>&1
if ($LASTEXITCODE -ne 0) { Write-Host "  FAILED: CCPOP.COM"; exit 1 }
"{0,-12} {1,7:N0} B  <- cc.asm (pop-up menu)" -f "CCPOP.COM", (Get-Item "$out\CCPOP.COM").Length | Write-Host

Write-Host "`nCopying data files"
foreach ($d in $data) {
    if (Test-Path "$dir\$d") {
        Copy-Item "$dir\$d" "$out\$d" -Force
        "{0,-12} {1,7:N0} B" -f $d, (Get-Item "$out\$d").Length | Write-Host
    } else {
        Write-Host "  (skipped missing $d)"
    }
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

The Tools menu runs the bundled helpers on the cursor / panel files so they
feel built in: Hex dump (the F3 viewer in hex mode), Checksum, Compare,
Split file and Wildcard rename. The F3 viewer itself has a built-in HEX
mode -- open any file with F3 and press H to toggle text <-> hex, or press
E to edit it (text editor in text mode, CCHEXED hex editor in hex mode).

Files:
  CC.COM      the file manager (run this) -- top pull-down menu bar on F9
  CCPOP.COM   same, but with the classic single pop-up menu on F9
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
  CCIMG.COM   view BMP/PCX/GIF  (F3 on a mapped image; VGA mode 13h)
  CCWAV.COM   play a PCM .wav   (F3 on a .wav; Sound Blaster, ESC stops)
  CCDIFF.COM  byte-compare      (type CCDIFF <file1> <file2>)
  CCSPLIT.COM split a file      (type CCSPLIT <file> <size>[K])
  CCJOIN.COM  rejoin parts      (type CCJOIN <output> <base>)
  CCREN.COM   wildcard rename   (type CCREN <srcmask> <dstmask>)
  cc.ini      startup options (sort=, columns=)
  cc.hlp      F1 help text
  da.lng      Danish F-key bar sample -- copy to cc.lng to use it

To run on real DOS / MiSTer ao486: copy this whole folder somewhere on the
DOS drive and run CC. In DOSBox: MOUNT C <thisfolder> then C: then CC.
"@
Set-Content -Path "$out\README.TXT" -Value $readme -Encoding ASCII

Write-Host "`nDistribution ready:" $out
Get-ChildItem $out | Sort-Object Name | Format-Table Name, Length -AutoSize
