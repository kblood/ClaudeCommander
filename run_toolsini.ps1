# run_toolsini.ps1 -- /T harness for FEAT_TOOLS_INI (W5 cc.ini [tools] registry).
# Build cc with FEAT_TOOLS_INI; stage a dir whose cc.ini declares a user tool
# under [tools]. Open the menu bar (F9), walk right to the Tools pull-down, and
# dump it. The dropdown must show BOTH the built-in rows (e.g. "Checksum") AND
# the user-declared row ("ZZHELLO") -- proving the [tools] line was parsed and
# folded into the menu with no rebuild ("drop a .COM, get a menu feature").
$ErrorActionPreference = "Stop"
$dir  = "C:\LLM\cc"
$dbox = "$dir\dbstaging\dosbox-staging-v0.82.2\dosbox.exe"
$nasm = "C:\Users\Caldor\AppData\Local\bin\NASM\nasm.exe"
if (-not (Test-Path $nasm)) { $nasm = "nasm" }

& $nasm -f bin -i "$dir/" -dFEAT_CUSTOM -dFEAT_TOOLS_INI "$dir\cc.asm" -o "$dir\cctini.com" 2>&1
if ($LASTEXITCODE -ne 0) { Write-Host "ASSEMBLE FAILED"; exit 1 }
Write-Host ("BUILD OK: cctini.com {0} bytes" -f (Get-Item "$dir\cctini.com").Length)

function Run($withTool) {
    $td = "$dir\_tini"
    if (Test-Path $td) { Remove-Item $td -Recurse -Force }
    New-Item -ItemType Directory -Path $td | Out-Null
    [IO.File]::WriteAllText("$td\DATA.TXT","hello")
    if ($withTool) {
        # A [tools] line: caption left of '=', program (first token) right of it.
        [IO.File]::WriteAllText("$td\cc.ini","[tools]`r`nZZHELLO = HELLO.COM`r`n")
    } else {
        [IO.File]::WriteAllText("$td\cc.ini","[tools]`r`n")
    }
    # F9 (open bar) ; Right x3 (Files->Commands->Options->Tools) ; F10 (close) ; F10 (quit)
    $k = [System.Collections.Generic.List[byte]]::new()
    $k.Add(0x00); $k.Add(0x43)                         # F9
    1..3 | ForEach-Object { $k.Add(0x00); $k.Add(0x4D) }  # Right x3
    $k.Add(0x00); $k.Add(0x44)                         # F10 close dropdown
    $k.Add(0x00); $k.Add(0x44)                         # F10 quit cc
    [IO.File]::WriteAllBytes("$td\cc.key", $k.ToArray())
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

$with    = Run $true
$without = Run $false

$wUser  = $with    -match 'ZZHELLO'
$wBuilt = $with    -match 'Checksum'
$nUser  = $without -match 'ZZHELLO'
$nBuilt = $without -match 'Checksum'

Write-Host ("`nwith [tools] entry : user row 'ZZHELLO' shown   = {0}  (expect True)"  -f $wUser)
Write-Host ("with [tools] entry : built-in 'Checksum' shown = {0}  (expect True)"  -f $wBuilt)
Write-Host ("empty [tools]      : user row 'ZZHELLO' shown   = {0}  (expect False)" -f $nUser)
Write-Host ("empty [tools]      : built-in 'Checksum' shown  = {0}  (expect True)"  -f $nBuilt)

if ($wUser -and $wBuilt -and (-not $nUser) -and $nBuilt) {
    Write-Host "`nTOOLS_INI HARNESS: PASS -- cc.ini [tools] row appears on the Tools menu, built-ins intact"
} else {
    Write-Host "`nTOOLS_INI HARNESS: FAIL"
    Write-Host "----- with-tool dump -----"; Write-Host $with
}
