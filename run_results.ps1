# run_results.ps1 -- /T harness for the FEAT_RESULTS search-results panel (W1).
# Builds cc with -dFEAT_RESULTS, stages D:\ with CCFIND.COM and SUB\TARGET.TXT,
# then drives:  Alt-F7, type "TARGET.TXT", Enter (run find) -> results panel,
# Enter (jump to the file) -> active panel retitled to D:\SUB with the cursor on
# TARGET.TXT, F10 (quit).
# Witnesses: a frame lists TARGET.TXT as a result, and a later frame shows the
# panel relisted on the real folder containing it.
$ErrorActionPreference = "Stop"
$dir  = "C:\LLM\cc"
$dbox = "$dir\dbstaging\dosbox-staging-v0.82.2\dosbox.exe"
$nasm = "C:\Users\Caldor\AppData\Local\bin\NASM\nasm.exe"
if (-not (Test-Path $nasm)) { $nasm = "nasm" }

# cc with the results panel
& $nasm -f bin -i "$dir/" -dFEAT_CUSTOM -dFEAT_RESULTS "$dir\cc.asm" -o "$dir\ccres.com" 2>&1
if ($LASTEXITCODE -ne 0) { Write-Host "ASSEMBLE FAILED (ccres)"; exit 1 }
Write-Host ("BUILD OK: ccres.com {0} bytes" -f (Get-Item "$dir\ccres.com").Length)

$td = "$dir\_restest"
if (Test-Path $td) { Remove-Item $td -Recurse -Force }
New-Item -ItemType Directory -Path $td | Out-Null
New-Item -ItemType Directory -Path "$td\SUB" | Out-Null
[IO.File]::WriteAllText("$td\SUB\TARGET.TXT","found me")
[IO.File]::WriteAllText("$td\OTHER.DAT","x")
# CCFIND helper (the find back-end the results panel parses)
& $nasm -f bin -i "$dir/" "$dir\cfind.asm" -o "$td\CCFIND.COM" 2>&1
if ($LASTEXITCODE -ne 0) { Write-Host "ASSEMBLE FAILED (cfind)"; exit 1 }

# Alt-F7, "TARGET.TXT", Enter(run), Enter(jump), F10(quit)
$keys = [System.Collections.Generic.List[byte]]::new()
function K([byte]$a,[byte]$b){ $script:keys.Add($a); $script:keys.Add($b) }
K 0x00 0x6E                                   # Alt-F7
foreach ($ch in "TARGET.TXT".ToCharArray()) { K ([byte][char]$ch) 0x00 }
K 0x0D 0x1C                                    # Enter -> run find
K 0x0D 0x1C                                    # Enter -> jump to the result
K 0x00 0x44                                    # F10 -> quit
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
if exist findout.txt del findout.txt
if exist ccdump.txt del ccdump.txt
c:\ccres.com /T
exit
"@
Set-Content -Path "$dir\_run_results.conf" -Value $conf -Encoding ASCII

$p = Start-Process -FilePath $dbox -ArgumentList @("-conf","$dir\_run_results.conf","-noprimaryconf") -PassThru -WindowStyle Minimized
if (-not $p.WaitForExit(20000)) { $p.Kill() | Out-Null }
Start-Sleep -Milliseconds 300

$dump = "$td\CCDUMP.TXT"
if (-not (Test-Path $dump)) { Write-Host "NO DUMP PRODUCED"; exit 1 }
$raw = Get-Content $dump -Raw
Write-Host "===== CCDUMP.TXT ====="
Write-Host $raw

# crude assertions
$ok = $true
if ($raw -notmatch 'TARGET\.TXT') { Write-Host "FAIL: TARGET.TXT never appears"; $ok = $false }
if ($raw -notmatch 'SUB')          { Write-Host "WARN: 'SUB' (jumped folder title) not seen" }
if ($ok) { Write-Host "`nRESULTS HARNESS: TARGET.TXT present (inspect frames above for jump)" }
else     { Write-Host "`nRESULTS HARNESS: FAIL" }
