# run_hexed.ps1 -- prove CCHEXED.COM overwrites bytes and F2 saves in place.
# Builds CCHEXED, drops a 4-byte all-zero file AAA.BIN and a keystroke script
# CCX.KEY that types  A B C D  (overwrites byte0=AB, auto-advances, byte1=CD)
# then F2 (save). Script exhaustion = Esc (quit). Then verifies AAA.BIN on disk.
$ErrorActionPreference = "Stop"
$dir  = "C:\LLM\cc"
$dbox = "$dir\dbstaging\dosbox-staging-v0.82.2\dosbox.exe"
$nasm = "C:\Users\Caldor\AppData\Local\bin\NASM\nasm.exe"
if (-not (Test-Path $nasm)) { $nasm = "nasm" }

& $nasm -f bin "$dir\chexed.asm" -o "$dir\CCHEXED.COM" 2>&1
if ($LASTEXITCODE -ne 0) { Write-Host "CCHEXED ASSEMBLE FAILED"; exit 1 }
Write-Host ("BUILD OK: CCHEXED {0} B" -f (Get-Item "$dir\CCHEXED.COM").Length)

$td = "$dir\_hxedit"
if (Test-Path $td) { Remove-Item $td -Recurse -Force }
New-Item -ItemType Directory -Path $td | Out-Null
Copy-Item "$dir\CCHEXED.COM" "$td\CCHEXED.COM"
# 4 zero bytes -> expect AB CD 00 00 after edit
[IO.File]::WriteAllBytes("$td\AAA.BIN", [byte[]](0,0,0,0))
# keys: 'A','B','C','D' (ascii,0), then F2 (0,0x3C)
$keys = [byte[]](0x41,0x00, 0x42,0x00, 0x43,0x00, 0x44,0x00, 0x00,0x3C)
[IO.File]::WriteAllBytes("$td\CCX.KEY", $keys)

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
c:\CCHEXED.COM AAA.BIN /T
exit
"@
Set-Content -Path "$dir\_run_hexed.conf" -Value $conf -Encoding ASCII

$p = Start-Process -FilePath $dbox -ArgumentList @("-conf","$dir\_run_hexed.conf","-noprimaryconf") -PassThru -WindowStyle Minimized
if (-not $p.WaitForExit(15000)) { $p.Kill() | Out-Null }
Start-Sleep -Milliseconds 300

$got = [IO.File]::ReadAllBytes("$td\AAA.BIN")
$hex = ($got | ForEach-Object { $_.ToString("X2") }) -join " "
Write-Host "AAA.BIN now = [$hex]"
if ($got.Length -eq 4 -and $got[0] -eq 0xAB -and $got[1] -eq 0xCD -and $got[2] -eq 0 -and $got[3] -eq 0) {
    Write-Host "PASS: CCHEXED overwrote byte0=AB byte1=CD and saved in place (size unchanged)"
} else {
    Write-Host "FAIL: expected [AB CD 00 00]"
}
