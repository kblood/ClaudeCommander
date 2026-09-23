param([string]$Work)
# run_test.ps1 -- headless regression gate for the wincc (Windows console) port.
# Builds cc.exe, stages a known directory, drives the in-memory render via the
# --keys/--dump/--dumpa seam (no interactive TTY needed), and asserts the frame
# and attribute layer. Mirrors the DOS /T + CCDUMP harness.
$ErrorActionPreference = "Stop"
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
# test data (incl. junctions and deletes) goes under -Work; default: this folder
if (-not $Work) { $Work = $dir }
$T = $Work
New-Item -ItemType Directory $T -Force | Out-Null
& "$dir\build.ps1"

$td = "$T\_rt"
New-Item -ItemType Directory -Path $td -Force | Out-Null
New-Item -ItemType Directory -Path "$td\SUBDIR" -Force | Out-Null
New-Item -ItemType Directory -Path "$td\Zeta Folder" -Force | Out-Null
[IO.File]::WriteAllText("$td\readme.txt","hello")
[IO.File]::WriteAllText("$td\BIG.DAT",("x"*123456))

$pass = 0; $fail = 0
function Check($name,$cond){ if($cond){Write-Host "  PASS  $name";$script:pass++}else{Write-Host "  FAIL  $name";$script:fail++} }

# --- frame: initial render ---
& "$dir\cc.exe" --dir $td --rdir $dir --dump "$T\_f.txt" | Out-Null
$f = Get-Content "$T\_f.txt" -Encoding UTF8
# a long -Work path is cut to the panel width, so then only its head is visible
Check "header shows path"      (($f[0] -match '_rt') -or ($td.Length -gt 34 -and $f[0].Contains($td.Substring(0,30))))
Check "'..' first entry"       ($f[1] -match '^\W*\.\.')
Check "dirs before files"      ($f[2] -match 'SUBDIR|Zeta Folder')
Check "LFN dir 'Zeta Folder'"  (($f -join "`n") -match 'Zeta Folder')
Check "file size right-align"  (($f -join "`n") -match 'BIG\.DAT\s+120 K')   # fmt_size: 123456 B -> "120 K"
Check "F-key bar present"      ($f[24] -match '2Rename.*8Del.*10Quit')
Check "F-key bar: no unbound"  ($f[24] -notmatch 'Help|Menu|PullDn')

# --- attributes: tag BIG.DAT (down x3 to BIG.DAT under SUBDIR/Zeta/readme? sorted) ---
# sorted order: .. , SUBDIR, Zeta Folder, BIG.DAT, readme.txt
Set-Content "$T\_k.txt" "DOWN`nDOWN`nDOWN`nTAG" -Encoding ASCII
& "$dir\cc.exe" --dir $td --keys "$T\_k.txt" --dumpa "$T\_a.txt" | Out-Null
$a = Get-Content "$T\_a.txt"
function tok($r,$c){ ($a[$r] -split ' ')[$c] }
# BIG.DAT is idx3 -> row 4 ; tagged => 1e ; cursor advanced to idx4 (readme,row5)=>30
Check "tagged entry attr 1e"   ((tok 4 1) -eq '1e')
Check "cursor entry attr 30"   ((tok 5 1) -eq '30')
Check "dir entry attr 1f"      ((tok 1 1) -eq '1f')

# --- milestone 2: file operations + viewer ---
$src = "$T\_op_src"; $dst = "$T\_op_dst"
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
function Drive($keys){ Set-Content "$T\_ko.txt" $keys -Encoding ASCII
    & "$dir\cc.exe" --dir $src --rdir $dst --keys "$T\_ko.txt" --dump "$T\_zo.txt" | Out-Null }

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
Restage; Set-Content "$T\_ko.txt" "DOWN`nDOWN`nVIEW" -Encoding ASCII
& "$dir\cc.exe" --dir $src --keys "$T\_ko.txt" --dump "$T\_vo.txt" | Out-Null
$vv = (Get-Content "$T\_vo.txt" -Encoding UTF8) -join "`n"
Check "viewer header"    ($vv -match 'View: copyme\.txt')
Check "viewer content"   ($vv -match 'COPY THIS CONTENT')

