# run_tools.ps1 -- CCDIFF / CCSPLIT / CCJOIN / CCREN in a freshly wiped TT\.
# Asserts each tool's exact stdout, split part sizes+bytes, a byte-exact join
# round-trip and the wildcard rename (with contents kept).
$ErrorActionPreference = "Stop"
$dir  = "C:\LLM\DOS\cc"
$dbox = "$dir\dbstaging\dosbox-staging-v0.82.2\dosbox.exe"
$nasm = "C:\Users\Caldor\AppData\Local\bin\NASM\nasm.exe"
if (-not (Test-Path $nasm)) { $nasm = "nasm" }
$td = "$dir\TT"

foreach ($s in "cdiff","csplit","cjoin","cren") {
    $com = "cc" + $s.Substring(1) + ".com"
    & $nasm -f bin "$dir\$s.asm" -o "$dir\$com" 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Host "ASSEMBLE FAILED: $s"; exit 1 }
}
Write-Host "BUILD OK (4 tools)"

# wipe TT\ so stale outputs from an earlier run can't satisfy any check below
if (Test-Path $td) { Remove-Item $td -Recurse -Force }
New-Item -ItemType Directory -Path $td | Out-Null

# ---- test inputs -----------------------------------------------------------
$same = [byte[]](0..255 + (0..243))                       # 500 bytes
[IO.File]::WriteAllBytes("$td\SAME1.BIN", $same)
[IO.File]::WriteAllBytes("$td\SAME2.BIN", $same)

$da = New-Object byte[] 100; for ($i=0;$i -lt 100;$i++){ $da[$i]=[byte]($i) }
$db = $da.Clone(); $da[50]=0xAA; $db[50]=0xBB
[IO.File]::WriteAllBytes("$td\DIFFA.BIN", $da)
[IO.File]::WriteAllBytes("$td\DIFFB.BIN", $db)

$short = New-Object byte[] 50; for ($i=0;$i -lt 50;$i++){ $short[$i]=[byte]($i) }
$long  = New-Object byte[] 80; for ($i=0;$i -lt 80;$i++){ $long[$i]=[byte]($i) }
[IO.File]::WriteAllBytes("$td\SHORT.BIN", $short)
[IO.File]::WriteAllBytes("$td\LONG.BIN",  $long)

$orig = New-Object byte[] 1000; for ($i=0;$i -lt 1000;$i++){ $orig[$i]=[byte]($i -band 0xFF) }
[IO.File]::WriteAllBytes("$td\ORIG.BIN", $orig)

# CCREN gets its own extension so it can't catch the capture .TXT files
[IO.File]::WriteAllText("$td\REN1.QQQ", "first file")
[IO.File]::WriteAllText("$td\REN2.QQQ", "second file")

$conf = @"
[sdl]
fullscreen = false
[cpu]
core=normal
cputype=486
cycles=max
[autoexec]
@echo off
mount c $dir
c:
cd TT
c:\ccdiff.com SAME1.BIN SAME2.BIN > D_SAME.TXT
c:\ccdiff.com DIFFA.BIN DIFFB.BIN > D_DIFF.TXT
c:\ccdiff.com SHORT.BIN LONG.BIN > D_LEN.TXT
c:\ccsplit.com ORIG.BIN 300 > S_OUT.TXT
c:\ccjoin.com OUT.BIN ORIG > J_OUT.TXT
del *.ZZZ
c:\ccren.com *.QQQ *.ZZZ > R_OUT.TXT
exit
"@
Set-Content -Path "$dir\_tools.conf" -Value $conf -Encoding ASCII

$t0 = Get-Date
$p = Start-Process -FilePath $dbox -ArgumentList @("-conf","$dir\_tools.conf","-noprimaryconf","--exit") -PassThru -WindowStyle Minimized
if (-not $p.WaitForExit(20000)) { $p.Kill() | Out-Null; Write-Host "FAIL: DOSBox hang/timeout (killed after 20s)"; exit 1 }
Start-Sleep -Milliseconds 400

