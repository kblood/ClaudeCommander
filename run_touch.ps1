# run_touch.ps1 -- headless regression gate for CCTOUCH.COM (Layer-3 timestamp tool).
# Assembles ctouch.asm, stamps a set of test files in DOSBox-staging, and checks
# both CCTOUCH's own confirmation line and the on-disk timestamp via DIR.
#
# Cases: explicit date+time, "now", date-only, HH:MM (no seconds), and a
# read-only file (RO bit must survive). DIR time/date assertions use SUMMER
# dates only: DOSBox-staging converts FAT timestamps through the host timezone,
# so winter-dated files show a +/-1h DST shift in DIR. That is an emulator
# display artifact, not a CCTOUCH bug -- the confirmation line (the exact FAT
# word passed to INT 21h/5701h) is asserted for every case and is always exact.
$ErrorActionPreference = "Stop"
$dir  = "C:\LLM\cc"
$dbox = "$dir\dbstaging\dosbox-staging-v0.82.2\dosbox.exe"
$nasm = "C:\Users\Caldor\AppData\Local\bin\NASM\nasm.exe"
if (-not (Test-Path $nasm)) { $nasm = "nasm" }

& $nasm -f bin "$dir\ctouch.asm" -o "$dir\cctouch.com" 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { throw "assemble failed: ctouch.asm" }
Write-Host ("CCTOUCH build: {0} bytes" -f (Get-Item "$dir\cctouch.com").Length)

# stage a fresh test dir (no Remove-Item: overwrite in place)
$td = "$dir\_touchrt"
New-Item -ItemType Directory -Path $td -Force | Out-Null
foreach ($f in "EXPL.TXT","NOW.TXT","DONLY.TXT","HM.TXT","RO.TXT") {
    [IO.File]::WriteAllText("$td\$f","x")
}
Copy-Item "$dir\cctouch.com" "$td\CCTOUCH.COM" -Force

# host "now" date, for the NOW.TXT assertion (DD.MM.YYYY as DOSBox DIR prints)
$now = Get-Date
$nowDmy = "{0:dd.MM.yyyy}" -f $now

$conf = @"
[sdl]
fullscreen = false
[cpu]
core = normal
cputype = 486
cycles = max
[autoexec]
@echo off
mount x $td
x:
attrib +r RO.TXT
echo [EXPL] >> R.TXT
cctouch.com EXPL.TXT 2020-07-15 13:24:46 >> R.TXT
dir EXPL.TXT >> R.TXT
echo [NOW] >> R.TXT
cctouch.com NOW.TXT >> R.TXT
dir NOW.TXT >> R.TXT
echo [DONLY] >> R.TXT
cctouch.com DONLY.TXT 2018-06-20 >> R.TXT
dir DONLY.TXT >> R.TXT
echo [HM] >> R.TXT
cctouch.com HM.TXT 2010-08-09 06:07 >> R.TXT
dir HM.TXT >> R.TXT
echo [RO] >> R.TXT
cctouch.com RO.TXT 2022-09-10 08:09:10 >> R.TXT
attrib RO.TXT >> R.TXT
dir RO.TXT >> R.TXT
exit
"@
Set-Content -Path "$td\_run_touch.conf" -Value $conf -Encoding ASCII
$p = Start-Process -FilePath $dbox -ArgumentList @("-conf","$td\_run_touch.conf","-noprimaryconf") -PassThru -WindowStyle Minimized
if (-not $p.WaitForExit(20000)) { $p.Kill() | Out-Null }
Start-Sleep -Milliseconds 300

if (-not (Test-Path "$td\R.TXT")) { Write-Host "FAIL: no output produced"; exit 1 }
$out = Get-Content "$td\R.TXT" -Raw
Write-Host "----- DOSBox output -----"; Write-Host $out; Write-Host "-------------------------"

$pass = 0; $fail = 0
function Check($name,$cond) {
    if ($cond) { Write-Host ("  PASS  {0}" -f $name); $script:pass++ }
    else       { Write-Host ("  FAIL  {0}" -f $name); $script:fail++ }
}

# confirmation lines (exact FAT value CCTOUCH emitted)
Check "EXPL confirmation"  ($out -match 'EXPL\.TXT\s+2020-07-15 13:24:46')
Check "DONLY confirmation" ($out -match 'DONLY\.TXT\s+2018-06-20 00:00:00')
Check "HM confirmation"    ($out -match 'HM\.TXT\s+2010-08-09 06:07:00')
Check "RO confirmation"    ($out -match 'RO\.TXT\s+2022-09-10 08:09:10')
Check "NOW confirmation"   ($out -match ('NOW\.TXT\s+{0:yyyy-MM-dd}' -f $now))

# on-disk DIR (summer dates -> no DST display shift)
Check "EXPL on disk"  ($out -match '15\.07\.2020\s+13:24')
Check "DONLY on disk" ($out -match '20\.06\.2018')
Check "HM on disk"    ($out -match '09\.08\.2010\s+6:07')
Check "RO on disk"    ($out -match '10\.09\.2022\s+8:09')
Check "NOW on disk"   ($out -match [regex]::Escape($nowDmy))
# read-only bit survived the stamp
Check "RO attr preserved" ($out -match '(?m)^\s*A?\s*R\s+X:\\RO\.TXT')

Write-Host ("`nCCTOUCH: {0} passed, {1} failed" -f $pass, $fail)
if ($fail -gt 0) { exit 1 } else { Write-Host "CCTOUCH REGRESSION: PASS"; exit 0 }