# --- milestone 3: sort modes + colour themes ---
$st = "$T\_sort"
Remove-Item $st -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory $st -Force | Out-Null
[IO.File]::WriteAllText("$st\bbb.txt",("x"*10));   Start-Sleep -Milliseconds 40
[IO.File]::WriteAllText("$st\aaa.zip",("y"*5000)); Start-Sleep -Milliseconds 40
[IO.File]::WriteAllText("$st\ccc.dat",("z"*100))
function SortDump($keys){ Set-Content "$T\_sk.txt" $keys -Encoding ASCII
    & "$dir\cc.exe" --dir $st --keys "$T\_sk.txt" --dump "$T\_sd.txt" | Out-Null
    Get-Content "$T\_sd.txt" -Encoding UTF8 }

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
Set-Content "$T\_sk.txt" "THEME" -Encoding ASCII
& "$dir\cc.exe" --dir $st --keys "$T\_sk.txt" --dumpa "$T\_ta.txt" | Out-Null
$ta = Get-Content "$T\_ta.txt"
Check "theme switch norm 07" ((($ta[2] -split ' ')[1]) -eq '07')

# --- milestone 4: quick search + drive selection ---
$qd = "$T\_qs"
Remove-Item $qd -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory $qd -Force | Out-Null
foreach ($f in "alpha.txt","beta.txt","gamma.txt","delta.txt") { [IO.File]::WriteAllText("$qd\$f","x") }
# sorted: .., alpha, beta, delta, gamma  -> rows 1..5
Set-Content "$T\_qk.txt" "TYPE:gam" -Encoding ASCII
& "$dir\cc.exe" --dir $qd --keys "$T\_qk.txt" --dump  "$T\_qd.txt" | Out-Null
& "$dir\cc.exe" --dir $qd --keys "$T\_qk.txt" --dumpa "$T\_qa.txt" | Out-Null
$qdd = Get-Content "$T\_qd.txt" -Encoding UTF8
$qaa = Get-Content "$T\_qa.txt"
Check "quicksearch status"   ($qdd[23] -match 'search: gam')
Check "quicksearch cursor"   ((($qaa[5] -split ' ')[1]) -eq '30' -and $qdd[5] -match 'gamma')

Set-Content "$T\_qk.txt" "DRIVE:C" -Encoding ASCII
& "$dir\cc.exe" --dir $qd --keys "$T\_qk.txt" --dump "$T\_qd2.txt" | Out-Null
Check "drive switch C:\"     ((Get-Content "$T\_qd2.txt" -Encoding UTF8)[0] -match 'C:\\')
Set-Content "$T\_qk.txt" "DRIVESL" -Encoding ASCII
& "$dir\cc.exe" --dir $qd --keys "$T\_qk.txt" --dump "$T\_qd3.txt" | Out-Null
Check "drive picker overlay" (((Get-Content "$T\_qd3.txt" -Encoding UTF8) -join "`n") -match 'C:\\')

# --- resize: layout follows --size WxH ---
& "$dir\cc.exe" --dir $qd --size 120x40 --dump "$T\_rbig.txt" | Out-Null
$rb = Get-Content "$T\_rbig.txt" -Encoding UTF8
Check "resize 120x40 rows"   ($rb.Count -eq 40)
Check "resize 120x40 cols"   ($rb[0].Length -eq 120)
Check "resize fkey at bottom" ($rb[39] -match '10Quit')
Check "resize panels split"   ($rb[0] -match '^┌.*┐┌.*┐$')  # two boxes side by side
& "$dir\cc.exe" --dir $qd --size 50x12 --dump "$T\_rsm.txt" | Out-Null
$rs = Get-Content "$T\_rsm.txt" -Encoding UTF8
Check "resize 50x12 rows"    ($rs.Count -eq 12)
Check "resize 50x12 cols"    ($rs[0].Length -eq 50)
Check "resize small lists"   ($rs[2] -match 'alpha\.txt')

