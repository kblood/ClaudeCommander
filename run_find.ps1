# run_find.ps1 -- CCFIND against a staged fixture tree (mounted as C:).
# Asserts the output is EXACTLY the expected *.INC file paths (case-insensitive
# match, recursion into subdirs incl. a dir whose own name ends .INC) and none of
# the decoys (wrong ext, "INC" in the base name, the DIR.INC directory itself).
# Exact assertions apply to the default pattern/startdir; other values just run.
param(
    [string]$pattern = "*.INC",
    [string]$startdir = "C:\"
)
$ErrorActionPreference = "Stop"
$dir  = "C:\LLM\DOS\cc"
$dbox = "$dir\dbstaging\dosbox-staging-v0.82.2\dosbox.exe"
$nasm = "C:\Users\Caldor\AppData\Local\bin\NASM\nasm.exe"
if (-not (Test-Path $nasm)) { $nasm = "nasm" }

& $nasm -f bin "$dir\cfind.asm" -o "$dir\ccfind.com" 2>&1
if ($LASTEXITCODE -ne 0) { Write-Host "ASSEMBLE FAILED"; exit 1 }
Write-Host ("BUILD OK: {0} bytes" -f (Get-Item "$dir\ccfind.com").Length)

# ---- fixture tree ------------------------------------------------------------
$ft = "$dir\_findtest"
if (Test-Path $ft) { Remove-Item $ft -Recurse -Force }
foreach ($d in "", "SUB", "SUB\DEEP", "DIR.INC", "EMPTY") { New-Item -ItemType Directory -Path "$ft\$d" -Force | Out-Null }
Copy-Item "$dir\ccfind.com" "$ft\CCFIND.COM"
foreach ($f in "ROOT.INC", "SUB\ALPHA.INC", "SUB\DEEP\BETA.INC", "SUB\DEEP\lower.inc", "DIR.INC\GAMMA.INC",
               "NOTE.TXT", "INC.DAT", "SUB\ALPHA.INX", "SUB\DEEP\INCLUDE.TXT") {
    [IO.File]::WriteAllText("$ft\$f", "x")
}
$expected = @("C:\ROOT.INC", "C:\SUB\ALPHA.INC", "C:\SUB\DEEP\BETA.INC", "C:\SUB\DEEP\LOWER.INC", "C:\DIR.INC\GAMMA.INC")
$decoys   = @("C:\NOTE.TXT", "C:\INC.DAT", "C:\SUB\ALPHA.INX", "C:\SUB\DEEP\INCLUDE.TXT", "C:\DIR.INC", "C:\CCFIND.COM")

$conf = @"
[sdl]
fullscreen = false
[cpu]
core    = normal
cputype = 486
cycles  = max
[autoexec]
@echo off
mount c $ft
c:
if exist findout.txt del findout.txt
ccfind.com $pattern $startdir > findout.txt
exit
"@
$confPath = "$dir\_run_find.conf"
Set-Content -Path $confPath -Value $conf -Encoding ASCII

$p = Start-Process -FilePath $dbox -ArgumentList @("-conf",$confPath,"-noprimaryconf","--exit") -PassThru -WindowStyle Minimized
if (-not $p.WaitForExit(12000)) { $p.Kill() | Out-Null; Write-Host "FAIL: DOSBox hang/timeout (killed after 12s)"; exit 1 }
Start-Sleep -Milliseconds 300

if (-not (Test-Path "$ft\findout.txt")) { Write-Host "NO OUTPUT"; exit 1 }
Write-Host "===== FINDOUT.TXT ====="
Get-Content "$ft\findout.txt"
Write-Host "======================="

if ($pattern -ne "*.INC" -or $startdir -ne "C:\") {
    Write-Host "NOTE: non-default pattern/startdir -- exact-set assertions skipped"
    exit 0
}
$got = @(Get-Content "$ft\findout.txt" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
$fail = 0
foreach ($e in $expected) {
    if ($got -contains $e) { Write-Host "PASS: lists $e" } else { Write-Host "FAIL: missing $e"; $fail++ }
}
foreach ($d in $decoys) {
    if ($got -contains $d) { Write-Host "FAIL: lists decoy $d"; $fail++ } else { Write-Host "PASS: decoy $d not listed" }
}
$extra = @($got | Where-Object { $expected -notcontains $_ })
if ($extra.Count -eq 0 -and $got.Count -eq $expected.Count) { Write-Host "PASS: exactly $($expected.Count) lines, no extras/duplicates" }
else { Write-Host ("FAIL: got {0} lines (want {1}); unexpected: {2}" -f $got.Count, $expected.Count, ($extra -join ", ")); $fail++ }

if ($fail -gt 0) { Write-Host "FIND: FAIL ($fail)"; exit 1 }
Write-Host "FIND: PASS"
exit 0
