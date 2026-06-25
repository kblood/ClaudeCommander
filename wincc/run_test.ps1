# run_test.ps1 -- headless regression gate for the wincc (Windows console) port.
# Builds cc.exe, stages a known directory, drives the in-memory render via the
# --keys/--dump/--dumpa seam (no interactive TTY needed), and asserts the frame
# and attribute layer. Mirrors the DOS /T + CCDUMP harness.
$ErrorActionPreference = "Stop"
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
& "$dir\build.ps1"

$td = "$dir\_rt"
New-Item -ItemType Directory -Path $td -Force | Out-Null
New-Item -ItemType Directory -Path "$td\SUBDIR" -Force | Out-Null
New-Item -ItemType Directory -Path "$td\Zeta Folder" -Force | Out-Null
[IO.File]::WriteAllText("$td\readme.txt","hello")
[IO.File]::WriteAllText("$td\BIG.DAT",("x"*123456))

$pass = 0; $fail = 0
function Check($name,$cond){ if($cond){Write-Host "  PASS  $name";$script:pass++}else{Write-Host "  FAIL  $name";$script:fail++} }

# --- frame: initial render ---
& "$dir\cc.exe" --dir $td --rdir $dir --dump "$dir\_f.txt" | Out-Null
$f = Get-Content "$dir\_f.txt" -Encoding UTF8
Check "header shows path"      ($f[0] -match '_rt')
Check "'..' first entry"       ($f[1] -match '^\W*\.\.')
Check "dirs before files"      ($f[2] -match 'SUBDIR|Zeta Folder')
Check "LFN dir 'Zeta Folder'"  (($f -join "`n") -match 'Zeta Folder')
Check "file size right-align"  (($f -join "`n") -match 'BIG\.DAT\s+123456')
Check "F-key bar present"      ($f[24] -match '1Help.*10Quit')

# --- attributes: tag BIG.DAT (down x3 to BIG.DAT under SUBDIR/Zeta/readme? sorted) ---
# sorted order: .. , SUBDIR, Zeta Folder, BIG.DAT, readme.txt
Set-Content "$dir\_k.txt" "DOWN`nDOWN`nDOWN`nTAG" -Encoding ASCII
& "$dir\cc.exe" --dir $td --keys "$dir\_k.txt" --dumpa "$dir\_a.txt" | Out-Null
$a = Get-Content "$dir\_a.txt"
function tok($r,$c){ ($a[$r] -split ' ')[$c] }
# BIG.DAT is idx3 -> row 4 ; tagged => 1e ; cursor advanced to idx4 (readme,row5)=>30
Check "tagged entry attr 1e"   ((tok 4 1) -eq '1e')
Check "cursor entry attr 30"   ((tok 5 1) -eq '30')
Check "dir entry attr 1f"      ((tok 1 1) -eq '1f')

Write-Host ("`nwincc: {0} passed, {1} failed" -f $pass,$fail)
if ($fail -gt 0) { exit 1 } else { Write-Host "WINCC REGRESSION: PASS"; exit 0 }
