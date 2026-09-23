# run_attr.ps1 -- /T harness for FEAT_ATTR (Ctrl-A attribute editor).
# Keys: End (-> test.txt), Ctrl-A, R, Enter. Asserts the overlay shows the file's
# real bits then R toggled on, and that test.txt is read-only on the host
# afterwards with H/S/A unchanged (and no other file touched).
$ErrorActionPreference = "Stop"
$dir  = "C:\LLM\DOS\cc"
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
$initAttr = (Get-Item "$at\test.txt").Attributes

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

$p = Start-Process -FilePath $dbox -ArgumentList @("-conf","$dir\_attr.conf","-noprimaryconf","--exit") -PassThru -WindowStyle Minimized
if (-not $p.WaitForExit(15000)) { $p.Kill() | Out-Null; Write-Host "FAIL: DOSBox hang/timeout (killed after 15s)"; exit 1 }
Start-Sleep -Milliseconds 400

# show the attr-editor overlay frames
$fail = 0
$overlays = @()
if (Test-Path "$at\CCDUMP.TXT") {
    $raw = Get-Content "$at\CCDUMP.TXT" -Raw
    ($raw -split "==== FRAME ====") | ForEach-Object {
        $line = ($_ -split "`n") | Where-Object { $_ -match 'Attributes:' } | Select-Object -First 1
        if ($line) { $t = $line.Trim(); $overlays += $t; Write-Host ("overlay: " + $t) }
    }
} else { Write-Host "FAIL: no CCDUMP.TXT produced"; $fail++ }

# expected: the editor opens showing test.txt's current R/H/S/A bits, 'R' flips
# only the R bit, Enter writes it to the file (and to nothing else).
function Flags([IO.FileAttributes]$a) {
    $r = if ($a -band [IO.FileAttributes]::ReadOnly) { "R" } else { "." }
    $h = if ($a -band [IO.FileAttributes]::Hidden)   { "H" } else { "." }
    $s = if ($a -band [IO.FileAttributes]::System)   { "S" } else { "." }
    $c = if ($a -band [IO.FileAttributes]::Archive)  { "A" } else { "." }
    "Attributes: $r $h $s $c  (R/H/S/A toggle, Enter apply, Esc cancel)"
}
$wantAttr = $initAttr -bor [IO.FileAttributes]::ReadOnly
$wantOv   = @((Flags $initAttr), (Flags $wantAttr))
if ($overlays.Count -eq 2 -and $overlays[0] -ceq $wantOv[0] -and $overlays[1] -ceq $wantOv[1]) {
    Write-Host "PASS: overlay '$($wantOv[0])' -> after R '$($wantOv[1])'"
} else {
    Write-Host ("FAIL: overlay frames want [{0}] then [{1}], got {2} frame(s): {3}" -f $wantOv[0], $wantOv[1], $overlays.Count, ($overlays -join " | "))
    $fail++
}

$after = (Get-Item "$at\test.txt").Attributes
$mask  = [IO.FileAttributes]::ReadOnly -bor [IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System -bor [IO.FileAttributes]::Archive
Write-Host "test.txt attributes: before [$initAttr]  after [$after]"
if (($after -band $mask) -eq ($wantAttr -band $mask)) { Write-Host "PASS: test.txt R/H/S/A on disk = R set, H/S/A unchanged" }
else { Write-Host ("FAIL: test.txt R/H/S/A want [{0}] got [{1}]" -f ($wantAttr -band $mask), ($after -band $mask)); $fail++ }
foreach ($o in "cc.com", "cc.key") {
    if ((Get-Item "$at\$o").IsReadOnly) { Write-Host "FAIL: $o became read-only (wrong entry edited)"; $fail++ }
    else { Write-Host "PASS: $o untouched (not read-only)" }
}
if ($fail -gt 0) { Write-Host "ATTR: FAIL ($fail)"; exit 1 }
Write-Host "ATTR: PASS"
exit 0
