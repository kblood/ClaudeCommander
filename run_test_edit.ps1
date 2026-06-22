param(
    [string]$testfile = "TESTED.TXT",
    [string]$keyfile  = "cce_keys.bin",
    [string]$initial  = "Hello`r`nWorld`r`n"
)
$ErrorActionPreference = "Stop"
$dir  = "C:\LLM\cc"
$dbox = "$dir\dbstaging\dosbox-staging-v0.82.2\dosbox.exe"
$nasm = "C:\Users\Caldor\AppData\Local\bin\NASM\nasm.exe"
if (-not (Test-Path $nasm)) { $nasm = "nasm" }

# 1. assemble
& $nasm -f bin "$dir\cce.asm" -o "$dir\ccedit.com" 2>&1
if ($LASTEXITCODE -ne 0) { Write-Host "ASSEMBLE FAILED"; exit 1 }
Write-Host ("BUILD OK: {0} bytes" -f (Get-Item "$dir\ccedit.com").Length)

# 2. seed the file to edit (write raw bytes so CRLF is exact)
[IO.File]::WriteAllText("$dir\$testfile", $initial)

# 3. key script -> cce.key
Copy-Item "$dir\$keyfile" "$dir\cce.key" -Force

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

# 5. report the saved file as a byte-accurate hex/escape view
$bytes = [IO.File]::ReadAllBytes("$dir\$testfile")
$sb = New-Object System.Text.StringBuilder
foreach ($b in $bytes) {
    if ($b -eq 13) { [void]$sb.Append('\r') }
    elseif ($b -eq 10) { [void]$sb.Append('\n') }
    elseif ($b -ge 32 -and $b -lt 127) { [void]$sb.Append([char]$b) }
    else { [void]$sb.Append(('\x{0:X2}' -f $b)) }
}
Write-Host "===== SAVED FILE ($($bytes.Length) bytes) ====="
Write-Host $sb.ToString()
