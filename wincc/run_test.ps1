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

# --- milestone 3: sort modes + colour themes ---
$st = "$dir\_sort"
Remove-Item $st -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory $st -Force | Out-Null
[IO.File]::WriteAllText("$st\bbb.txt",("x"*10));   Start-Sleep -Milliseconds 40
[IO.File]::WriteAllText("$st\aaa.zip",("y"*5000)); Start-Sleep -Milliseconds 40
[IO.File]::WriteAllText("$st\ccc.dat",("z"*100))
function SortDump($keys){ Set-Content "$dir\_sk.txt" $keys -Encoding ASCII
    & "$dir\cc.exe" --dir $st --keys "$dir\_sk.txt" --dump "$dir\_sd.txt" | Out-Null
    Get-Content "$dir\_sd.txt" -Encoding UTF8 }

# row 0 = box border, row 1 = "..", so the first file entry is row 2
$s = SortDump "SORT:name"
Check "sort name: aaa first" ($s[2] -match 'aaa\.zip')
$s = SortDump "SORT:ext"
Check "sort ext: dat first"  ($s[2] -match 'ccc\.dat')   # dat < txt < zip
Check "sort status shows ext" ($s[23] -match 'sort:ext')
$s = SortDump "SORT:size"
Check "sort size: 10 first"  ($s[2] -match 'bbb\.txt\s+10\b')
$s = SortDump "SORT:date"
Check "sort date: newest 1st" ($s[2] -match 'ccc\.dat')  # created last

# theme: 1 cycle -> black (norm 0x07), 2 cycles -> mono (norm 0x07, dir 0x0f), back to blue
Set-Content "$dir\_sk.txt" "THEME" -Encoding ASCII
& "$dir\cc.exe" --dir $st --keys "$dir\_sk.txt" --dumpa "$dir\_ta.txt" | Out-Null
$ta = Get-Content "$dir\_ta.txt"
Check "theme switch norm 07" ((($ta[2] -split ' ')[1]) -eq '07')

# --- milestone 4: quick search + drive selection ---
$qd = "$dir\_qs"
Remove-Item $qd -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory $qd -Force | Out-Null
foreach ($f in "alpha.txt","beta.txt","gamma.txt","delta.txt") { [IO.File]::WriteAllText("$qd\$f","x") }
# sorted: .., alpha, beta, delta, gamma  -> rows 1..5
Set-Content "$dir\_qk.txt" "TYPE:gam" -Encoding ASCII
& "$dir\cc.exe" --dir $qd --keys "$dir\_qk.txt" --dump  "$dir\_qd.txt" | Out-Null
& "$dir\cc.exe" --dir $qd --keys "$dir\_qk.txt" --dumpa "$dir\_qa.txt" | Out-Null
$qdd = Get-Content "$dir\_qd.txt" -Encoding UTF8
$qaa = Get-Content "$dir\_qa.txt"
Check "quicksearch status"   ($qdd[23] -match 'search: gam')
Check "quicksearch cursor"   ((($qaa[5] -split ' ')[1]) -eq '30' -and $qdd[5] -match 'gamma')

Set-Content "$dir\_qk.txt" "DRIVE:C" -Encoding ASCII
& "$dir\cc.exe" --dir $qd --keys "$dir\_qk.txt" --dump "$dir\_qd2.txt" | Out-Null
Check "drive switch C:\"     ((Get-Content "$dir\_qd2.txt" -Encoding UTF8)[0] -match 'C:\\')
Set-Content "$dir\_qk.txt" "DRIVESL" -Encoding ASCII
& "$dir\cc.exe" --dir $qd --keys "$dir\_qk.txt" --dump "$dir\_qd3.txt" | Out-Null
Check "drive picker overlay" (((Get-Content "$dir\_qd3.txt" -Encoding UTF8) -join "`n") -match 'C:\\')

# --- resize: layout follows --size WxH ---
& "$dir\cc.exe" --dir $qd --size 120x40 --dump "$dir\_rbig.txt" | Out-Null
$rb = Get-Content "$dir\_rbig.txt" -Encoding UTF8
Check "resize 120x40 rows"   ($rb.Count -eq 40)
Check "resize 120x40 cols"   ($rb[0].Length -eq 120)
Check "resize fkey at bottom" ($rb[39] -match '1Help')
Check "resize panels split"   ($rb[0] -match '^┌.*┐┌.*┐$')  # two boxes side by side
& "$dir\cc.exe" --dir $qd --size 50x12 --dump "$dir\_rsm.txt" | Out-Null
$rs = Get-Content "$dir\_rsm.txt" -Encoding UTF8
Check "resize 50x12 rows"    ($rs.Count -eq 12)
Check "resize 50x12 cols"    ($rs[0].Length -eq 50)
Check "resize small lists"   ($rs[2] -match 'alpha\.txt')

# --- cd-on-exit: active panel's path is exported to %CC_CWD_FILE% ---
$cl = "$dir\_cdl"; $cr = "$dir\_cdr"
Remove-Item $cl,$cr -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory "$cl\SUBA","$cr\SUBB" -Force | Out-Null
$env:CC_CWD_FILE = "$dir\_cwd.txt"
# sorted: .., SUBA  -> DOWN lands on SUBA, ENTER descends into it
Remove-Item $env:CC_CWD_FILE -ErrorAction SilentlyContinue
Set-Content "$dir\_cdk.txt" "DOWN`nENTER" -Encoding ASCII
& "$dir\cc.exe" --dir $cl --keys "$dir\_cdk.txt" --dump "$dir\_cdd.txt" | Out-Null
$cwd1 = if (Test-Path $env:CC_CWD_FILE) { (Get-Content $env:CC_CWD_FILE -Raw).Trim() } else { "" }
Check "cd-on-exit active panel" ($cwd1 -match 'SUBA$')
# after TAB the right panel is active -> its path is what gets exported
Remove-Item $env:CC_CWD_FILE -ErrorAction SilentlyContinue
Set-Content "$dir\_cdk.txt" "TAB`nDOWN`nENTER" -Encoding ASCII
& "$dir\cc.exe" --dir $cl --rdir $cr --keys "$dir\_cdk.txt" --dump "$dir\_cdd.txt" | Out-Null
$cwd2 = if (Test-Path $env:CC_CWD_FILE) { (Get-Content $env:CC_CWD_FILE -Raw).Trim() } else { "" }
Check "cd-on-exit follows TAB"  ($cwd2 -match 'SUBB$')
Remove-Item Env:\CC_CWD_FILE -ErrorAction SilentlyContinue

Write-Host ("`nwincc: {0} passed, {1} failed" -f $pass,$fail)
if ($fail -gt 0) { exit 1 } else { Write-Host "WINCC REGRESSION: PASS"; exit 0 }
