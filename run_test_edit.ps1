param(
    [string]$testfile = "TESTED.TXT",
    [string]$keyfile  = "cce_keys.bin",
    [string]$initial  = "Hello`r`nWorld`r`n"
)
$ErrorActionPreference = "Stop"
$dir  = "C:\LLM\DOS\cc"
$dbox = "$dir\dbstaging\dosbox-staging-v0.82.2\dosbox.exe"
$nasm = "C:\Users\Caldor\AppData\Local\bin\NASM\nasm.exe"
if (-not (Test-Path $nasm)) { $nasm = "nasm" }

# 1. assemble
& $nasm -f bin "$dir\cce.asm" -o "$dir\ccedit.com" 2>&1
if ($LASTEXITCODE -ne 0) { Write-Host "ASSEMBLE FAILED"; exit 1 }
Write-Host ("BUILD OK: {0} bytes" -f (Get-Item "$dir\ccedit.com").Length)

# 2. seed the file to edit (write raw bytes so CRLF is exact)
[IO.File]::WriteAllText("$dir\$testfile", $initial)

# 3. key script -> cce.key. Older checkouts used an external cce_keys.bin;
# generate a tiny insert/save/quit script when it is absent.
$keyPath = if ([System.IO.Path]::IsPathRooted($keyfile)) { $keyfile } else { Join-Path $dir $keyfile }
if (Test-Path $keyPath) {
    Copy-Item $keyPath "$dir\cce.key" -Force
} else {
    [IO.File]::WriteAllBytes("$dir\cce.key", [byte[]](0x58,0x00, 0x00,0x3C, 0x00,0x44))
    Write-Host "generated inline key script: X, F2, F10"
}

# 4. conf
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
if exist ccedump.txt del ccedump.txt
ccedit.com /T $testfile
exit
"@
$confPath = "$dir\_run_edit.conf"
Set-Content -Path $confPath -Value $conf -Encoding ASCII

if (Test-Path "$dir\CCEDUMP.TXT") { Remove-Item "$dir\CCEDUMP.TXT" -Force }
$p = Start-Process -FilePath $dbox -ArgumentList @("-conf",$confPath,"-noprimaryconf") -PassThru -WindowStyle Minimized
if (-not $p.WaitForExit(12000)) { $p.Kill() | Out-Null }
Start-Sleep -Milliseconds 300

# 5. report and assert the saved file as a byte-accurate hex/escape view
function Format-Bytes([byte[]]$data) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($b in $data) {
        if ($b -eq 13) { [void]$sb.Append('\r') }
        elseif ($b -eq 10) { [void]$sb.Append('\n') }
        elseif ($b -ge 32 -and $b -lt 127) { [void]$sb.Append([char]$b) }
        else { [void]$sb.Append(('\x{0:X2}' -f $b)) }
    }
    return $sb.ToString()
}

$bytes = [IO.File]::ReadAllBytes("$dir\$testfile")
$expected = [System.Text.Encoding]::ASCII.GetBytes("X$initial")
$savedEsc = Format-Bytes $bytes
$expectedEsc = Format-Bytes $expected
Write-Host "===== SAVED FILE ($($bytes.Length) bytes) ====="
Write-Host $savedEsc

if ($savedEsc -eq $expectedEsc) {
    Write-Host "CCEDIT HARNESS: PASS -- inserted X, saved, and quit"
} else {
    Write-Host "CCEDIT HARNESS: FAIL -- expected $expectedEsc"
    exit 1
}
