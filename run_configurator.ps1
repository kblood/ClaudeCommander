<#
  run_configurator.ps1 -- self-test / regression guard for configure.ps1.

  The configurator (configure.ps1) derives its feature catalogue by SCANNING the
  @feature manifests in mod/*.inc. cc.asm independently defines the same sets in
  its -dFEAT_MIN/STD/FULL tier block, and package.ps1 defines CCPOP as an explicit
  flag list. This test proves those two definitions can never silently diverge:

    for each canonical profile (MIN, STD, FULL, CCPOP) it builds
      (a) the CANONICAL binary  -- the exact nasm invocation cc.asm/package.ps1 use
      (b) the CONFIGURATOR binary -- configure.ps1 reproducing the same set
    and asserts (a) and (b) are BYTE-IDENTICAL (SHA-256), then /T-smokes each
    unique binary (runs it headless and checks it renders a frame).

  Exit 0 = all green; non-zero = a divergence or a dead build. No DOSBox? pass
  -NoSmoke to run the byte-equality checks only.
#>
param([switch]$NoSmoke)
$ErrorActionPreference = "Stop"
$dir  = "C:\LLM\cc"
$nasm = "C:\Users\Caldor\AppData\Local\bin\NASM\nasm.exe"
if (-not (Test-Path $nasm)) { $nasm = "nasm" }
$dbox = "$dir\dbstaging\dosbox-staging-v0.82.2\dosbox.exe"
$work = "$dir\_cfgtest"
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
New-Item -ItemType Directory -Path $work | Out-Null

# CCPOP's canonical flag list (mirror of package.ps1) = STD minus MENUBAR/TOOLS.
$popDefs = @(
    "-dFEAT_CUSTOM",
    "-dFEAT_WIDGETS","-dFEAT_CLOCK","-dFEAT_FREE","-dFEAT_VIEWS",
    "-dFEAT_TREE","-dFEAT_SORT","-dFEAT_COLS","-dFEAT_SEARCH","-dFEAT_MASK",
    "-dFEAT_MENU","-dFEAT_HELP","-dFEAT_EDIT","-dFEAT_FIND","-dFEAT_GREP",
    "-dFEAT_ZIP","-dFEAT_ATTR","-dFEAT_VFS","-dFEAT_VIEW","-dFEAT_INI",
    "-dFEAT_LANG","-dFEAT_LFN"
)
$popOnly = ($popDefs | ForEach-Object { $_ -replace '^-dFEAT_','' } | Where-Object { $_ -ne 'CUSTOM' })

function Asm([string[]]$defs,[string]$out) {
    & $nasm -f bin -i "$dir/" @defs "$dir\cc.asm" -o $out 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "nasm failed: $($defs -join ' ')" }
}
function Cfg([string[]]$cfgArgs,[string]$out) {
    & pwsh -NoProfile -File "$dir\configure.ps1" @cfgArgs -Out $out -Quiet
    if ($LASTEXITCODE -ne 0) { throw "configure.ps1 failed: $($cfgArgs -join ' ')" }
}
function Sha([string]$p) { (Get-FileHash $p -Algorithm SHA256).Hash }

# profile -> @{ ref-defs ; cfg-args }
$profiles = [ordered]@{
    MIN   = @{ ref=@("-dFEAT_MIN");  cfg=@("-Base","min") }
    STD   = @{ ref=@("-dFEAT_STD");  cfg=@("-Base","std") }
    FULL  = @{ ref=@("-dFEAT_FULL"); cfg=@("-Base","std") }   # FULL set == STD set today
    CCPOP = @{ ref=$popDefs;         cfg=@("-Only", ($popOnly -join ',')) }
}

$fail = 0
$uniqueBins = @{}
Write-Host "=== byte-equality: configurator vs canonical ==="
foreach ($name in $profiles.Keys) {
    $p = $profiles[$name]
    $ref = "$work\ref_$name.com"
    $cfg = "$work\cfg_$name.com"
    Asm $p.ref $ref
    Cfg $p.cfg $cfg
    $hr = Sha $ref; $hc = Sha $cfg
    $sz = (Get-Item $cfg).Length
    if ($hr -eq $hc) {
        Write-Host ("  {0,-6} OK   {1,7:N0} B   {2}" -f $name, $sz, $hc.Substring(0,16))
        $uniqueBins[$hc] = $cfg
    } else {
        Write-Host ("  {0,-6} FAIL configurator diverges from canonical" -f $name)
        Write-Host ("         ref={0}  cfg={1}" -f $hr.Substring(0,16), $hc.Substring(0,16))
        $fail++
    }
}

if (-not $NoSmoke) {
    if (-not (Test-Path $dbox)) {
        Write-Host "`n(skipping /T smoke: DOSBox not found at $dbox)"
    } else {
        Write-Host "`n=== /T smoke: each unique binary renders a frame ==="
        $sd = "$work\smoke"
        foreach ($h in $uniqueBins.Keys) {
            $bin = $uniqueBins[$h]
            if (Test-Path $sd) { Remove-Item $sd -Recurse -Force }
            New-Item -ItemType Directory -Path $sd | Out-Null
            Copy-Item $bin "$sd\T.COM" -Force
            [IO.File]::WriteAllText("$sd\A.TXT","hello")
            [IO.File]::WriteAllBytes("$sd\cc.key",[byte[]](0x00,0x44))   # F10 = quit
            $conf = @"
[sdl]
fullscreen = false
[cpu]
core    = normal
cputype = 486
cycles  = max
[autoexec]
@echo off
mount c $sd
c:
if exist ccdump.txt del ccdump.txt
T.COM /T
exit
"@
            Set-Content -Path "$work\_smoke.conf" -Value $conf -Encoding ASCII
            $pr = Start-Process -FilePath $dbox -ArgumentList @("-conf","$work\_smoke.conf","-noprimaryconf") -PassThru -WindowStyle Minimized
            if (-not $pr.WaitForExit(15000)) { $pr.Kill() | Out-Null }
            Start-Sleep -Milliseconds 200
            $dump = "$sd\CCDUMP.TXT"
            if ((Test-Path $dump) -and ((Get-Content $dump -Raw) -match 'FRAME')) {
                Write-Host ("  {0}  OK (frame rendered)" -f (Split-Path $bin -Leaf))
            } else {
                Write-Host ("  {0}  FAIL (no frame)" -f (Split-Path $bin -Leaf))
                $fail++
            }
        }
    }
}

Write-Host ""
if ($fail -eq 0) { Write-Host "CONFIGURATOR SELF-TEST: PASS"; exit 0 }
else { Write-Host ("CONFIGURATOR SELF-TEST: FAIL ({0} problem(s))" -f $fail); exit 1 }
