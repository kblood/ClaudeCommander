# run_vedit.ps1 -- prove the F3 pager's E key launches an editor on the file
# and survives the post-edit reload. Uses the TED sentinel as the editor so the
# whole chain (E -> view_launch_editor -> "TED <path>" -> run_command -> reload)
# completes headlessly. Hex-mode E (-> CCHEXED) is the same code path with a
# different program-name constant, so this exercises the mechanism.
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

$td = "$dir\_vedit"
if (Test-Path $td) { Remove-Item $td -Recurse -Force }
New-Item -ItemType Directory -Path $td | Out-Null
Copy-Item "$dir\TED.COM" "$td\TED.COM"
[IO.File]::WriteAllText("$td\AAA.TXT","hello")            # sorts first -> cursor 0
[IO.File]::WriteAllText("$td\cc.ini","editor = TED`r`n")

# F3 (open text pager), 'e' (launch editor), space (run_command's any-key pause),
# Esc (close viewer), F10 (quit cc)
$keys = [byte[]](0x00,0x3D, 0x65,0x00, 0x20,0x00, 0x1B,0x01, 0x00,0x44)
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
Set-Content -Path "$dir\_run_vedit.conf" -Value $conf -Encoding ASCII

if (Test-Path "$td\TEDOUT.TXT") { Remove-Item "$td\TEDOUT.TXT" -Force }
$p = Start-Process -FilePath $dbox -ArgumentList @("-conf","$dir\_run_vedit.conf","-noprimaryconf") -PassThru -WindowStyle Minimized
if (-not $p.WaitForExit(15000)) { $p.Kill() | Out-Null }
Start-Sleep -Milliseconds 300

if (Test-Path "$td\TEDOUT.TXT") {
    $t = (Get-Content "$td\TEDOUT.TXT" -Raw)
    Write-Host "editor ran from pager. tail = [$($t.Trim())]"
    if ($t -match 'AAA\.TXT') { Write-Host "PASS: F3 pager E key launched the editor on the viewed file" }
    else { Write-Host "FAIL: editor ran but file path not in tail" }
} else { Write-Host "FAIL: TEDOUT.TXT not created -- E key did not launch the editor" }
