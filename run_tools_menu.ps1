# run_tools_menu.ps1 -- /T harness test for the menu-bar "Tools" pull-down.
# Builds cc.com (std, with -i), sets up a clean one-file dir, then:
#   End (cursor -> HEXIN.TXT), F9 (open bar), Right x3 (-> Tools dropdown),
#   Enter (item 0 = "Hex dump" -> built-in hex view), Esc.
# Witnesses: the Tools dropdown renders its items, and Tools->Hex dump
# dispatches into the built-in hex pager (no external process).
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
[IO.File]::WriteAllText("$td\HEXIN.TXT","0123456789ABCDEFGHIJKLMNOPQRSTUVwxyz")

# End, F9, Right, Right, Right, Enter, Esc
$keys = [byte[]](0x00,0x4F, 0x00,0x43, 0x00,0x4D, 0x00,0x4D, 0x00,0x4D, 0x0D,0x1C, 0x1B,0x01)
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
Set-Content -Path "$dir\_run_tools.conf" -Value $conf -Encoding ASCII

if (Test-Path "$td\CCDUMP.TXT") { Remove-Item "$td\CCDUMP.TXT" -Force }
$p = Start-Process -FilePath $dbox -ArgumentList @("-conf","$dir\_run_tools.conf","-noprimaryconf") -PassThru -WindowStyle Minimized
if (-not $p.WaitForExit(15000)) { $p.Kill() | Out-Null }
Start-Sleep -Milliseconds 300

if (Test-Path "$td\CCDUMP.TXT") {
    Write-Host "===== CCDUMP.TXT ====="
    Get-Content "$td\CCDUMP.TXT" -Raw
} else { Write-Host "NO DUMP PRODUCED" }
