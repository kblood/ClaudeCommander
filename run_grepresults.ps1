# run_grepresults.ps1 -- /T harness for FEAT_RESULTS + FEAT_GREP (W2).
# Builds cc with -dFEAT_GREP -dFEAT_RESULTS -dFEAT_VIEW, stages D:\ with
# CCGREP.COM and SUB\DATA.TXT (the search word "NEEDLE" on known lines), then
# drives:  Alt-F8, type "NEEDLE", Enter (run grep) -> results panel listing one
# row per matching file with the first match's line number in the size column;
# Enter (jump) -> F3 viewer scrolled to that line; F10 (close viewer); F10 (quit).
# Asserts: a results frame (right panel) lists exactly DATA.TXT with the first
# match's line (4) in its size column; a later viewer frame on DATA.TXT has line
# 4 as its top text line; F10 returns to the results panel. The typed prompt
# text is never asserted on (it would be present even if grep never ran).
$ErrorActionPreference = "Stop"
$dir  = "C:\LLM\DOS\cc"
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
# DATA.TXT: the FIRST needle is on line 4 (1-based), a second one on line 6 --
# the results row must carry the first match's line (4), and the viewer must
# land on line 4. OTHER.DAT is a near-miss decoy ("NEEDL") that must not list.
$lines = @("line one alpha","line two beta","line three gamma","hit NEEDLE marker here","line five delta","line six NEEDLE again")
[IO.File]::WriteAllText("$td\SUB\DATA.TXT", ($lines -join "`r`n"))
[IO.File]::WriteAllText("$td\OTHER.DAT","nothing to see, NEEDL only")
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

$p = Start-Process -FilePath $dbox -ArgumentList @("-conf","$dir\_run_grepresults.conf","-noprimaryconf","--exit") -PassThru -WindowStyle Minimized
if (-not $p.WaitForExit(20000)) { $p.Kill() | Out-Null; Write-Host "FAIL: DOSBox hang/timeout (killed after 20s)"; exit 1 }
Start-Sleep -Milliseconds 300

$dump = "$td\CCDUMP.TXT"
if (-not (Test-Path $dump)) { Write-Host "NO DUMP PRODUCED"; exit 1 }
$raw = Get-Content $dump -Raw
Write-Host "===== CCDUMP.TXT ====="
Write-Host $raw

# ---- assertions (frames in order; CP437 read 1:1 as Latin-1) ----------------
$raw = [IO.File]::ReadAllText($dump, [Text.Encoding]::Latin1)
$frames = [System.Collections.Generic.List[object]]::new()
foreach ($f in ($raw -split "==== FRAME ====\r?\n")) { if ($f.Trim() -ne "") { $frames.Add([string[]]($f -split "\r?\n" | ForEach-Object { $_.TrimEnd() })) } }
function FindFrame([int]$from, [scriptblock]$pred) {
    for ($i = $from; $i -lt $frames.Count; $i++) { if (& $pred $frames[$i]) { return $i } }
    return -1
}
# right-panel cell text of each two-panel row ("|left|right|" -> "right"), trimmed
function RightRows([string[]]$f) {
    @($f | Where-Object { $_ -match '^\xB3[^\xB3]*\xB3[^\xB3]*\xB3$' } | ForEach-Object { ($_ -split '\xB3')[2].Trim() } | Where-Object { $_ -ne "" })
}
$fail = 0
function Check([bool]$ok, [string]$what) { if ($ok) { Write-Host "PASS: $what" } else { Write-Host "FAIL: $what"; $script:fail++ } }

Check ($frames.Count -ge 1 -and -not (($frames[0] -join "`n") -match 'DATA\.TXT')) "initial frame does not show DATA.TXT (it lives in SUB)"
# results panel: ".." then exactly one row, DATA.TXT with line 4 in the size
# column (the file is 110 B, so "4 B" can only be the first-match line number)
$ir = FindFrame 1 { param($f) $r = RightRows $f; $r.Count -ge 1 -and $r[0] -match '^\.\.\s+<UP>$' -and @($r -match '^DATA\.TXT\s').Count -ge 1 }
Check ($ir -ge 0) "results panel appears (right panel '..' + DATA.TXT row) [frame $ir]"
if ($ir -ge 0) {
    $r = RightRows $frames[$ir]
    Write-Host ("       results rows: " + ($r -join " | "))
    Check ($r.Count -eq 2) "exactly one result row (one per matching FILE; OTHER.DAT near-miss not listed)"
    Check (@($r -match '^DATA\.TXT\s+4 B$').Count -eq 1) "DATA.TXT row carries the FIRST match's line number (4 B), not 6 or the 110 B size"
    Check (($frames[$ir] -join "`n") -match '\xC2\xC4+ D:\\ \xC4+\xBF') "results panel titled with the searched dir D:\"
}
# Enter: F3 viewer on DATA.TXT, scrolled so line 4 is the top text line
$iv = if ($ir -ge 0) { FindFrame ($ir + 1) { param($f) $f[0] -match '^ DATA\.TXT\s+\[ View \]' } } else { -1 }
Check ($iv -gt $ir -and $ir -ge 0) "Enter on the row opens the viewer on DATA.TXT [frame $iv]"
if ($iv -ge 0) {
    $v = $frames[$iv]
    Write-Host ("       viewer top lines: '{0}' / '{1}'" -f $v[1], $v[2])
    Check ($v[1] -ceq "hit NEEDLE marker here" -and $v[2] -ceq "line five delta") "viewer lands on line 4 (top line 'hit NEEDLE marker here', then line 5)"
    Check (-not (($v -join "`n") -match 'line (one|two|three)')) "lines 1-3 are scrolled off"
}
$ib = if ($iv -ge 0) { FindFrame ($iv + 1) { param($f) @((RightRows $f) -match '^DATA\.TXT\s+4 B$').Count -ge 1 } } else { -1 }
Check ($ib -gt $iv -and $iv -ge 0) "F10 closes the viewer back to the results panel [frame $ib]"

if ($fail -gt 0) { Write-Host "`nGREP RESULTS HARNESS: FAIL ($fail)"; exit 1 }
Write-Host "`nGREP RESULTS HARNESS: PASS"
exit 0
