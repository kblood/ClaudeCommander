param([string]$file = "HEXIN.TXT")
$ErrorActionPreference = "Stop"
$dir  = "C:\LLM\cc"
$dbox = "$dir\dbstaging\dosbox-staging-v0.82.2\dosbox.exe"
$nasm = "C:\Users\Caldor\AppData\Local\bin\NASM\nasm.exe"

& $nasm -f bin "$dir\chex.asm" -o "$dir\cchex.com" 2>&1
if ($LASTEXITCODE -ne 0) { Write-Host "ASSEMBLE FAILED"; exit 1 }
Write-Host ("BUILD OK: {0} bytes" -f (Get-Item "$dir\cchex.com").Length)

# known 20-byte input
[IO.File]::WriteAllText("$dir\HEXIN.TXT","ABCDEFGHIJ0123456789")

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
if exist hexout.txt del hexout.txt
cchex.com $file > hexout.txt
exit
"@
Set-Content -Path "$dir\_run_hex.conf" -Value $conf -Encoding ASCII

if (Test-Path "$dir\hexout.txt") { Remove-Item "$dir\hexout.txt" -Force }
$p = Start-Process -FilePath $dbox -ArgumentList @("-conf","$dir\_run_hex.conf","-noprimaryconf") -PassThru -WindowStyle Minimized
if (-not $p.WaitForExit(12000)) { $p.Kill() | Out-Null }
Start-Sleep -Milliseconds 300

if (Test-Path "$dir\hexout.txt") {
    Write-Host "===== HEXOUT.TXT ====="
    Get-Content "$dir\hexout.txt"
} else { Write-Host "NO OUTPUT" }
