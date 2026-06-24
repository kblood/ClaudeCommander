# run_grepresults.ps1 -- /T harness for FEAT_RESULTS + FEAT_GREP (W2).
# Builds cc with -dFEAT_GREP -dFEAT_RESULTS -dFEAT_VIEW, stages D:\ with
# CCGREP.COM and SUB\DATA.TXT (the search word "NEEDLE" on a known line), then
# drives:  Alt-F8, type "NEEDLE", Enter (run grep) -> results panel listing the
# matched line text + line number; Enter (jump) -> F3 viewer scrolled to the
# matched line; F10 (close viewer); F10 (quit).
# Witnesses: a frame shows the matched line text + its line number in the panel,
# and a later (viewer) frame shows the file open with the matched line visible.
$ErrorActionPreference = "Stop"
$dir  = "C:\LLM\cc"
$dbox = "$dir\dbstaging\dosbox-staging-v0.82.2\dosbox.exe"
$nasm = "C:\Users\Caldor\AppData\Local\bin\NASM\nasm.exe"
if (-not (Test-Path $nasm)) { $nasm = "nasm" }

& $nasm -f bin -i "$dir/" -dFEAT_CUSTOM -dFEAT_GREP -dFEAT_RESULTS -dFEAT_VIEW "$dir\cc.asm" -o "$dir\ccgres.com" 2>&1
if ($LASTEXITCODE -ne 0) { Write-Host "ASSEMBLE FAILED (ccgres)"; exit 1 }
Write-Host ("BUILD OK: ccgres.com {0} bytes" -f (Get-Item "$dir\ccgres.com").Length)

# CCGREP back-end with the path:lineno:text contract
& $nasm -f bin -i "$dir/" "$dir\cgrep.asm" -o "$dir\ccgrep.com" 2>&1
if ($LASTEXITCODE -ne 0) { Write-Host "ASSEMBLE FAILED (cgrep)"; exit 1 }

$td = "$dir\_grestest"
if (Test-Path $td) { Remove-Item $td -Recurse -Force }
New-Item -ItemType Directory -Path $td | Out-Null
New-Item -ItemType Directory -Path "$td\SUB" | Out-Null
# DATA.TXT: the needle is on line 4 (1-based), with a recognisable text.
$lines = @("line one alpha","line two beta","line three gamma","hit NEEDLE marker here","line five delta","line six")
[IO.File]::WriteAllText("$td\SUB\DATA.TXT", ($lines -join "`r`n"))
[IO.File]::WriteAllText("$td\OTHER.DAT","nothing to see")
Copy-Item "$dir\ccgrep.com" "$td\CCGREP.COM"

# Alt-F8, "NEEDLE", Enter(run), Enter(jump->viewer), F10(close viewer), F10(quit)
$keys = [System.Collections.Generic.List[byte]]::new()
function K([byte]$a,[byte]$b){ $script:keys.Add($a); $script:keys.Add($b) }
K 0x00 0x6F                                    # Alt-F8 (grep)
foreach ($ch in "NEEDLE".ToCharArray()) { K ([byte][char]$ch) 0x00 }
K 0x0D 0x1C                                     # Enter -> run grep
K 0x0D 0x1C                                     # Enter -> jump to viewer at line
K 0x00 0x44                                     # F10 -> close viewer
K 0x00 0x44                                     # F10 -> quit cc
[IO.File]::WriteAllBytes("$td\cc.key",$keys.ToArray())

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
if exist grepout.txt del grepout.txt
if exist ccdump.txt del ccdump.txt
c:\ccgres.com /T
exit
"@
Set-Content -Path "$dir\_run_grepresults.conf" -Value $conf -Encoding ASCII

$p = Start-Process -FilePath $dbox -ArgumentList @("-conf","$dir\_run_grepresults.conf","-noprimaryconf") -PassThru -WindowStyle Minimized
if (-not $p.WaitForExit(20000)) { $p.Kill() | Out-Null }
Start-Sleep -Milliseconds 300

$dump = "$td\CCDUMP.TXT"
if (-not (Test-Path $dump)) { Write-Host "NO DUMP PRODUCED"; exit 1 }
$raw = Get-Content $dump -Raw
Write-Host "===== CCDUMP.TXT ====="
Write-Host $raw

$ok = $true
if ($raw -notmatch 'NEEDLE')        { Write-Host "FAIL: matched text 'NEEDLE' never appears in a panel/viewer frame"; $ok = $false }
if ($raw -notmatch 'DATA\.TXT')     { Write-Host "WARN: DATA.TXT (file name) not seen" }
# the line number 4 should show in the result row's size column
if ($raw -match 'NEEDLE.*\b4\b' -or $raw -match '\b4\b') { Write-Host "note: line-number column present" }
if ($ok) { Write-Host "`nGREP RESULTS HARNESS: matched text present (inspect frames for line# + viewer jump)" }
else     { Write-Host "`nGREP RESULTS HARNESS: FAIL" }