# --- cd-on-exit: active panel's path is exported to %CC_CWD_FILE% ---
$cl = "$T\_cdl"; $cr = "$T\_cdr"
Remove-Item $cl,$cr -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory "$cl\SUBA","$cr\SUBB" -Force | Out-Null
$env:CC_CWD_FILE = "$T\_cwd.txt"
# sorted: .., SUBA  -> DOWN lands on SUBA, ENTER descends into it
Remove-Item $env:CC_CWD_FILE -ErrorAction SilentlyContinue
Set-Content "$T\_cdk.txt" "DOWN`nENTER" -Encoding ASCII
& "$dir\cc.exe" --dir $cl --keys "$T\_cdk.txt" --dump "$T\_cdd.txt" | Out-Null
$cwd1 = if (Test-Path $env:CC_CWD_FILE) { (Get-Content $env:CC_CWD_FILE -Raw).Trim() } else { "" }
Check "cd-on-exit active panel" ($cwd1 -match 'SUBA$')
# after TAB the right panel is active -> its path is what gets exported
Remove-Item $env:CC_CWD_FILE -ErrorAction SilentlyContinue
Set-Content "$T\_cdk.txt" "TAB`nDOWN`nENTER" -Encoding ASCII
& "$dir\cc.exe" --dir $cl --rdir $cr --keys "$T\_cdk.txt" --dump "$T\_cdd.txt" | Out-Null
$cwd2 = if (Test-Path $env:CC_CWD_FILE) { (Get-Content $env:CC_CWD_FILE -Raw).Trim() } else { "" }
Check "cd-on-exit follows TAB"  ($cwd2 -match 'SUBB$')
# non-ASCII folder: the cwd file is UTF-8 (no BOM) so the wrappers can read it
$cu = "$T\_cdu\$([char]0xC6)blegr$([char]0xF8)d $([char]0x0416)"   # AEblegrod + Cyrillic ZHE
Remove-Item "$T\_cdu" -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory "$cu" -Force | Out-Null
Remove-Item $env:CC_CWD_FILE -ErrorAction SilentlyContinue
Set-Content "$T\_cdk.txt" "DOWN`nENTER" -Encoding ASCII
& "$dir\cc.exe" --dir "$T\_cdu" --keys "$T\_cdk.txt" --dump "$T\_cdd.txt" | Out-Null
$cwd3 = if (Test-Path $env:CC_CWD_FILE) { (Get-Content $env:CC_CWD_FILE -Raw -Encoding UTF8).Trim() } else { "" }
$bom = if (Test-Path $env:CC_CWD_FILE) { [IO.File]::ReadAllBytes($env:CC_CWD_FILE)[0] -eq 0xEF } else { $true }
Check "cd-on-exit UTF-8 path"   ($cwd3 -eq $cu -and -not $bom)
Remove-Item Env:\CC_CWD_FILE -ErrorAction SilentlyContinue

