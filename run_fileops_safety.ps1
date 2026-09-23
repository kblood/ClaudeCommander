# run_fileops_safety.ps1 -- data-safety regression gate for the Layer-3 file
# helpers: CCSPLIT, CCJOIN, CCREN, CCEDIT, CCHEXED, CCTOUCH.
#
# Everything (build output, staged files, DOSBox conf, captures) lives under
# $env:TEMP\cc_fileops_safety -- nothing is written to the repo, so this can run
# concurrently with the other run_*.ps1 tests. One DOSBox-staging session runs
# every case from a generated autoexec; each case records its exit code
# ("<case> EL=0|1" in R.TXT) and the host side then byte-compares the files.
#
# Cases: split refusing a part name == source (source intact); split in a
# dotted directory writes the parts next to the file; split->join round trip
# (incl. exact-multiple size, no empty trailing part); stale higher parts
# deleted; 999-part cap and bad sizes rejected before anything is written;
# join refusing to clobber a part / touching nothing without parts; rename with
# a source directory (and exit 1 on a failed rename); CCEDIT refusing a >48K
# file, safe save via .$$$, save-on-quit prompt (Y / N / Esc / exhausted
# script), save failure on a read-only file; CCHEXED prompt; CCTOUCH rejecting
# malformed/out-of-range dates.
# Exit 0 = PASS, 1 = FAIL.
$ErrorActionPreference = "Stop"
$dir  = "C:\LLM\DOS\cc"
$dbox = "$dir\dbstaging\dosbox-staging-v0.82.2\dosbox.exe"
$nasm = "C:\Users\Caldor\AppData\Local\bin\NASM\nasm.exe"
if (-not (Test-Path $nasm)) { $nasm = "nasm" }

$root = Join-Path $env:TEMP "cc_fileops_safety"
$w    = "$root\w"                       # mounted as C: inside DOSBox
if (Test-Path $w) { Remove-Item $w -Recurse -Force }
New-Item -ItemType Directory -Path "$w\T" -Force | Out-Null
New-Item -ItemType Directory -Path "$w\OUT" -Force | Out-Null

# ---- build (straight into the staging dir) ---------------------------------
$tools = [ordered]@{ csplit="CCSPLIT"; cjoin="CCJOIN"; cren="CCREN"; cce="CCEDIT"; chexed="CCHEXED"; ctouch="CCTOUCH" }
foreach ($src in $tools.Keys) {
    & $nasm -f bin -i "$dir/" "$dir\$src.asm" -o "$w\T\$($tools[$src]).COM" 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Host "ASSEMBLE FAILED: $src.asm"; exit 1 }
}
Write-Host "BUILD OK (6 helpers) -> $w\T"

# ---- helpers ----------------------------------------------------------------
$rng = New-Object System.Random 4711
function RandBytes([int]$n) { $b = New-Object byte[] $n; $rng.NextBytes($b); return ,$b }
function Put([string]$rel, [byte[]]$data) {
    $p = Join-Path $w $rel
    New-Item -ItemType Directory -Path (Split-Path $p) -Force | Out-Null
    [IO.File]::WriteAllBytes($p, $data)
}
function PutText([string]$rel, [string]$s) { Put $rel ([Text.Encoding]::ASCII.GetBytes($s)) }
function Keys([string]$rel, [int[]]$k) { Put $rel ([byte[]]$k) }
function SameBytes([string]$rel, [byte[]]$exp) {
    $p = Join-Path $w $rel
    if (-not (Test-Path $p)) { return $false }
    $got = [IO.File]::ReadAllBytes($p)
    if ($got.Length -ne $exp.Length) { return $false }
    for ($i = 0; $i -lt $got.Length; $i++) { if ($got[$i] -ne $exp[$i]) { return $false } }
    return $true
}
function Exists([string]$rel) { Test-Path (Join-Path $w $rel) }

$bat = New-Object System.Collections.Generic.List[string]
function Dcd([string]$d) { $bat.Add("cd $d") }
function Run([string]$name, [string]$cmd) {
    $bat.Add("$cmd > C:\OUT\$name.TXT")
    $bat.Add("if errorlevel 1 echo $name EL=1 >> C:\R.TXT")
    $bat.Add("if not errorlevel 1 echo $name EL=0 >> C:\R.TXT")
}

# key codes (al, ah pairs)
$F2 = @(0x00,0x3C); $F10 = @(0x00,0x44); $ESC = @(0x1B,0x01)
function K([char]$c) { return @([int][byte]$c, 0x00) }

