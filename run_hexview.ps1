# run_hexview.ps1 -- /T harness test for the built-in F3 hex view (toggle H).
# Builds cc.com (std, with -i so includes resolve), sets up a clean directory
# containing exactly one viewable text file, then drives: Down -> F3 -> h (hex)
# -> Down (scroll) -> Esc, dumping every frame to CCDUMP.TXT.
$ErrorActionPreference = "Stop"
$dir  = "C:\LLM\cc"
$dbox = "$dir\dbstaging\dosbox-staging-v0.82.2\dosbox.exe"
$nasm = "C:\Users\Caldor\AppData\Local\bin\NASM\nasm.exe"
if (-not (Test-Path $nasm)) { $nasm = "nasm" }

& $nasm -f bin -i "$dir/" "$dir\cc.asm" -o "$dir\cc.com" 2>&1
if ($LASTEXITCODE -ne 0) { Write-Host "ASSEMBLE FAILED"; exit 1 }
Write-Host ("BUILD OK: {0} bytes" -f (Get-Item "$dir\cc.com").Length)

$td = "$dir\_hxtest"
if (Test-Path $td) { Remove-Item $td -Recurse -Force }
New-Item -ItemType Directory -Path $td | Out-Null

# 36 bytes: three hex rows (16 + 16 + 4) of fully predictable content
[IO.File]::WriteAllText("$td\HEXIN.TXT","0123456789ABCDEFGHIJKLMNOPQRSTUVwxyz")

# key script (al, ah) pairs: End (-> HEXIN.TXT, last entry), F3, 'h', Down, Esc
$keys = [byte[]](0x00,0x4F, 0x00,0x3D, 0x68,0x00, 0x00,0x50, 0x1B,0x01)
[IO.File]::WriteAllBytes("$td\cc.key",$keys)

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
mount d $td
d:
if exist ccdump.txt del ccdump.txt
c:\cc.com /T
exit
"@
Set-Content -Path "$dir\_run_hexview.conf" -Value $conf -Encoding ASCII

if (Test-Path "$td\CCDUMP.TXT") { Remove-Item "$td\CCDUMP.TXT" -Force }
$p = Start-Process -FilePath $dbox -ArgumentList @("-conf","$dir\_run_hexview.conf","-noprimaryconf") -PassThru -WindowStyle Minimized
if (-not $p.WaitForExit(15000)) { $p.Kill() | Out-Null }
Start-Sleep -Milliseconds 300

if (Test-Path "$td\CCDUMP.TXT") {
    Write-Host "===== CCDUMP.TXT ====="
    Get-Content "$td\CCDUMP.TXT" -Raw
} else { Write-Host "NO DUMP PRODUCED" }
