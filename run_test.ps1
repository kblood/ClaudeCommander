# run_test.ps1 -- generic cc driver (default: /D one-frame smoke of C:\ = repo).
# Asserts the first frame is the real two-panel UI listing real host entries.
param(
    [string]$ccArgs = "/D",
    [string]$keyfile = "",
    [string]$flags = ""   # e.g. "FEAT_LFN_FULL" -> nasm -dFEAT_LFN_FULL
)
$ErrorActionPreference = "Stop"
$dir   = "C:\LLM\DOS\cc"
$dbox  = "$dir\dbstaging\dosbox-staging-v0.82.2\dosbox.exe"
$nasm  = "C:\Users\Caldor\AppData\Local\bin\NASM\nasm.exe"

# 1. assemble
if ($flags -ne "") { $na = @("-f","bin"); foreach ($f in ($flags -split ";")) { $na += "-d" + $f } }
else { $na = @("-f","bin") }
& $nasm $na "$dir\cc.asm" -o "$dir\cc.com" 2>&1
if ($LASTEXITCODE -ne 0) { Write-Host "ASSEMBLE FAILED"; exit 1 }
Write-Host ("BUILD OK: {0} bytes" -f (Get-Item "$dir\cc.com").Length)

# 2. optional key script
if ($keyfile -ne "") { Copy-Item $keyfile "$dir\cc.key" -Force }
elseif (Test-Path "$dir\cc.key") { Remove-Item "$dir\cc.key" -Force }

# 3. generate conf
$conf = @"
[sdl]
fullscreen = false
window_position = 0,0
[cpu]
core    = normal
cputype = 486
cycles  = max
[autoexec]
@echo off
mount c $dir
c:
if exist ccdump.txt del ccdump.txt
cc.com $ccArgs
exit
"@
$confPath = "$dir\_run.conf"
Set-Content -Path $confPath -Value $conf -Encoding ASCII

# 4. run with timeout
if (Test-Path "$dir\CCDUMP.TXT") { Remove-Item "$dir\CCDUMP.TXT" -Force }
$p = Start-Process -FilePath $dbox -ArgumentList @("-conf",$confPath,"-noprimaryconf","--exit") -PassThru -WindowStyle Minimized
if (-not $p.WaitForExit(12000)) { $p.Kill() | Out-Null; Write-Host "FAIL: DOSBox hang/timeout (killed after 12s)"; exit 1 }
Start-Sleep -Milliseconds 300

# 5. show dump
if (Test-Path "$dir\CCDUMP.TXT") {
    Write-Host "===== CCDUMP.TXT ====="
    Get-Content "$dir\CCDUMP.TXT" -Raw
} else {
    Write-Host "NO DUMP PRODUCED"
    exit 1
}

# 6. assert the FIRST frame (initial screen, whatever the key script) is the
#    two-panel UI listing the real C:\ (= $dir). CP437 read 1:1 as Latin-1.
$raw = [IO.File]::ReadAllText("$dir\CCDUMP.TXT", [Text.Encoding]::Latin1)
$frames = @($raw -split "==== FRAME ====\r?\n" | Where-Object { $_.Trim() -ne "" })
$fail = 0
function Check([bool]$ok, [string]$what) { if ($ok) { Write-Host "PASS: $what" } else { Write-Host "FAIL: $what"; $script:fail++ } }
Check ($frames.Count -ge 1) "dump has at least one frame ($($frames.Count))"
if ($ccArgs -eq "/D") { Check ($frames.Count -eq 1) "/D dumps exactly one frame" }
$f = if ($frames.Count -ge 1) { [string[]]($frames[0] -split "\r?\n" | ForEach-Object { $_.TrimEnd() }) } else { [string[]]@() }
$all = $f -join "`n"
Check ($all -match '\xDA\xC4+ C:\\ \xC4+\xC2\xC4+ C:\\ \xC4+\xBF') "top border: two panels, both titled C:\"
Check ($all -match '\xC0\xC4+ \d+ Files ') "bottom border shows the 'N Files' count"
Check ($all -match '(?m)^C:\\>') "command prompt 'C:\>'"
Check ($all -match '(?m)^1Help\s+2\s+3View\s+4Edit\s+5Copy\s+6Move\s+7MkDir\s+8Del\s+9Menu\s+10Quit') "F-key bar 1Help .. 10Quit"
# every left-panel row names a real host entry (8.3 short names with '~' are
# not host-checkable; <DIR> rows must be directories)
$rows = @($f | Where-Object { $_ -match '^\xB3(\S+)\s+(<DIR>|<UP>|[\d,.]+ [BKMG])\xB3' } | ForEach-Object {
    $m = [regex]::Match($_, '^\xB3(\S+)\s+(<DIR>|<UP>|[\d,.]+ [BKMG])\xB3'); [pscustomobject]@{ Name=$m.Groups[1].Value; Tag=$m.Groups[2].Value } })
$checked = 0; $bad = @()
foreach ($r in $rows) {
    if ($r.Name -eq ".." -or $r.Name -match '~') { continue }
    $hp = Join-Path $dir $r.Name
    $ok = if ($r.Tag -eq "<DIR>") { Test-Path $hp -PathType Container } else { Test-Path $hp -PathType Leaf }
    if ($ok) { $checked++ } else { $bad += "$($r.Name) [$($r.Tag)]" }
}
Check ($rows.Count -ge 10) "left panel lists >= 10 entries ($($rows.Count))"
Check ($bad.Count -eq 0 -and $checked -ge 5) ("listed names exist in $dir with the right type ($checked checked" + $(if ($bad.Count) { "; not found: " + ($bad -join ", ") } else { "" }) + ")")

if ($fail -gt 0) { Write-Host "RUN_TEST: FAIL ($fail)"; exit 1 }
Write-Host "RUN_TEST: PASS"
exit 0