# ---- stage inputs + build the DOS script ------------------------------------
# A. CCSPLIT must refuse a part name that resolves to the source
$backup = RandBytes 3000; Put "SAME\BACKUP.001" $backup
$big3   = RandBytes 5000; Put "SAME\BIG.003" $big3
Dcd "\SAME"
Run "SAME1"  "C:\T\CCSPLIT.COM BACKUP.001 1K"
Run "SAME3"  "C:\T\CCSPLIT.COM BIG.003 1K"
Dcd "\"
Run "SAMELC" "C:\T\CCSPLIT.COM same\backup.001 1k"

# B. dotted directory: parts go next to the file, not into the parent
$readme = RandBytes 3000; Put "DOTTED\DOOM.V19\README" $readme
Dcd "\DOTTED"
Run "DOTSPL" "C:\T\CCSPLIT.COM DOOM.V19\README 1K"
Run "DOTJOIN" "C:\T\CCJOIN.COM DOOM.V19\README.OUT DOOM.V19\README"

# C. round trips
$orig  = RandBytes 5000; Put "RT\ORIG.BIN" $orig
$exact = RandBytes 4096; Put "RT\EXACT.BIN" $exact
$meg   = RandBytes 3000; Put "RT\MEG.BIN" $meg
Dcd "\RT"
Run "RTSPL"  "C:\T\CCSPLIT.COM ORIG.BIN 1K"
Run "RTJOIN" "C:\T\CCJOIN.COM OUT.BIN ORIG"
Run "EXSPL"  "C:\T\CCSPLIT.COM EXACT.BIN 1024"
Run "EXJOIN" "C:\T\CCJOIN.COM EXOUT.BIN EXACT"
Run "MEGSPL" "C:\T\CCSPLIT.COM MEG.BIN 1M"

# D. stale higher-numbered parts from an earlier split are removed
$stale = RandBytes 5000; Put "STALE\STALE.BIN" $stale
Put "STALE\STALE.006" (RandBytes 100); Put "STALE\STALE.007" (RandBytes 100)
Put "STALE\STALE.009" (RandBytes 100)   # after a gap: must survive
Dcd "\STALE"
Run "STSPL"  "C:\T\CCSPLIT.COM STALE.BIN 1K"
Run "STJOIN" "C:\T\CCJOIN.COM SOUT.BIN STALE"

# E. part cap + size syntax: rejected before anything is written
$capb = RandBytes 1500; Put "SIZE\CAP.BIN" $capb
$sb   = RandBytes 3000; Put "SIZE\S.BIN" $sb
Dcd "\SIZE"
Run "CAP"    "C:\T\CCSPLIT.COM CAP.BIN 1"
Run "SZDOT"  "C:\T\CCSPLIT.COM S.BIN 1.44M"
Run "SZSUF"  "C:\T\CCSPLIT.COM S.BIN 12X"
Run "SZNUM"  "C:\T\CCSPLIT.COM S.BIN K"
Run "SZTAIL" "C:\T\CCSPLIT.COM S.BIN 2KB"

# F. CCJOIN must not clobber
$jall = RandBytes 2000; $j1 = $jall[0..1023]; $j2 = $jall[1024..1999]
Put "JOIN\J.001" $j1; Put "JOIN\J.002" $j2
$jbin = RandBytes 777; Put "JOIN\J.BIN" $jbin
$keep = RandBytes 555; Put "JOIN\KEEP.BIN" $keep
Dcd "\JOIN"
Run "JPART"  "C:\T\CCJOIN.COM J.001 J"
Run "JPART2" "C:\T\CCJOIN.COM j.002 J"
Run "JSELF"  "C:\T\CCJOIN.COM J.BIN J.BIN"
Run "JNONE"  "C:\T\CCJOIN.COM KEEP.BIN NOPE"

# G. CCREN with a source directory
PutText "REN\SUB\A.TXT" "a"; PutText "REN\SUB\B.TXT" "b"; PutText "REN\A.TXT" "decoy"
PutText "REN\F\X.TXT" "x"; PutText "REN\F\X.BAK" "already here"
Dcd "\REN"
Run "RENSUB" "C:\T\CCREN.COM SUB\*.TXT *.BAK"
Run "RENDRV" "C:\T\CCREN.COM C:\REN\SUB\*.BAK *.OLD"
Run "RENFAIL" "C:\T\CCREN.COM F\*.TXT *.BAK"
Run "RENDST" "C:\T\CCREN.COM A.TXT SUB\*.XYZ"

