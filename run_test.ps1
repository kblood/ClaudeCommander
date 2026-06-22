param(
    [string]$ccArgs = "/D",
    [string]$keyfile = ""
)
$ErrorActionPreference = "Stop"
$dir   = "C:\LLM\cc"
$dbox  = "$dir\dbstaging\dosbox-staging-v0.82.2\dosbox.exe"
$nasm  = "C:\Users\Caldor\AppData\Local\bin\NASM\nasm.exe"

# 1. assemble
& $nasm -f bin "$dir\cc.asm" -o "$dir\cc.com" 2>&1
if ($LASTEXITCODE -ne 0) { Write-Host "ASSEMBLE FAILED"; exit 1 }
Write-Host ("BUILD OK: {0} bytes" -f (Get-Item "$dir\cc.com").Length)

# 2. optional key script
if ($keyfile -ne "") { Copy-Item $keyfile "$dir\cc.key" -Force }
elseif (Test-Path "$dir\cc.key") { Remove-Item "$dir\cc.key" -Force }

# 3. generate conf
$conf = @"
[sdl]
fullscreen = false
window_position = 0,0
[cpu]
core    = normal
cputype = 486
cycles  = max
[autoexec]
@echo off
mount c $dir
c:
if exist ccdump.txt del ccdump.txt
cc.com $ccArgs
exit
"@
$confPath = "$dir\_run.conf"
Set-Content -Path $confPath -Value $conf -Encoding ASCII

# 4. run with timeout
if (Test-Path "$dir\CCDUMP.TXT") { Remove-Item "$dir\CCDUMP.TXT" -Force }
$p = Start-Process -FilePath $dbox -ArgumentList @("-conf",$confPath,"-noprimaryconf") -PassThru -WindowStyle Minimized
if (-not $p.WaitForExit(12000)) { $p.Kill() | Out-Null }
Start-Sleep -Milliseconds 300

# 5. show dump
if (Test-Path "$dir\CCDUMP.TXT") {
    Write-Host "===== CCDUMP.TXT ====="
    Get-Content "$dir\CCDUMP.TXT" -Raw
} else {
    Write-Host "NO DUMP PRODUCED"
}
