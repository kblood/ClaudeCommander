$ErrorActionPreference = "Stop"
$dir  = "C:\LLM\cc"
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

if (-not (Test-Path $td)) { New-Item -ItemType Directory -Path $td | Out-Null }

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
$p = Start-Process -FilePath $dbox -ArgumentList @("-conf","$dir\_tools.conf","-noprimaryconf") -PassThru -WindowStyle Minimized
if (-not $p.WaitForExit(20000)) { $p.Kill() | Out-Null }
Start-Sleep -Milliseconds 400

function Show($f){ if(Test-Path "$td\$f"){ (Get-Content "$td\$f" -Raw).Trim() } else { "<missing $f>" } }

Write-Host "`n--- CCDIFF ---"
Write-Host ("identical : " + (Show "D_SAME.TXT"))
Write-Host ("differ    : " + (Show "D_DIFF.TXT"))
Write-Host ("length    : " + (Show "D_LEN.TXT"))

Write-Host "`n--- CCSPLIT ---"
Write-Host (Show "S_OUT.TXT")
foreach ($p2 in "001","002","003","004","005") {
    $f = "$td\ORIG.$p2"
    if (Test-Path $f) { Write-Host ("  ORIG.$p2 = {0} B" -f (Get-Item $f).Length) }
}

Write-Host "`n--- CCJOIN ---"
Write-Host (Show "J_OUT.TXT")
if (Test-Path "$td\OUT.BIN") {
    $out = [IO.File]::ReadAllBytes("$td\OUT.BIN")
    $ok = ($out.Length -eq $orig.Length)
    if ($ok) { for ($i=0;$i -lt $orig.Length;$i++){ if($out[$i] -ne $orig[$i]){ $ok=$false; break } } }
    Write-Host ("  round-trip byte-exact: " + $(if($ok){"PASS ($($out.Length) B)"}else{"FAIL"}))
} else { Write-Host "  OUT.BIN missing" }

Write-Host "`n--- CCREN ---"
Write-Host (Show "R_OUT.TXT")
$renOk = (Test-Path "$td\REN1.ZZZ") -and (Test-Path "$td\REN2.ZZZ") -and -not (Test-Path "$td\REN1.QQQ") -and -not (Test-Path "$td\REN2.QQQ")
Write-Host ("  *.QQQ -> *.ZZZ: " + $(if($renOk){"PASS"}else{"FAIL"}))
