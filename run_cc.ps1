# run_cc.ps1 -- build the dist\ folder (via package.ps1) and launch it
# INTERACTIVELY in DOSBox so you can click around and test the real app.
# Quit cc with F10; DOSBox then closes. This is NOT the headless /T harness.

$ErrorActionPreference = "Stop"
$dir  = "C:\LLM\cc"
$dbox = "$dir\dbstaging\dosbox-staging-v0.82.2\dosbox.exe"
$out  = "$dir\dist"

# (re)build the distribution
& "$dir\package.ps1"
if ($LASTEXITCODE -ne 0) { Write-Host "PACKAGE FAILED"; exit 1 }

$conf = @"
[sdl]
fullscreen     = false
window_position = 0,0
[cpu]
core    = normal
cputype = 486
cycles  = max
[autoexec]
@echo off
mount c $out
c:
cc.com
exit
"@
$confPath = "$dir\_run_cc.conf"
Set-Content -Path $confPath -Value $conf -Encoding ASCII

Write-Host "`nLaunching cc in DOSBox (quit with F10)..."
& $dbox -conf $confPath -noprimaryconf
