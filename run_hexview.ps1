# run_hexview.ps1 -- /T harness test for the built-in F3 hex view (toggle H).
# Builds cc.com (std, with -i so includes resolve), sets up a clean directory
# containing exactly one viewable text file, then drives: Down -> F3 -> h (hex)
# -> Down (scroll) -> Esc, dumping every frame to CCDUMP.TXT.
$ErrorActionPreference = "Stop"
$dir  = "C:\LLM\DOS\cc"
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
$p = Start-Process -FilePath $dbox -ArgumentList @("-conf","$dir\_run_hexview.conf","-noprimaryconf","--exit") -PassThru -WindowStyle Minimized
if (-not $p.WaitForExit(15000)) { $p.Kill() | Out-Null; Write-Host "FAIL: DOSBox hang/timeout (killed after 15s)"; exit 1 }
Start-Sleep -Milliseconds 300

if (Test-Path "$td\CCDUMP.TXT") {
    Write-Host "===== CCDUMP.TXT ====="
    Get-Content "$td\CCDUMP.TXT" -Raw
} else { Write-Host "NO DUMP PRODUCED"; exit 1 }

# ---- assertions (frames in order; CP437 read 1:1 as Latin-1) ----------------
$raw = [IO.File]::ReadAllText("$td\CCDUMP.TXT", [Text.Encoding]::Latin1)
$frames = [System.Collections.Generic.List[object]]::new()
foreach ($f in ($raw -split "==== FRAME ====\r?\n")) { if ($f.Trim() -ne "") { $frames.Add([string[]]($f -split "\r?\n" | ForEach-Object { $_.TrimEnd() })) } }
function FindFrame([int]$from, [scriptblock]$pred) {
    for ($i = $from; $i -lt $frames.Count; $i++) { if (& $pred $frames[$i]) { return $i } }
    return -1
}
$fail = 0
function Check([bool]$ok, [string]$what) { if ($ok) { Write-Host "PASS: $what" } else { Write-Host "FAIL: $what"; $script:fail++ } }

$hex0 = "00000000  30 31 32 33 34 35 36 37 38 39 41 42 43 44 45 46  0123456789ABCDEF"
$hex1 = "00000010  47 48 49 4A 4B 4C 4D 4E 4F 50 51 52 53 54 55 56  GHIJKLMNOPQRSTUV"
$hex2 = "00000020  77 78 79 7A " + ("   " * 12) + " wxyz"

$iv = FindFrame 0 { param($f) $f[0] -match '^ HEXIN\.TXT\s+\[ View \]' -and $f[1] -ceq "0123456789ABCDEFGHIJKLMNOPQRSTUVwxyz" }
Check ($iv -ge 0) "F3 text view of HEXIN.TXT (header + file text) [frame $iv]"
$ih = FindFrame ([Math]::Max($iv, 0)) { param($f) $f[0] -match '^ HEXIN\.TXT\s+\[ Hex \]' }
Check ($ih -gt $iv -and $iv -ge 0) "'h' switches to [ Hex ] after the text view [frame $ih]"
if ($ih -ge 0) {
    $f = $frames[$ih]
    Check ($f[1] -ceq $hex0) "hex row 0: '$hex0'"
    Check ($f[2] -ceq $hex1) "hex row 1: '$hex1'"
    Check ($f[3] -ceq $hex2) "hex row 2: '$hex2'"
    if (-not ($f[1] -ceq $hex0 -and $f[2] -ceq $hex1 -and $f[3] -ceq $hex2)) { Write-Host "       got rows:"; $f[1..3] | ForEach-Object { Write-Host "       '$_'" } }
}
$is = if ($ih -ge 0) { FindFrame ($ih + 1) { param($f) $f[0] -match '\[ Hex \]' } } else { -1 }
Check ($is -ge 0 -and $frames[$is][1] -ceq $hex1 -and $frames[$is][2] -ceq $hex2 -and -not (($frames[$is] -join "`n") -match '00000000')) `
      "Down scrolls the hex view one row (top row = offset 00000010) [frame $is]"
$ip = if ($is -ge 0) { FindFrame ($is + 1) { param($f) ($f -join "`n") -match '\xB3HEXIN\.TXT\s+36 B\xB3' } } else { -1 }
Check ($ip -ge 0) "Esc returns to the panels (HEXIN.TXT 36 B row) [frame $ip]"

if ($fail -gt 0) { Write-Host "HEXVIEW: FAIL ($fail)"; exit 1 }
Write-Host "HEXVIEW: PASS"
exit 0
