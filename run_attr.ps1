$ErrorActionPreference = "Stop"
$dir  = "C:\LLM\cc"
$dbox = "$dir\dbstaging\dosbox-staging-v0.82.2\dosbox.exe"
$nasm = "C:\Users\Caldor\AppData\Local\bin\NASM\nasm.exe"

& $nasm -f bin "$dir\cc.asm" -o "$dir\cc.com" 2>&1
if ($LASTEXITCODE -ne 0) { Write-Host "ASSEMBLE FAILED"; exit 1 }
Write-Host ("BUILD OK: {0} bytes" -f (Get-Item "$dir\cc.com").Length)

# test dir mounted as C: with one writable file
$at = "$dir\attrtest"
if (Test-Path $at) { Get-ChildItem $at | ForEach-Object { $_.IsReadOnly = $false }; Remove-Item $at -Recurse -Force }
New-Item -ItemType Directory -Path $at | Out-Null
Copy-Item "$dir\cc.com" "$at\cc.com" -Force
Set-Content -Path "$at\test.txt" -Value "hello" -Encoding ASCII

# keys: End -> last entry (test.txt), Ctrl-A, 'R' toggle, Enter apply, F10
# pairs are [ascii, scan]
$bytes = [byte[]]@(0x00,0x4F, 0x01,0x1E, 0x52,0x13, 0x0D,0x1C, 0x00,0x44)
[IO.File]::WriteAllBytes("$at\cc.key", $bytes)

$conf = @"
[sdl]
fullscreen = false
[cpu]
core    = normal
cputype = 486
cycles  = max
[autoexec]
@echo off
mount c $at
c:
if exist ccdump.txt del ccdump.txt
cc.com /T
exit
"@
Set-Content -Path "$dir\_attr.conf" -Value $conf -Encoding ASCII

$p = Start-Process -FilePath $dbox -ArgumentList @("-conf","$dir\_attr.conf","-noprimaryconf") -PassThru -WindowStyle Minimized
if (-not $p.WaitForExit(15000)) { $p.Kill() | Out-Null }
Start-Sleep -Milliseconds 400

# show the attr-editor overlay frame
if (Test-Path "$at\CCDUMP.TXT") {
    $raw = Get-Content "$at\CCDUMP.TXT" -Raw
    ($raw -split "==== FRAME ====") | ForEach-Object {
        $line = ($_ -split "`n") | Where-Object { $_ -match 'Attributes:' } | Select-Object -First 1
        if ($line) { Write-Host ("overlay: " + $line.Trim()) }
    }
}
$ro = (Get-Item "$at\test.txt").IsReadOnly
Write-Host "test.txt IsReadOnly after Ctrl-A R + Enter: $ro"
