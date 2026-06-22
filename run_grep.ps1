param(
    [string]$text = "wildmatch",
    [string]$startdir = "C:\MOD",
    [string]$mask = "*.INC"
)
$ErrorActionPreference = "Stop"
$dir  = "C:\LLM\cc"
$dbox = "$dir\dbstaging\dosbox-staging-v0.82.2\dosbox.exe"
$nasm = "C:\Users\Caldor\AppData\Local\bin\NASM\nasm.exe"
if (-not (Test-Path $nasm)) { $nasm = "nasm" }

& $nasm -f bin "$dir\cgrep.asm" -o "$dir\ccgrep.com" 2>&1
if ($LASTEXITCODE -ne 0) { Write-Host "ASSEMBLE FAILED"; exit 1 }
Write-Host ("BUILD OK: {0} bytes" -f (Get-Item "$dir\ccgrep.com").Length)

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
if exist grepout.txt del grepout.txt
ccgrep.com $text $startdir $mask > grepout.txt
exit
"@
$confPath = "$dir\_run_grep.conf"
Set-Content -Path $confPath -Value $conf -Encoding ASCII

if (Test-Path "$dir\grepout.txt") { Remove-Item "$dir\grepout.txt" -Force }
$p = Start-Process -FilePath $dbox -ArgumentList @("-conf",$confPath,"-noprimaryconf") -PassThru -WindowStyle Minimized
if (-not $p.WaitForExit(15000)) { $p.Kill() | Out-Null }
Start-Sleep -Milliseconds 300

if (Test-Path "$dir\grepout.txt") {
    Write-Host "===== GREPOUT.TXT ====="
    Get-Content "$dir\grepout.txt"
} else { Write-Host "NO OUTPUT" }
