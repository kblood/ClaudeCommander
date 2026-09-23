# run_tools_menu.ps1 -- /T harness test for the menu-bar "Tools" pull-down.
# Builds cc.com (std, with -i), sets up a clean one-file dir, then:
#   End (cursor -> HEXIN.TXT), F9 (open bar), Right x3 (-> Tools dropdown),
#   Enter (item 0 = "Hex dump" -> built-in hex view), Esc.
# Witnesses: the Tools dropdown renders its items, and Tools->Hex dump
# dispatches into the built-in hex pager (no external process).
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
$p = Start-Process -FilePath $dbox -ArgumentList @("-conf","$dir\_run_tools.conf","-noprimaryconf","--exit") -PassThru -WindowStyle Minimized
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

# Tools pull-down: every item label, in order, on consecutive rows 2..6 inside
# the double-line (0xBA) box
$items = @("Hex dump (F3, then H)", "Checksum (CRC-32)", "Compare (other panel)", "Split file...", "Wildcard rename...")
$it = FindFrame 0 { param($f)
    for ($k = 0; $k -lt $items.Count; $k++) { if ($f[2 + $k] -notmatch ('\xBA ' + [regex]::Escape($items[$k]) + '\s*\xBA')) { return $false } }
    return $true }
Check ($it -ge 0) "Tools dropdown lists: $($items -join ' / ') [frame $it]"
$im = if ($it -ge 0) { FindFrame 0 { param($f) ($f -join "`n") -match 'Sort: Name' } } else { -1 }
Check ($im -ge 0 -and $im -lt $it) "Right x3 walks Files -> Commands -> Options -> Tools (Options menu seen first) [frame $im]"
$hex0 = "00000000  30 31 32 33 34 35 36 37 38 39 41 42 43 44 45 46  0123456789ABCDEF"
$ih = if ($it -ge 0) { FindFrame ($it + 1) { param($f) $f[0] -match '^ HEXIN\.TXT\s+\[ Hex \]' -and $f[1] -ceq $hex0 } } else { -1 }
Check ($ih -gt $it) "Enter on 'Hex dump' opens the built-in hex view of HEXIN.TXT (row 0 = '$hex0') [frame $ih]"
$ip = if ($ih -ge 0) { FindFrame ($ih + 1) { param($f) ($f -join "`n") -match '\xB3HEXIN\.TXT\s+36 B\xB3' } } else { -1 }
Check ($ip -ge 0) "Esc returns to the panels [frame $ip]"

if ($fail -gt 0) { Write-Host "TOOLS MENU: FAIL ($fail)"; exit 1 }
Write-Host "TOOLS MENU: PASS"
exit 0
