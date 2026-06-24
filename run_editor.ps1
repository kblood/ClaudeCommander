# run_editor.ps1 -- prove the cc.ini "editor =" override drives F4.
# Builds cc.com (std) + a tiny sentinel editor TED.COM that records its args,
# sets cc.ini "editor = TED", then drives: End (cursor -> HEXIN.TXT), F4.
# If the override worked, cc EXECs "TED <path>" and TED writes TEDOUT.TXT.
$ErrorActionPreference = "Stop"
$dir  = "C:\LLM\cc"
$dbox = "$dir\dbstaging\dosbox-staging-v0.82.2\dosbox.exe"
$nasm = "C:\Users\Caldor\AppData\Local\bin\NASM\nasm.exe"
if (-not (Test-Path $nasm)) { $nasm = "nasm" }

& $nasm -f bin -i "$dir/" "$dir\cc.asm" -o "$dir\cc.com" 2>&1
if ($LASTEXITCODE -ne 0) { Write-Host "cc ASSEMBLE FAILED"; exit 1 }
& $nasm -f bin "$dir\ted.asm" -o "$dir\TED.COM" 2>&1
if ($LASTEXITCODE -ne 0) { Write-Host "ted ASSEMBLE FAILED"; exit 1 }
Write-Host ("BUILD OK: cc {0} B, TED {1} B" -f (Get-Item "$dir\cc.com").Length, (Get-Item "$dir\TED.COM").Length)

$td = "$dir\_edtest"
if (Test-Path $td) { Remove-Item $td -Recurse -Force }
New-Item -ItemType Directory -Path $td | Out-Null
Copy-Item "$dir\TED.COM" "$td\TED.COM"
[IO.File]::WriteAllText("$td\AAA.TXT","hello")   # sorts first -> cursor 0
[IO.File]::WriteAllText("$td\cc.ini","editor = TED`r`n")

# F4 on cursor 0 (AAA.TXT, first alphabetically regardless of leftovers)
$keys = [byte[]](0x00,0x3E)
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
c:\cc.com /T
exit
"@
Set-Content -Path "$dir\_run_editor.conf" -Value $conf -Encoding ASCII

if (Test-Path "$td\TEDOUT.TXT") { Remove-Item "$td\TEDOUT.TXT" -Force }
if (Test-Path "$td\CCDUMP.TXT") { Remove-Item "$td\CCDUMP.TXT" -Force }
$p = Start-Process -FilePath $dbox -ArgumentList @("-conf","$dir\_run_editor.conf","-noprimaryconf") -PassThru -WindowStyle Minimized
if (-not $p.WaitForExit(15000)) { $p.Kill() | Out-Null }
Start-Sleep -Milliseconds 300

if (Test-Path "$td\TEDOUT.TXT") {
    $t = (Get-Content "$td\TEDOUT.TXT" -Raw)
    Write-Host "TED ran. command tail = [$($t.Trim())]"
    if ($t -match 'AAA\.TXT') { Write-Host "PASS: editor=TED honoured, file path passed" }
    else { Write-Host "FAIL: TED ran but path not found in tail" }
} else { Write-Host "FAIL: TEDOUT.TXT not created -- editor override did not fire" }
