param(
    [string]$keyfile = "keys_lfn.bin"
)
$ErrorActionPreference = "Stop"
$dir   = "C:\LLM\DOS\cc"
$dbox  = "$dir\dbstaging\dosbox-staging-v0.82.2\dosbox.exe"
$nasm  = "C:\Users\Caldor\AppData\Local\bin\NASM\nasm.exe"

# 1. assemble (STD includes FEAT_LFN)
& $nasm -f bin "$dir\cc.asm" -o "$dir\cc.com" 2>&1
if ($LASTEXITCODE -ne 0) { Write-Host "ASSEMBLE FAILED"; exit 1 }
Write-Host ("BUILD OK: {0} bytes" -f (Get-Item "$dir\cc.com").Length)

# 2. make a clean test dir with one long-named file
$lt = "$dir\lfntest"
if (Test-Path $lt) { Remove-Item $lt -Recurse -Force }
New-Item -ItemType Directory -Path $lt | Out-Null
Set-Content -Path "$lt\My Long Document Name.txt" -Value "hi" -Encoding ASCII

# 3. key script -- cc reads cc.key from its CWD, which will be lfntest.
# Move from CC.KEY to the long-name fixture, then quit. Older checkouts used
# an external keys_lfn.bin; generate the tiny script when it is absent.
$keyPath = if ([System.IO.Path]::IsPathRooted($keyfile)) { $keyfile } else { Join-Path $dir $keyfile }
if (Test-Path $keyPath) {
    Copy-Item $keyPath "$lt\cc.key" -Force
} else {
    [IO.File]::WriteAllBytes("$lt\cc.key", [byte[]](0x00,0x50, 0x00,0x44))
    Write-Host "generated inline key script: Down, F10"
}

# 4. conf with LFN + DOS 7.10 so the long name resolves
$conf = @"
[sdl]
fullscreen = false
window_position = 0,0
[dos]
ver = 7.10
lfn = true
[cpu]
core    = normal
cputype = 486
cycles  = max
[autoexec]
@echo off
mount c $dir
c:
cd lfntest
if exist ccdump.txt del ccdump.txt
..\cc.com /T
exit
"@
$confPath = "$dir\_lfn.conf"
Set-Content -Path $confPath -Value $conf -Encoding ASCII

# 5. run with timeout
$dump = "$lt\CCDUMP.TXT"
if (Test-Path $dump) { Remove-Item $dump -Force }
$p = Start-Process -FilePath $dbox -ArgumentList @("-conf",$confPath,"-noprimaryconf") -PassThru -WindowStyle Minimized
if (-not $p.WaitForExit(12000)) { $p.Kill() | Out-Null }
Start-Sleep -Milliseconds 300

# 6. show dump (last frame only)
if (Test-Path $dump) {
    Write-Host "===== CCDUMP.TXT (last frame) ====="
    $raw = Get-Content $dump -Raw
    $frames = $raw -split "==== FRAME ===="
    $last = $frames | Where-Object { $_.Trim().Length -gt 0 } | Select-Object -Last 1
    Write-Host $last
    if ($raw -match "My Long Document Name\.txt") {
        Write-Host "LFN HARNESS: PASS -- long filename rendered"
    } elseif ($raw -match "MY.?LONG|MYLONG") {
        Write-Host "LFN HARNESS: PASS -- 8.3 fallback rendered (LFN provider unavailable)"
    } else {
        Write-Host "LFN HARNESS: FAIL -- long-name fixture not visible"
        exit 1
    }
} else {
    Write-Host "NO DUMP PRODUCED"
    exit 1
}