# --- file-op safety (audit fixes) ---
# rmdir /s removes junctions as links (Windows PowerShell's Remove-Item may follow them)
function Stage($p){ if (Test-Path $p) { cmd /c "rmdir /s /q `"$p`"" | Out-Null }
    New-Item -ItemType Directory $p -Force | Out-Null }
function Run($l,$r,$keys){ Set-Content "$T\_sk2.txt" $keys -Encoding ASCII
    & "$dir\cc.exe" --dir $l --rdir $r --keys "$T\_sk2.txt" --dump "$T\_sf.txt" | Out-Null
    $script:rc = $LASTEXITCODE; Get-Content "$T\_sf.txt" -Encoding UTF8 }
$sf = "$T\_safe"

# move a folder into its own subfolder: refused, nothing lost
Stage $sf; New-Item -ItemType Directory "$sf\A\sub" -Force | Out-Null
[IO.File]::WriteAllText("$sf\A\keep.txt","k")
$o = Run $sf "$sf\A\sub" "DOWN`nMOVE"
Check "move into own subdir refused" ((Test-Path "$sf\A\keep.txt") -and ($o[23] -match 'into itself'))
$o = Run $sf "$sf\A\sub" "DOWN`nCOPY"
Check "copy into own subdir refused" (-not (Test-Path "$sf\A\sub\A"))
# ...but a sibling that merely shares the prefix (A2) is fine
New-Item -ItemType Directory "$sf\A2" -Force | Out-Null
$o = Run $sf "$sf\A2" "DOWN`nMOVE"
Check "move into prefix sibling ok"  ((Test-Path "$sf\A2\A\keep.txt") -and -not (Test-Path "$sf\A"))

# delete a folder holding a junction: the junction target must survive
Stage $sf; New-Item -ItemType Directory "$sf\D","$sf\TGT" -Force | Out-Null
[IO.File]::WriteAllText("$sf\TGT\precious.txt","p")
cmd /c "mklink /J `"$sf\D\J`" `"$sf\TGT`"" | Out-Null
$o = Run $sf $sf "DOWN`nDEL"
Check "delete: junction not followed" ((-not (Test-Path "$sf\D")) -and (Test-Path "$sf\TGT\precious.txt"))

# copy a folder holding a junction cycle: terminates, link skipped + reported
Stage $sf; New-Item -ItemType Directory "$sf\C","$sf\OUT" -Force | Out-Null
[IO.File]::WriteAllText("$sf\C\f.txt","f")
cmd /c "mklink /J `"$sf\C\loop`" `"$sf\C`"" | Out-Null
$o = Run $sf "$sf\OUT" "DOWN`nCOPY"
Check "copy: junction cycle skipped" ((Test-Path "$sf\OUT\C\f.txt") -and -not (Test-Path "$sf\OUT\C\loop") -and ($o[23] -match 'link'))

# viewer on a file that is nothing but newlines (old line table overflowed)
Stage $sf; [IO.File]::WriteAllBytes("$sf\nl.txt", [byte[]](,10 * 100000))
$o = Run $sf $sf "DOWN`nVIEW`nEND"
Check "viewer newline-only file"     (($rc -eq 0) -and ($o[0] -match '100001 lines'))

# overwrite: existing target -> confirm; NO skips, YES overwrites
Stage $sf; New-Item -ItemType Directory "$sf\L","$sf\R" -Force | Out-Null
[IO.File]::WriteAllText("$sf\L\x.txt","NEW"); [IO.File]::WriteAllText("$sf\R\x.txt","OLD")
$o = Run "$sf\L" "$sf\R" "DOWN`nCOPY"
Check "overwrite asks first"         ((($o -join "`n") -match 'already exist') -and ([IO.File]::ReadAllText("$sf\R\x.txt") -eq 'OLD'))
$o = Run "$sf\L" "$sf\R" "DOWN`nCOPY`nNO"
Check "overwrite NO keeps target"    (([IO.File]::ReadAllText("$sf\R\x.txt") -eq 'OLD') -and ($o[23] -match 'skipped'))
$o = Run "$sf\L" "$sf\R" "DOWN`nCOPY`nYES"
Check "overwrite YES replaces"       ([IO.File]::ReadAllText("$sf\R\x.txt") -eq 'NEW')

# read-only file deletes; a failing delete is reported and keeps its RO bit
Stage $sf; [IO.File]::WriteAllText("$sf\ro.txt","r"); Set-ItemProperty "$sf\ro.txt" IsReadOnly $true
$o = Run $sf $sf "DOWN`nDEL"
Check "delete read-only file"        (-not (Test-Path "$sf\ro.txt"))
[IO.File]::WriteAllText("$sf\busy.txt","b"); Set-ItemProperty "$sf\busy.txt" IsReadOnly $true
$fs = [IO.File]::Open("$sf\busy.txt",'Open','Read','Read')
$o = Run $sf $sf "DOWN`nDEL"
$fs.Close()
Check "failed delete reported"       ((Test-Path "$sf\busy.txt") -and ($o[23] -match '1 failed'))
Check "failed delete keeps RO bit"   ((Get-Item "$sf\busy.txt").IsReadOnly)
Set-ItemProperty "$sf\busy.txt" IsReadOnly $false

# no console: redirected stdin must exit with a message, not spin
$p = Start-Process "$dir\cc.exe" -RedirectStandardInput "$T\_sk2.txt" -RedirectStandardError "$T\_se.txt" -NoNewWindow -PassThru
$fin = $p.WaitForExit(5000); if (-not $fin) { $p.Kill() }
Check "no console -> exits"          ($fin -and $p.ExitCode -eq 2 -and ((Get-Content "$T\_se.txt" -Raw) -match 'interactive console'))

Write-Host ("`nwincc: {0} passed, {1} failed" -f $pass,$fail)
if ($fail -gt 0) { exit 1 } else { Write-Host "WINCC REGRESSION: PASS"; exit 0 }