$fail = 0
function Show($f){ if(Test-Path "$td\$f"){ (Get-Content "$td\$f" -Raw).Trim() } else { $script:fail++; "<missing $f>" } }
# exact stdout text of a tool (lines joined with " / ")
function Expect([string]$f, [string]$want) {
    $got = if (Test-Path "$td\$f") { (@(Get-Content "$td\$f" | ForEach-Object { $_.TrimEnd() } | Where-Object { $_ -ne "" })) -join " / " } else { "<missing $f>" }
    if ($got -ceq $want) { Write-Host "  PASS: $f = '$want'" } else { Write-Host "  FAIL: $f want '$want' got '$got'"; $script:fail++ }
}

Write-Host "`n--- CCDIFF ---"
Write-Host ("identical : " + (Show "D_SAME.TXT"))
Write-Host ("differ    : " + (Show "D_DIFF.TXT"))
Write-Host ("length    : " + (Show "D_LEN.TXT"))
Expect "D_SAME.TXT" "identical"
Expect "D_DIFF.TXT" "differ at offset 50: AA vs BB"
Expect "D_LEN.TXT"  "differ: prefix matches up to offset 50 (lengths differ)"

Write-Host "`n--- CCSPLIT ---"
Write-Host (Show "S_OUT.TXT")
Expect "S_OUT.TXT" "split into 4 part(s)"
$off = 0
foreach ($p2 in "001","002","003","004","005") {
    $f = "$td\ORIG.$p2"
    $want = [Math]::Max(0, [Math]::Min(300, $orig.Length - $off))
    if ($want -eq 0) {
        if (Test-Path $f) { Write-Host "  FAIL: ORIG.$p2 exists (only 4 parts expected)"; $fail++ } else { Write-Host "  PASS: no ORIG.$p2" }
        continue
    }
    if (-not (Test-Path $f)) { Write-Host "  FAIL: ORIG.$p2 missing"; $fail++; $off += 300; continue }
    $part = [IO.File]::ReadAllBytes($f)
    $ok = ($part.Length -eq $want)
    if ($ok) { for ($i=0;$i -lt $want;$i++){ if($part[$i] -ne $orig[$off+$i]){ $ok=$false; break } } }
    if ($ok) { Write-Host ("  PASS: ORIG.$p2 = {0} B, bytes {1}..{2} of ORIG.BIN" -f $part.Length, $off, ($off+$want-1)) }
    else     { Write-Host ("  FAIL: ORIG.$p2 = {0} B (want {1} B = bytes {2}..{3} of ORIG.BIN)" -f $part.Length, $want, $off, ($off+$want-1)); $fail++ }
    $off += 300
}

Write-Host "`n--- CCJOIN ---"
Write-Host (Show "J_OUT.TXT")
Expect "J_OUT.TXT" "joined 4 part(s)"
if (Test-Path "$td\OUT.BIN") {
    $out = [IO.File]::ReadAllBytes("$td\OUT.BIN")
    $ok = ($out.Length -eq $orig.Length)
    if ($ok) { for ($i=0;$i -lt $orig.Length;$i++){ if($out[$i] -ne $orig[$i]){ $ok=$false; break } } }
    Write-Host ("  round-trip byte-exact: " + $(if($ok){"PASS ($($out.Length) B)"}else{"FAIL"}))
    if (-not $ok) { $fail++ }
} else { Write-Host "  OUT.BIN missing"; $fail++ }

Write-Host "`n--- CCREN ---"
Write-Host (Show "R_OUT.TXT")
Expect "R_OUT.TXT" "REN1.QQQ -> REN1.ZZZ / REN2.QQQ -> REN2.ZZZ / renamed 2 file(s)"
$renOk = (Test-Path "$td\REN1.ZZZ") -and (Test-Path "$td\REN2.ZZZ") -and -not (Test-Path "$td\REN1.QQQ") -and -not (Test-Path "$td\REN2.QQQ")
if ($renOk) { $renOk = ([IO.File]::ReadAllText("$td\REN1.ZZZ") -ceq "first file") -and ([IO.File]::ReadAllText("$td\REN2.ZZZ") -ceq "second file") }
Write-Host ("  *.QQQ -> *.ZZZ (contents kept): " + $(if($renOk){"PASS"}else{"FAIL"}))
if (-not $renOk) { $fail++ }
if ($fail -gt 0) { Write-Host "`nTOOLS: FAIL ($fail)"; exit 1 } else { Write-Host "`nTOOLS: PASS"; exit 0 }
