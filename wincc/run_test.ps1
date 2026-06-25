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

# --- milestone 2: file operations + viewer ---
$src = "$dir\_op_src"; $dst = "$dir\_op_dst"
function Restage {
    Remove-Item $src,$dst -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory $src,$dst,"$src\TREE" -Force | Out-Null
    [IO.File]::WriteAllText("$src\TREE\inner.txt","nested")
    [IO.File]::WriteAllText("$src\copyme.txt","COPY THIS CONTENT")
    [IO.File]::WriteAllText("$src\moveme.txt","mv")
    [IO.File]::WriteAllText("$src\killme.txt","rm")
    [IO.File]::WriteAllText("$src\old.txt","ren")
}
# sorted src: .. , TREE, copyme.txt, killme.txt, moveme.txt, old.txt
function Drive($keys){ Set-Content "$dir\_ko.txt" $keys -Encoding ASCII
    & "$dir\cc.exe" --dir $src --rdir $dst --keys "$dir\_ko.txt" --dump "$dir\_zo.txt" | Out-Null }

Restage; Drive "DOWN`nDOWN`nCOPY"                 # copyme.txt -> dst
Check "copy file"        (Test-Path "$dst\copyme.txt")
Restage; Drive "DOWN`nCOPY"                       # TREE dir -> dst (recursive)
Check "copy dir tree"    (Test-Path "$dst\TREE\inner.txt")
Restage; Drive "DOWN`nDOWN`nDOWN`nDOWN`nMOVE"     # moveme.txt -> dst
Check "move removes src" (-not (Test-Path "$src\moveme.txt"))
Check "move adds dst"    (Test-Path "$dst\moveme.txt")
Restage; Drive "MKDIR:NewFolder"
Check "mkdir"            (Test-Path "$src\NewFolder")
Restage; Drive "END`nREN:renamed.txt"            # old.txt (last) -> renamed.txt
Check "rename old gone"  (-not (Test-Path "$src\old.txt"))
Check "rename new there" (Test-Path "$src\renamed.txt")
Restage; Drive "DOWN`nDOWN`nDOWN`nDEL"           # killme.txt (idx3)
Check "delete file"      (-not (Test-Path "$src\killme.txt"))
# viewer
Restage; Set-Content "$dir\_ko.txt" "DOWN`nDOWN`nVIEW" -Encoding ASCII
& "$dir\cc.exe" --dir $src --keys "$dir\_ko.txt" --dump "$dir\_vo.txt" | Out-Null
$vv = (Get-Content "$dir\_vo.txt" -Encoding UTF8) -join "`n"
Check "viewer header"    ($vv -match 'View: copyme\.txt')
Check "viewer content"   ($vv -match 'COPY THIS CONTENT')

Write-Host ("`nwincc: {0} passed, {1} failed" -f $pass,$fail)
if ($fail -gt 0) { exit 1 } else { Write-Host "WINCC REGRESSION: PASS"; exit 0 }
