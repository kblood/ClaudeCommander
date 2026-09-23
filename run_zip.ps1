# run_zip.ps1 -- CCZIP lists a known two-member zip; asserts names+sizes+method.
$ErrorActionPreference = "Stop"
$dir  = "C:\LLM\DOS\cc"
$dbox = "$dir\dbstaging\dosbox-staging-v0.82.2\dosbox.exe"
$nasm = "C:\Users\Caldor\AppData\Local\bin\NASM\nasm.exe"
if (-not (Test-Path $nasm)) { $nasm = "nasm" }

& $nasm -f bin "$dir\czip.asm" -o "$dir\cczip.com" 2>&1
if ($LASTEXITCODE -ne 0) { Write-Host "ASSEMBLE FAILED"; exit 1 }
Write-Host ("BUILD OK: {0} bytes" -f (Get-Item "$dir\cczip.com").Length)

# build a known test zip
[IO.File]::WriteAllText("$dir\TA.TXT", "hello alpha")
[IO.File]::WriteAllText("$dir\TB.TXT", ("x" * 5000))
if (Test-Path "$dir\ZTEST.ZIP") { Remove-Item "$dir\ZTEST.ZIP" -Force }
Compress-Archive -Path "$dir\TA.TXT","$dir\TB.TXT" -DestinationPath "$dir\ZTEST.ZIP"

$conf = @"
[sdl]
fullscreen = false
[cpu]
core    = normal
cputype = 486
cycles  = max
[autoexec]
@echo off
mount c $dir
c:
if exist ziplist.txt del ziplist.txt
cczip.com ZTEST.ZIP > ziplist.txt
exit
"@
$confPath = "$dir\_run_zip.conf"
Set-Content -Path $confPath -Value $conf -Encoding ASCII

if (Test-Path "$dir\ziplist.txt") { Remove-Item "$dir\ziplist.txt" -Force }
$p = Start-Process -FilePath $dbox -ArgumentList @("-conf",$confPath,"-noprimaryconf","--exit") -PassThru -WindowStyle Minimized
if (-not $p.WaitForExit(12000)) { $p.Kill() | Out-Null; Write-Host "FAIL: DOSBox hang/timeout (killed after 12s)"; exit 1 }
Start-Sleep -Milliseconds 300

if (-not (Test-Path "$dir\ziplist.txt")) { Write-Host "NO OUTPUT"; exit 1 }
Write-Host "===== ZIPLIST.TXT ====="
Get-Content "$dir\ziplist.txt"
Write-Host "======================="

# one row per member: name, uncompressed size, method (whitespace-normalised)
$expected = @("TA.TXT 11 bytes (deflated)", "TB.TXT 5000 bytes (deflated)")
$got = @(Get-Content "$dir\ziplist.txt" | ForEach-Object { ($_ -replace '\s+', ' ').Trim() } | Where-Object { $_ -ne "" })
$fail = 0
foreach ($e in $expected) {
    if ($got -ccontains $e) { Write-Host "PASS: member '$e'" } else { Write-Host "FAIL: missing member row '$e'"; $fail++ }
}
if ($got.Count -eq $expected.Count) { Write-Host "PASS: exactly $($expected.Count) member rows" }
else { Write-Host ("FAIL: got {0} rows, want {1}" -f $got.Count, $expected.Count); $fail++ }
if ($fail -gt 0) { Write-Host "ZIP: FAIL ($fail)"; exit 1 }
Write-Host "ZIP: PASS"
exit 0