# H. CCEDIT
$bigtxt = New-Object System.Text.StringBuilder
for ($i = 0; $bigtxt.Length -lt 100000; $i++) { [void]$bigtxt.Append(("line {0:D6} the quick brown fox`r`n" -f $i)) }
$bigBytes = [Text.Encoding]::ASCII.GetBytes($bigtxt.ToString()); Put "EDBIG\BIG.TXT" $bigBytes
Keys "EDBIG\cce.key" ((K 'X') + $F2 + $F10)
$hello = [Text.Encoding]::ASCII.GetBytes("Hello`r`nWorld`r`n")
$x48 = New-Object byte[] 49152; for ($i=0;$i -lt 49152;$i++){ $x48[$i] = 0x41 + ($i % 26) }
Put "ED48\FULL.TXT" $x48                         # exactly 48K: still editable
Keys "ED48\cce.key" ($F10)
Put "EDOK\T.TXT" $hello;  Keys "EDOK\cce.key" ((K 'X') + $F2 + $F10)
Put "EDY\T.TXT" $hello;   Keys "EDY\cce.key"  ((K 'X') + $ESC + (K 'y'))
Put "EDN\T.TXT" $hello;   Keys "EDN\cce.key"  ((K 'X') + $ESC + (K 'n'))
Put "EDC\T.TXT" $hello;   Keys "EDC\cce.key"  ((K 'X') + $ESC + $ESC + (K 'Z') + $F10 + (K 'Y'))
Put "EDX\T.TXT" $hello;   Keys "EDX\cce.key"  ((K 'X'))           # script ends dirty
Put "EDRO\T.TXT" $hello;  Keys "EDRO\cce.key" ((K 'X') + $F2 + $F10)   # save fails; exhaust -> N
Keys "EDNEW\cce.key" ((K 'N') + $F2 + $F10)
Put "ED.DIR\NOEXT" $hello; Keys "ED.DIR\cce.key" ((K 'X') + $F2 + $F10)
Dcd "\EDBIG";  Run "EDBIG" "C:\T\CCEDIT.COM /T BIG.TXT"
Dcd "\ED48";   Run "ED48"  "C:\T\CCEDIT.COM /T FULL.TXT"
Dcd "\EDOK";   Run "EDOK"  "C:\T\CCEDIT.COM /T T.TXT"
Dcd "\EDY";    Run "EDY"   "C:\T\CCEDIT.COM /T T.TXT"
Dcd "\EDN";    Run "EDN"   "C:\T\CCEDIT.COM /T T.TXT"
Dcd "\EDC";    Run "EDC"   "C:\T\CCEDIT.COM /T T.TXT"
Dcd "\EDX";    Run "EDX"   "C:\T\CCEDIT.COM /T T.TXT"
Dcd "\EDRO";   $bat.Add("attrib +r T.TXT"); Run "EDRO" "C:\T\CCEDIT.COM /T T.TXT"; $bat.Add("attrib -r T.TXT")
Dcd "\EDNEW";  Run "EDNEW" "C:\T\CCEDIT.COM /T NEW.TXT"
Dcd "\ED.DIR"; Run "EDDIR" "C:\T\CCEDIT.COM /T NOEXT"

# I. CCHEXED
$z4 = [byte[]](0,0,0,0)
Put "HXOK\A.BIN" $z4; Keys "HXOK\CCX.KEY" ((K 'A') + (K 'B') + $F2)
Put "HXY\A.BIN" $z4;  Keys "HXY\CCX.KEY"  ((K 'A') + (K 'B') + $ESC + (K 'Y'))
Put "HXN\A.BIN" $z4;  Keys "HXN\CCX.KEY"  ((K 'A') + (K 'B') + $ESC + (K 'n'))
Put "HXX\A.BIN" $z4;  Keys "HXX\CCX.KEY"  ((K 'A') + (K 'B'))    # exhausted while modified
Dcd "\HXOK"; Run "HXOK" "C:\T\CCHEXED.COM A.BIN /T"
Dcd "\HXY";  Run "HXY"  "C:\T\CCHEXED.COM A.BIN /T"
Dcd "\HXN";  Run "HXN"  "C:\T\CCHEXED.COM A.BIN /T"
Dcd "\HXX";  Run "HXX"  "C:\T\CCHEXED.COM A.BIN /T"

