# build.ps1 -- compile the native Windows console port of Claude Commander.
# Produces cc.exe (a PE that runs in any Windows 10/11 console: cmd, Windows
# Terminal, PowerShell host). Uses MinGW gcc if present, else gcc on PATH.
$ErrorActionPreference = "Stop"
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$gcc = "C:\ProgramData\mingw64\mingw64\bin\gcc.exe"
if (-not (Test-Path $gcc)) { $gcc = "gcc" }

& $gcc -O2 -Wall -o "$dir\cc.exe" "$dir\cc.c"
if ($LASTEXITCODE -ne 0) { throw "build failed ($LASTEXITCODE)" }
"cc.exe: {0:N0} bytes" -f (Get-Item "$dir\cc.exe").Length | Write-Host
