# run_hex.ps1 -- CCHEX on a known 20-byte file; asserts the exact dump rows.
param([string]$file = "HEXIN.TXT")
$ErrorActionPreference = "Stop"
$dir  = "C:\LLM\DOS\cc"
$dbox = "$dir\dbstaging\dosbox-staging-v0.82.2\dosbox.exe"
$nasm = "C:\Users\Caldor\AppData\Local\bin\NASM\nasm.exe"

& $nasm -f bin "$dir\chex.asm" -o "$dir\cchex.com" 2>&1
if ($LASTEXITCODE -ne 0) { Write-Host "ASSEMBLE FAILED"; exit 1 }
Write-Host ("BUILD OK: {0} bytes" -f (Get-Item "$dir\cchex.com").Length)

# known 20-byte input
[IO.File]::WriteAllText("$dir\HEXIN.TXT","ABCDEFGHIJ0123456789")

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
c:
if exist hexout.txt del hexout.txt
cchex.com $file > hexout.txt
exit
"@
Set-Content -Path "$dir\_run_hex.conf" -Value $conf -Encoding ASCII

if (Test-Path "$dir\hexout.txt") { Remove-Item "$dir\hexout.txt" -Force }
$p = Start-Process -FilePath $dbox -ArgumentList @("-conf","$dir\_run_hex.conf","-noprimaryconf","--exit") -PassThru -WindowStyle Minimized
if (-not $p.WaitForExit(12000)) { $p.Kill() | Out-Null; Write-Host "FAIL: DOSBox hang/timeout (killed after 12s)"; exit 1 }
Start-Sleep -Milliseconds 300

if (-not (Test-Path "$dir\hexout.txt")) { Write-Host "NO OUTPUT"; exit 1 }
Write-Host "===== HEXOUT.TXT ====="
Get-Content "$dir\hexout.txt"
Write-Host "======================"

if ($file -ne "HEXIN.TXT") { Write-Host "NOTE: non-default file -- exact-row assertions skipped"; exit 0 }
# expected rows for the 20 known bytes: 8-digit offset, 2 sp, 16 "XX " slots
# (blank-padded on the short last row), 1 sp, printable ASCII column
$expected = @(
    "00000000  41 42 43 44 45 46 47 48 49 4A 30 31 32 33 34 35  ABCDEFGHIJ012345",
    ("00000010  36 37 38 39 " + ("   " * 12) + " 6789")
)
$got = @(Get-Content "$dir\hexout.txt" | ForEach-Object { $_.TrimEnd() } | Where-Object { $_ -ne "" })
$fail = 0
for ($i = 0; $i -lt $expected.Count; $i++) {
    if ($i -lt $got.Count -and $got[$i] -ceq $expected[$i]) { Write-Host "PASS: row $i = '$($expected[$i])'" }
    else { Write-Host "FAIL: row $i want '$($expected[$i])'"; Write-Host ("       got  '{0}'" -f $(if ($i -lt $got.Count) { $got[$i] } else { "<none>" })); $fail++ }
}
if ($got.Count -eq $expected.Count) { Write-Host "PASS: exactly $($expected.Count) rows" }
else { Write-Host ("FAIL: got {0} rows, want {1}" -f $got.Count, $expected.Count); $fail++ }
if ($fail -gt 0) { Write-Host "HEX: FAIL ($fail)"; exit 1 }
Write-Host "HEX: PASS"
exit 0