# J. CCTOUCH date validation (bad input must not touch the file)
PutText "TOUCH\BAD.TXT" "x"; PutText "TOUCH\GOOD.TXT" "x"
$badStamp = [datetime]::new(2019, 7, 1, 12, 0, 0, [DateTimeKind]::Utc)
[IO.File]::SetLastWriteTimeUtc("$w\TOUCH\BAD.TXT", $badStamp)
$badDates = [ordered]@{
    TBYY="24-05-01"; TBMON="2024-13-01"; TBMON0="2024-00-10"; TBDAY="2024-05-32"; TBDAY0="2024-05-00"
    TBY79="1979-12-31"; TBY2108="2108-01-01"; TBTAIL="2024-05-01x"; TBSEP="2024--05-01"
}
Dcd "\TOUCH"
foreach ($k in $badDates.Keys) { Run $k "C:\T\CCTOUCH.COM BAD.TXT $($badDates[$k])" }
Run "TBHR"  "C:\T\CCTOUCH.COM BAD.TXT 2024-05-01 24:00"
Run "TBMIN" "C:\T\CCTOUCH.COM BAD.TXT 2024-05-01 10:60"
Run "TBSEC" "C:\T\CCTOUCH.COM BAD.TXT 2024-05-01 10:20:60"
Run "TBTIME" "C:\T\CCTOUCH.COM BAD.TXT 2024-05-01 10"
Run "TGOOD" "C:\T\CCTOUCH.COM GOOD.TXT 2024-05-01 10:20:30"
Run "TEDGE" "C:\T\CCTOUCH.COM GOOD.TXT 2107-12-31 23:59:58"

$bat.Add("echo DONE >> C:\R.TXT")

# ---- run DOSBox --------------------------------------------------------------
$conf = @"
[sdl]
fullscreen = false
[cpu]
core    = normal
cputype = 486
cycles  = max
[autoexec]
@echo off
mount c $w
c:
$($bat -join "`r`n")
exit
"@
$confPath = "$root\run_fileops_safety.conf"
Set-Content -Path $confPath -Value $conf -Encoding ASCII
# --exit: close DOSBox when autoexec ends even if the batch "exit" is ignored
$t0 = Get-Date
$p = Start-Process -FilePath $dbox -ArgumentList @("-conf",$confPath,"-noprimaryconf","--exit") -PassThru -WindowStyle Minimized
if (-not $p.WaitForExit(90000)) { $p.Kill() | Out-Null; Write-Host "FAIL: DOSBox hang/timeout (killed after 90s)"; exit 1 }
else { Write-Host ("DOSBox finished in {0:N1}s" -f ((Get-Date) - $t0).TotalSeconds) }
Start-Sleep -Milliseconds 400

if (-not (Test-Path "$w\R.TXT")) { Write-Host "FAIL: no R.TXT produced"; exit 1 }
$r = Get-Content "$w\R.TXT" -Raw
$el = @{}
foreach ($m in [regex]::Matches($r, '(?m)^(\S+) EL=(\d)')) { $el[$m.Groups[1].Value] = [int]$m.Groups[2].Value }
function Out1([string]$name) { $f = "$w\OUT\$name.TXT"; if (Test-Path $f) { ((Get-Content $f -Raw) -replace '\s+$','') } else { "<none>" } }

$script:pass = 0; $script:fail = 0
function Check([string]$name, [bool]$cond, [string]$detail = "") {
    if ($cond) { Write-Host ("  PASS  {0}" -f $name); $script:pass++ }
    else       { Write-Host ("  FAIL  {0}  {1}" -f $name, $detail); $script:fail++ }
}
function EL([string]$case, [int]$want) {
    $got = if ($el.ContainsKey($case)) { $el[$case] } else { -1 }
    Check "$case exit=$want" ($got -eq $want) ("(got {0}; out: {1})" -f $got, (Out1 $case))
}

Write-Host "`n--- CCSPLIT: same-name refusal ---"
EL "SAME1" 1;  Check "BACKUP.001 intact" (SameBytes "SAME\BACKUP.001" $backup)
Check "no BACKUP.002 created" (-not (Exists "SAME\BACKUP.002"))
EL "SAME3" 1;  Check "BIG.003 intact" (SameBytes "SAME\BIG.003" $big3)
Check "nothing written before refusing (no BIG.001)" (-not (Exists "SAME\BIG.001"))
EL "SAMELC" 1; Check "BACKUP.001 intact after lowercase path" (SameBytes "SAME\BACKUP.001" $backup)
Write-Host ("  msg: " + (Out1 "SAME1"))

