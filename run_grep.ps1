# run_grep.ps1 -- CCGREP against a staged fixture tree (mounted as C:).
# Asserts the output is EXACTLY the expected  path:line:text  rows: right line
# numbers (CRLF and LF-only files), case-insensitive hit, recursion into a
# subdir, and nothing from the decoys (wrong mask, outside startdir, near-miss).
# Exact assertions apply to the default text/startdir/mask; other values just run.
param(
    [string]$text = "wildmatch",
    [string]$startdir = "C:\MOD",
    [string]$mask = "*.INC"
)
$ErrorActionPreference = "Stop"
$dir  = "C:\LLM\DOS\cc"
$dbox = "$dir\dbstaging\dosbox-staging-v0.82.2\dosbox.exe"
$nasm = "C:\Users\Caldor\AppData\Local\bin\NASM\nasm.exe"
if (-not (Test-Path $nasm)) { $nasm = "nasm" }

& $nasm -f bin "$dir\cgrep.asm" -o "$dir\ccgrep.com" 2>&1
if ($LASTEXITCODE -ne 0) { Write-Host "ASSEMBLE FAILED"; exit 1 }
Write-Host ("BUILD OK: {0} bytes" -f (Get-Item "$dir\ccgrep.com").Length)

# ---- fixture tree ------------------------------------------------------------
$gt = "$dir\_greptest"
if (Test-Path $gt) { Remove-Item $gt -Recurse -Force }
foreach ($d in "", "MOD", "MOD\SUB", "OUT") { New-Item -ItemType Directory -Path "$gt\$d" -Force | Out-Null }
Copy-Item "$dir\ccgrep.com" "$gt\CCGREP.COM"
[IO.File]::WriteAllText("$gt\MOD\A.INC", (@("; header", "        call    wildmatch", "x", "y", "WILDMATCH:  ; upper case", "z") -join "`r`n"))
[IO.File]::WriteAllText("$gt\MOD\B.INC", (@("nothing here", "wildmatc h near miss", "end") -join "`r`n"))
[IO.File]::WriteAllText("$gt\MOD\C.TXT", "wildmatch in a file the mask excludes`r`n")
[IO.File]::WriteAllText("$gt\MOD\SUB\D.INC", "a`nb`nfoo wildmatch bar`nc`n")     # LF-only
[IO.File]::WriteAllText("$gt\OUT\E.INC", "wildmatch outside the start dir`r`n")
$expected = @(
    "C:\MOD\A.INC:2:        call    wildmatch",
    "C:\MOD\A.INC:5:WILDMATCH:  ; upper case",
    "C:\MOD\SUB\D.INC:3:foo wildmatch bar"
)

$conf = @"
[sdl]
fullscreen = false
[cpu]
core    = normal
cputype = 486
cycles  = max
[autoexec]
@echo off
mount c $gt
c:
if exist grepout.txt del grepout.txt
ccgrep.com $text $startdir $mask > grepout.txt
exit
"@
$confPath = "$dir\_run_grep.conf"
Set-Content -Path $confPath -Value $conf -Encoding ASCII

$p = Start-Process -FilePath $dbox -ArgumentList @("-conf",$confPath,"-noprimaryconf","--exit") -PassThru -WindowStyle Minimized
if (-not $p.WaitForExit(15000)) { $p.Kill() | Out-Null; Write-Host "FAIL: DOSBox hang/timeout (killed after 15s)"; exit 1 }
Start-Sleep -Milliseconds 300

if (-not (Test-Path "$gt\grepout.txt")) { Write-Host "NO OUTPUT"; exit 1 }
Write-Host "===== GREPOUT.TXT ====="
Get-Content "$gt\grepout.txt"
Write-Host "======================="

if ($text -ne "wildmatch" -or $startdir -ne "C:\MOD" -or $mask -ne "*.INC") {
    Write-Host "NOTE: non-default arguments -- exact-row assertions skipped"
    exit 0
}
$got = @(Get-Content "$gt\grepout.txt" | ForEach-Object { $_.TrimEnd() } | Where-Object { $_ -ne "" })
$fail = 0
foreach ($e in $expected) {
    if ($got -ccontains $e) { Write-Host "PASS: row '$e'" } else { Write-Host "FAIL: missing row '$e'"; $fail++ }
}
foreach ($d in "B.INC", "C.TXT", "E.INC") {
    if (@($got | Where-Object { $_ -like "*\$d*" }).Count -gt 0) { Write-Host "FAIL: decoy $d produced a row"; $fail++ }
    else { Write-Host "PASS: decoy $d has no row" }
}
if ($got.Count -eq $expected.Count) { Write-Host "PASS: exactly $($expected.Count) rows" }
else { Write-Host ("FAIL: got {0} rows, want {1}" -f $got.Count, $expected.Count); $fail++ }

if ($fail -gt 0) { Write-Host "GREP: FAIL ($fail)"; exit 1 }
Write-Host "GREP: PASS"
exit 0
