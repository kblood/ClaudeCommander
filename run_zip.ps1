$ErrorActionPreference = "Stop"
$dir  = "C:\LLM\cc"
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
$p = Start-Process -FilePath $dbox -ArgumentList @("-conf",$confPath,"-noprimaryconf") -PassThru -WindowStyle Minimized
if (-not $p.WaitForExit(12000)) { $p.Kill() | Out-Null }
Start-Sleep -Milliseconds 300

if (Test-Path "$dir\ziplist.txt") {
    Write-Host "===== ZIPLIST.TXT ====="
    Get-Content "$dir\ziplist.txt"
} else { Write-Host "NO OUTPUT" }
