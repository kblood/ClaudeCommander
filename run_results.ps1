# run_results.ps1 -- /T harness for the FEAT_RESULTS search-results panel (W1).
# Builds cc with -dFEAT_RESULTS, stages D:\ with CCFIND.COM and SUB\TARGET.TXT
# (plus SUB\AAA.DAT, which sorts BEFORE it), then drives:  Alt-F7, type
# "TARGET.TXT", Enter (run find) -> results panel, Enter (jump to the file) ->
# active panel retitled to D:\SUB with the cursor on TARGET.TXT, F3 (view the
# cursor file -- proves where the cursor landed), Esc, F10 (quit).
# Asserts (never on the typed prompt text): a results frame whose right panel
# lists exactly ".." + TARGET.TXT; a LATER frame with the right panel titled
# D:\SUB, the prompt D:\SUB>, and the real listing (AAA.DAT + TARGET.TXT 8 B);
# then F3 opens TARGET.TXT ("found me") -- i.e. the cursor is on the found file,
# not on the first entry.
$ErrorActionPreference = "Stop"
$dir  = "C:\LLM\DOS\cc"
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
[IO.File]::WriteAllText("$td\SUB\AAA.DAT","decoy, sorts first")
[IO.File]::WriteAllText("$td\OTHER.DAT","x")
# CCFIND helper (the find back-end the results panel parses)
& $nasm -f bin -i "$dir/" "$dir\cfind.asm" -o "$td\CCFIND.COM" 2>&1
if ($LASTEXITCODE -ne 0) { Write-Host "ASSEMBLE FAILED (cfind)"; exit 1 }

# Alt-F7, "TARGET.TXT", Enter(run), Enter(jump), F3(view cursor file), Esc, F10(quit)
$keys = [System.Collections.Generic.List[byte]]::new()
function K([byte]$a,[byte]$b){ $script:keys.Add($a); $script:keys.Add($b) }
K 0x00 0x6E                                   # Alt-F7
foreach ($ch in "TARGET.TXT".ToCharArray()) { K ([byte][char]$ch) 0x00 }
K 0x0D 0x1C                                    # Enter -> run find
K 0x0D 0x1C                                    # Enter -> jump to the result
K 0x00 0x3D                                    # F3 -> view the cursor file
K 0x1B 0x01                                    # Esc -> close viewer
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

$p = Start-Process -FilePath $dbox -ArgumentList @("-conf","$dir\_run_results.conf","-noprimaryconf","--exit") -PassThru -WindowStyle Minimized
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

Check ($frames.Count -ge 1 -and -not (($frames[0] -join "`n") -match 'TARGET\.TXT')) "initial frame does not show TARGET.TXT (it lives in SUB)"
# results panel: ".." + exactly one row, TARGET.TXT, still titled with the searched dir
$ir = FindFrame 1 { param($f) $r = RightRows $f; $r.Count -ge 1 -and $r[0] -match '^\.\.\s+<UP>$' -and @($r -match '^TARGET\.TXT\s').Count -ge 1 }
Check ($ir -ge 0) "results panel appears (right panel '..' + TARGET.TXT row) [frame $ir]"
if ($ir -ge 0) {
    $r = RightRows $frames[$ir]
    Write-Host ("       results rows: " + ($r -join " | "))
    Check ($r.Count -eq 2) "exactly one result row (AAA.DAT / OTHER.DAT not listed)"
    Check (($frames[$ir] -join "`n") -match '\xC2\xC4+ D:\\ \xC4+\xBF') "results panel titled with the searched dir D:\"
}
# jump: a LATER frame relists the real folder D:\SUB
$ij = if ($ir -ge 0) { FindFrame ($ir + 1) { param($f) ($f -join "`n") -match '\xC2\xC4+ D:\\SUB \xC4+\xBF' } } else { -1 }
Check ($ij -gt $ir -and $ir -ge 0) "Enter jumps: right panel retitled D:\SUB [frame $ij]"
if ($ij -ge 0) {
    $j = $frames[$ij]; $r = RightRows $j
    Write-Host ("       relisted rows: " + ($r -join " | "))
    Check (@($j -match '^D:\\SUB>').Count -ge 1) "command prompt follows to D:\SUB>"
    Check ($r.Count -eq 3 -and $r[0] -match '^\.\.\s+<UP>$' -and $r[1] -match '^AAA\.DAT\s+18 B$' -and $r[2] -match '^TARGET\.TXT\s+8 B$') `
          "real listing of SUB: '..', AAA.DAT 18 B, TARGET.TXT 8 B (real size, not a results row)"
}
# F3 on the cursor entry must open TARGET.TXT (cursor landed on the found file)
$iv = if ($ij -ge 0) { FindFrame ($ij + 1) { param($f) $f[0] -match '^ \S+\s+\[ View \]' } } else { -1 }
if ($iv -ge 0) { Write-Host ("       viewer header: '{0}' / first line: '{1}'" -f $frames[$iv][0], $frames[$iv][1]) }
Check ($iv -gt $ij -and $ij -ge 0 -and $frames[$iv][0] -match '^ TARGET\.TXT\s+\[ View \]' -and $frames[$iv][1] -ceq "found me") `
      "cursor is on TARGET.TXT after the jump (F3 views it: 'found me') [frame $iv]"

if ($fail -gt 0) { Write-Host "`nRESULTS HARNESS: FAIL ($fail)"; exit 1 }
Write-Host "`nRESULTS HARNESS: PASS"
exit 0
