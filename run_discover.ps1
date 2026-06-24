# run_discover.ps1 -- /T harness for FEAT_DISCOVER (W4 tool gating).
# One cc build (FEAT_DISCOVER + GREP/RESULTS/VIEW); two staged dirs that differ
# only in whether CCGREP.COM is present. In BOTH, drive Alt-F8 then F10 and dump.
#   present -> the grep prompt "Search file contents for" appears (key fires).
#   absent  -> NO prompt, NO "Bad command" (the key is a silent no-op).
$ErrorActionPreference = "Stop"
$dir  = "C:\LLM\cc"
$dbox = "$dir\dbstaging\dosbox-staging-v0.82.2\dosbox.exe"
$nasm = "C:\Users\Caldor\AppData\Local\bin\NASM\nasm.exe"
if (-not (Test-Path $nasm)) { $nasm = "nasm" }

& $nasm -f bin -i "$dir/" -dFEAT_CUSTOM -dFEAT_GREP -dFEAT_RESULTS -dFEAT_VIEW -dFEAT_DISCOVER "$dir\cc.asm" -o "$dir\ccdisc.com" 2>&1
if ($LASTEXITCODE -ne 0) { Write-Host "ASSEMBLE FAILED"; exit 1 }
Write-Host ("BUILD OK: ccdisc.com {0} bytes" -f (Get-Item "$dir\ccdisc.com").Length)
& $nasm -f bin -i "$dir/" "$dir\cgrep.asm" -o "$dir\ccgrep.com" 2>&1 | Out-Null

function MakeKeys($full) {
    $k = [System.Collections.Generic.List[byte]]::new()
    $k.Add(0x00); $k.Add(0x6F)                                  # Alt-F8 (grep)
    if ($full) {
        foreach ($ch in "NEEDLE".ToCharArray()) { $k.Add([byte][char]$ch); $k.Add(0x00) }
        $k.Add(0x0D); $k.Add(0x1C)                              # Enter -> run grep
    }
    $k.Add(0x00); $k.Add(0x44)                                  # F10 quit
    return $k.ToArray()
}

function Scenario($name, $withTool) {
    $td = "$dir\_disc_$name"
    if (Test-Path $td) { Remove-Item $td -Recurse -Force }
    New-Item -ItemType Directory -Path $td | Out-Null
    [IO.File]::WriteAllText("$td\DATA.TXT","hello NEEDLE world")
    if ($withTool) { Copy-Item "$dir\ccgrep.com" "$td\CCGREP.COM" }
    # present -> drive the full grep (expect a results row); absent -> Alt-F8 then
    # quit (expect a silent no-op, so don't type into the freed command line).
    [IO.File]::WriteAllBytes("$td\cc.key", (MakeKeys $withTool))
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
if exist ccdump.txt del ccdump.txt
c:\ccdisc.com /T
exit
"@
    Set-Content -Path "$dir\_run_disc.conf" -Value $conf -Encoding ASCII
    $p = Start-Process -FilePath $dbox -ArgumentList @("-conf","$dir\_run_disc.conf","-noprimaryconf") -PassThru -WindowStyle Minimized
    if (-not $p.WaitForExit(20000)) { $p.Kill() | Out-Null }
    Start-Sleep -Milliseconds 300
    $raw = Get-Content "$td\CCDUMP.TXT" -Raw
    return $raw
}

$present = Scenario "present" $true
$absent  = Scenario "absent"  $false

# present: CCGREP found -> Alt-F8 runs it -> a results row shows the matched line.
# absent : CCGREP not found -> Alt-F8 is a no-op -> no results row, no Bad command.
$pResults = $present -match 'hello NEEDLE'
$aResults = $absent  -match 'hello NEEDLE'
$aBad     = ($absent -match 'Bad command') -or ($absent -match 'Illegal command')

Write-Host ("`npresent: grep ran, matched-line row shown = {0}  (expect True)" -f $pResults)
Write-Host ("absent : matched-line row shown            = {0}  (expect False)" -f $aResults)
Write-Host ("absent : 'Bad command' from the tool       = {0}  (expect False)" -f $aBad)

if ($pResults -and -not $aResults -and -not $aBad) {
    Write-Host "`nDISCOVER HARNESS: PASS -- present tool fires, absent tool is a silent no-op"
} else {
    Write-Host "`nDISCOVER HARNESS: FAIL"
    Write-Host "----- present dump (frames joined) -----"; Write-Host $present
}