Write-Host "`n--- CCSPLIT: dotted directory ---"
EL "DOTSPL" 0
Check "parts next to the file (DOOM.V19\README.001..003)" ((Exists "DOTTED\DOOM.V19\README.001") -and (Exists "DOTTED\DOOM.V19\README.003") -and -not (Exists "DOTTED\DOOM.V19\README.004"))
Check "no DOOM.001 in the parent" (-not (Exists "DOTTED\DOOM.001"))
EL "DOTJOIN" 0; Check "dotted-dir join byte-identical" (SameBytes "DOTTED\DOOM.V19\README.OUT" $readme)

Write-Host "`n--- CCSPLIT/CCJOIN: round trip ---"
EL "RTSPL" 0; Write-Host ("  " + (Out1 "RTSPL"))
EL "RTJOIN" 0; Check "ORIG round trip byte-identical (5000 B)" (SameBytes "RT\OUT.BIN" $orig)
EL "EXSPL" 0; Check "exact multiple -> 4 parts, no empty EXACT.005" ((Exists "RT\EXACT.004") -and -not (Exists "RT\EXACT.005"))
EL "EXJOIN" 0; Check "EXACT round trip byte-identical" (SameBytes "RT\EXOUT.BIN" $exact)
EL "MEGSPL" 0; Check "1M suffix -> single part" (SameBytes "RT\MEG.001" $meg)

Write-Host "`n--- CCSPLIT: stale parts ---"
EL "STSPL" 0
Check "stale STALE.006/.007 deleted" (-not (Exists "STALE\STALE.006") -and -not (Exists "STALE\STALE.007"))
Check "STALE.009 after the gap untouched" (Exists "STALE\STALE.009")
EL "STJOIN" 0; Check "STALE join byte-identical (no stale data appended)" (SameBytes "STALE\SOUT.BIN" $stale)

Write-Host "`n--- CCSPLIT: cap / size syntax ---"
EL "CAP" 1; Check "no CAP.001 written" (-not (Exists "SIZE\CAP.001")); Write-Host ("  msg: " + (Out1 "CAP"))
EL "SZDOT" 1; EL "SZSUF" 1; EL "SZNUM" 1; EL "SZTAIL" 1
Check "no S.001 written for bad sizes" (-not (Exists "SIZE\S.001"))

Write-Host "`n--- CCJOIN: no clobber ---"
EL "JPART" 1;  Check "J.001 intact" (SameBytes "JOIN\J.001" ([byte[]]$j1))
EL "JPART2" 1; Check "J.002 intact" (SameBytes "JOIN\J.002" ([byte[]]$j2))
EL "JSELF" 1;  Check "J.BIN intact (CCJOIN J.BIN J.BIN)" (SameBytes "JOIN\J.BIN" $jbin)
EL "JNONE" 1;  Check "KEEP.BIN untouched when no parts exist" (SameBytes "JOIN\KEEP.BIN" $keep)
Write-Host ("  msgs: " + (Out1 "JPART") + " | " + (Out1 "JSELF") + " | " + (Out1 "JNONE"))

Write-Host "`n--- CCREN: source directory ---"
EL "RENSUB" 0; Check "RENSUB renamed 2" ((Out1 "RENSUB") -match 'renamed 2 file')
EL "RENDRV" 0; Check "RENDRV (drive+path) renamed 2" ((Out1 "RENDRV") -match 'renamed 2 file')
Check "SUB\A,B renamed (.TXT -> .BAK -> .OLD)" ((Exists "REN\SUB\A.OLD") -and (Exists "REN\SUB\B.OLD") -and -not (Exists "REN\SUB\A.TXT") -and -not (Exists "REN\SUB\A.BAK"))
Check "cwd decoy A.TXT untouched" ((Exists "REN\A.TXT") -and -not (Exists "REN\A.BAK"))
EL "RENFAIL" 1; Check "failed rename leaves both files" ((Exists "REN\F\X.TXT") -and (Exists "REN\F\X.BAK"))
EL "RENDST" 1
Write-Host ("  " + ((Out1 "RENSUB") -replace "`r`n", " / "))

