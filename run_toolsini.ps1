# run_toolsini.ps1 -- /T harness for FEAT_TOOLS_INI (W5 cc.ini [tools] registry).
# Build cc with FEAT_TOOLS_INI; stage a dir whose cc.ini declares a user tool
# under [tools] with a hotkey:  "ZZHELLO = HELLO.COM Alt-F3".
#   MENU   : open the bar (F9), walk to the Tools pull-down, dump it. The dropdown
#            must show BOTH the built-in rows (e.g. "Checksum") AND the user row
#            ("ZZHELLO") -- the [tools] line was folded into the menu, no rebuild.
#   HOTKEY : press Alt-F3 (its scan, unbound by any built-in). It must run
#            HELLO.COM, a tiny .COM that creates RAN.TXT -- so RAN.TXT's existence
#            proves the runtime keybinding fired and EXEC'd the program.
#   EMPTY  : an empty [tools] adds no row (the splice is conditional).
$ErrorActionPreference = "Stop"
$dir  = "C:\LLM\cc"
$dbox = "$dir\dbstaging\dosbox-staging-v0.82.2\dosbox.exe"
$nasm = "C:\Users\Caldor\AppData\Local\bin\NASM\nasm.exe"
if (-not (Test-Path $nasm)) { $nasm = "nasm" }

& $nasm -f bin -i "$dir/" -dFEAT_CUSTOM -dFEAT_TOOLS_INI "$dir\cc.asm" -o "$dir\cctini.com" 2>&1
if ($LASTEXITCODE -ne 0) { Write-Host "ASSEMBLE FAILED"; exit 1 }
Write-Host ("BUILD OK: cctini.com {0} bytes" -f (Get-Item "$dir\cctini.com").Length)

# HELLO.COM: create RAN.TXT (INT 21h/3Ch), close, exit. ~ a dozen bytes.
$hello = @'
org 100h
        mov     ah, 3Ch
        xor     cx, cx
        mov     dx, fname
        int     21h
        mov     bx, ax
        mov     ah, 3Eh
        int     21h
        mov     ax, 4C00h
        int     21h
fname   db 'RAN.TXT', 0
'@
Set-Content -Path "$dir\_hello.asm" -Value $hello -Encoding ASCII
& $nasm -f bin "$dir\_hello.asm" -o "$dir\_hello.com" 2>&1
if ($LASTEXITCODE -ne 0) { Write-Host "HELLO.COM ASSEMBLE FAILED"; exit 1 }

function Stage($withTool) {
    $td = "$dir\_tini"
    if (Test-Path $td) { Remove-Item $td -Recurse -Force }
    New-Item -ItemType Directory -Path $td | Out-Null
    [IO.File]::WriteAllText("$td\DATA.TXT","hello")
    if ($withTool) {
        [IO.File]::WriteAllText("$td\cc.ini","[tools]`r`nZZHELLO = HELLO.COM Alt-F3`r`n")
        Copy-Item "$dir\_hello.com" "$td\HELLO.COM"
    } else {
        [IO.File]::WriteAllText("$td\cc.ini","[tools]`r`n")
    }
    return $td
}

function RunKeys($td, $keys) {
    [IO.File]::WriteAllBytes("$td\cc.key", $keys)
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
c:\cctini.com /T
exit
"@
    Set-Content -Path "$dir\_run_tini.conf" -Value $conf -Encoding ASCII
    $p = Start-Process -FilePath $dbox -ArgumentList @("-conf","$dir\_run_tini.conf","-noprimaryconf") -PassThru -WindowStyle Minimized
    if (-not $p.WaitForExit(20000)) { $p.Kill() | Out-Null }
    Start-Sleep -Milliseconds 300
    return (Get-Content "$td\CCDUMP.TXT" -Raw)
}

# --- MENU scenario: F9 ; Right x3 (Files->Commands->Options->Tools) ; F10 ; F10
$td = Stage $true
$mk = [System.Collections.Generic.List[byte]]::new()
$mk.Add(0x00); $mk.Add(0x43)
1..3 | ForEach-Object { $mk.Add(0x00); $mk.Add(0x4D) }
$mk.Add(0x00); $mk.Add(0x44); $mk.Add(0x00); $mk.Add(0x44)
$menu = RunKeys $td $mk.ToArray()

# --- HOTKEY scenario: Alt-F3 (00 6A) ; Enter (dismiss run_command wait) ; F10
$td = Stage $true
if (Test-Path "$td\RAN.TXT") { Remove-Item "$td\RAN.TXT" -Force }
$hk = [byte[]]@(0x00,0x6A, 0x0D,0x1C, 0x00,0x44)
RunKeys $td $hk | Out-Null
$ranExists = Test-Path "$td\RAN.TXT"

# --- EMPTY scenario: same nav, but no [tools] entry
$td = Stage $false
$empty = RunKeys $td $mk.ToArray()

$mUser  = $menu  -match 'ZZHELLO'
$mBuilt = $menu  -match 'Checksum'
$eUser  = $empty -match 'ZZHELLO'

Write-Host ("`nmenu  : user row 'ZZHELLO' on Tools menu = {0}  (expect True)"  -f $mUser)
Write-Host ("menu  : built-in 'Checksum' still there = {0}  (expect True)"  -f $mBuilt)
Write-Host ("hotkey: Alt-F3 ran HELLO.COM (RAN.TXT)  = {0}  (expect True)"  -f $ranExists)
Write-Host ("empty : user row 'ZZHELLO' shown        = {0}  (expect False)" -f $eUser)

if ($mUser -and $mBuilt -and $ranExists -and (-not $eUser)) {
    Write-Host "`nTOOLS_INI HARNESS: PASS -- [tools] row on the menu AND its Alt-F3 hotkey fires"
} else {
    Write-Host "`nTOOLS_INI HARNESS: FAIL"
    Write-Host "----- menu dump -----"; Write-Host $menu
}
