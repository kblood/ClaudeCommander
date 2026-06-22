param(
    [string]$pattern = "*.INC",
    [string]$startdir = "C:\"
)
$ErrorActionPreference = "Stop"
$dir  = "C:\LLM\cc"
$dbox = "$dir\dbstaging\dosbox-staging-v0.82.2\dosbox.exe"
$nasm = "C:\Users\Caldor\AppData\Local\bin\NASM\nasm.exe"
if (-not (Test-Path $nasm)) { $nasm = "nasm" }

& $nasm -f bin "$dir\cfind.asm" -o "$dir\ccfind.com" 2>&1
if ($LASTEXITCODE -ne 0) { Write-Host "ASSEMBLE FAILED"; exit 1 }
Write-Host ("BUILD OK: {0} bytes" -f (Get-Item "$dir\ccfind.com").Length)

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
if exist findout.txt del findout.txt
ccfind.com $pattern $startdir > findout.txt
exit
"@
$confPath = "$dir\_run_find.conf"
Set-Content -Path $confPath -Value $conf -Encoding ASCII

if (Test-Path "$dir\findout.txt") { Remove-Item "$dir\findout.txt" -Force }
$p = Start-Process -FilePath $dbox -ArgumentList @("-conf",$confPath,"-noprimaryconf") -PassThru -WindowStyle Minimized
if (-not $p.WaitForExit(12000)) { $p.Kill() | Out-Null }
Start-Sleep -Milliseconds 300

if (Test-Path "$dir\findout.txt") {
    Write-Host "===== FINDOUT.TXT ====="
    Get-Content "$dir\findout.txt"
} else { Write-Host "NO OUTPUT" }