Write-Host "`n--- CCEDIT ---"
$xhello = [Text.Encoding]::ASCII.GetBytes("XHello`r`nWorld`r`n")
EL "EDBIG" 1; Check "100K file unchanged" (SameBytes "EDBIG\BIG.TXT" $bigBytes); Check "no BIG.`$`$`$" (-not (Exists "EDBIG\BIG.`$`$`$"))
Write-Host ("  msg: " + (Out1 "EDBIG"))
EL "ED48" 0; Check "exactly-48K file opens and is untouched" (SameBytes "ED48\FULL.TXT" $x48)
EL "EDOK" 0; Check "X,F2,F10 saved" (SameBytes "EDOK\T.TXT" $xhello); Check "temp T.`$`$`$ cleaned up" (-not (Exists "EDOK\T.`$`$`$"))
EL "EDY" 0;  Check "X,Esc,Y -> saved" (SameBytes "EDY\T.TXT" $xhello)
$dumpY = if (Exists "EDY\CCEDUMP.TXT") { Get-Content "$w\EDY\CCEDUMP.TXT" -Raw } else { "" }
Check "prompt text shown" ($dumpY -match 'Save changes\? \(Y/N/Esc\)')
EL "EDN" 0;  Check "X,Esc,N -> discarded" (SameBytes "EDN\T.TXT" $hello)
EL "EDC" 0;  Check "X,Esc,Esc(cancel),Z,F10,Y -> XZ saved" (SameBytes "EDC\T.TXT" ([Text.Encoding]::ASCII.GetBytes("XZHello`r`nWorld`r`n")))
EL "EDX" 0;  Check "script exhausted while dirty -> terminates, discarded" (SameBytes "EDX\T.TXT" $hello)
EL "EDRO" 0; Check "read-only: save fails, original intact" (SameBytes "EDRO\T.TXT" $hello)
Check "read-only: no T.`$`$`$ left" (-not (Exists "EDRO\T.`$`$`$"))
$dumpRO = if (Exists "EDRO\CCEDUMP.TXT") { Get-Content "$w\EDRO\CCEDUMP.TXT" -Raw } else { "" }
Check "read-only: SAVE FAILED shown, dirty kept" (($dumpRO -match 'SAVE FAILED') -and ($dumpRO -match 'T\.TXT\*'))
EL "EDNEW" 0; Check "new file created" (SameBytes "EDNEW\NEW.TXT" ([Text.Encoding]::ASCII.GetBytes("N")))
EL "EDDIR" 0; Check "dotted dir, no extension: saved in place" (SameBytes "ED.DIR\NOEXT" $xhello)
Check "dotted dir: temp named NOEXT.`$`$`$ and cleaned (no ED.`$`$`$)" (-not (Exists "ED.DIR\NOEXT.`$`$`$") -and -not (Exists "ED.`$`$`$"))

Write-Host "`n--- CCHEXED ---"
$abz = [byte[]](0xAB,0,0,0)
EL "HXOK" 0; Check "A,B,F2 -> AB 00 00 00" (SameBytes "HXOK\A.BIN" $abz)
EL "HXY" 0;  Check "A,B,Esc,Y -> saved" (SameBytes "HXY\A.BIN" $abz)
EL "HXN" 0;  Check "A,B,Esc,N -> discarded" (SameBytes "HXN\A.BIN" $z4)
EL "HXX" 0;  Check "exhausted while modified -> terminates, discarded" (SameBytes "HXX\A.BIN" $z4)

Write-Host "`n--- CCTOUCH ---"
foreach ($k in @($badDates.Keys) + @("TBHR","TBMIN","TBSEC","TBTIME")) { EL $k 1 }
Check "BAD.TXT timestamp untouched" ((Get-Item "$w\TOUCH\BAD.TXT").LastWriteTimeUtc -eq $badStamp)
EL "TGOOD" 0; Check "good date confirmed" ((Out1 "TGOOD") -match 'GOOD\.TXT\s+2024-05-01 10:20:30')
EL "TEDGE" 0; Check "2107-12-31 23:59:58 accepted" ((Out1 "TEDGE") -match '2107-12-31 23:59:58')
Write-Host ("  msg: " + ((Out1 "TBYY") -split "`r`n")[0])

Check "DOSBox script ran to the end (no helper hung)" ($r -match 'DONE')
Write-Host ("`nFILEOPS SAFETY: {0} passed, {1} failed" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { Write-Host "FILEOPS SAFETY: FAIL"; exit 1 }
Write-Host "FILEOPS SAFETY: PASS"
exit 0
