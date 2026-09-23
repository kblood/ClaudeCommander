# cc.ps1 -- launcher that makes Claude Commander "cd on exit": when you quit,
# the PowerShell session is left in the directory of cc's active panel.
# A Windows program can't change its parent's current directory, so cc.exe
# writes the active panel's path to $env:CC_CWD_FILE and this wrapper Set-Locations
# there afterwards. Run it as ".\cc.ps1" (or put this folder on your PATH).
$f = Join-Path $env:TEMP ("cc_cwd_{0}.txt" -f ([guid]::NewGuid().ToString('N')))
$env:CC_CWD_FILE = $f
try {
    & (Join-Path $PSScriptRoot 'cc.exe') @args
} finally {
    Remove-Item Env:\CC_CWD_FILE -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $f) {
        # cc.exe writes the path as UTF-8 (no BOM); Windows PowerShell 5.1 would
        # otherwise read it in the ANSI codepage and mangle non-ASCII folders.
        $d = (Get-Content -LiteralPath $f -Raw -Encoding UTF8).Trim()
        Remove-Item -LiteralPath $f -ErrorAction SilentlyContinue
        if ($d -and (Test-Path -LiteralPath $d)) { Set-Location -LiteralPath $d }
    }
}
