# run_w3_diff.ps1 -- behavioural-identity gate for W3 (widget descriptor table).
# Builds the SAME feature set from the current tree (post-W3 wtab walker) and
# from HEAD (pre-W3, the hard-coded fan-outs), drives an identical /T key script
# that exercises panels + frames + command/fkey rows + footer + the menu bar
# (F9 dropdown via the key seam), and byte-compares the two CCDUMP.TXT files.
# CLOCK is left OUT of the set so the time-varying clock cells can't create a
# false diff; the clock's own code is unchanged by W3.
$ErrorActionPreference = "Stop"
$dir  = "C:\LLM\cc"
$dbox = "$dir\dbstaging\dosbox-staging-v0.82.2\dosbox.exe"
$nasm = "C:\Users\Caldor\AppData\Local\bin\NASM\nasm.exe"
if (-not (Test-Path $nasm)) { $nasm = "nasm" }
$defs = @("-dFEAT_CUSTOM","-dFEAT_FREE","-dFEAT_MENUBAR","-dFEAT_SORT","-dFEAT_COLS","-dFEAT_FIND")

function Build($out) {
    & $nasm -f bin -i "$dir/" @defs "$dir\cc.asm" -o $out 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "assemble failed: $out" }
}

# new (current working tree = post-W3)
Build "$dir\_w3new.com"
Write-Host ("post-W3 build: {0} bytes" -f (Get-Item "$dir\_w3new.com").Length)

# old (HEAD = pre-W3): stash just the two W3 files, build, restore
$stashed = $false
& git -C $dir stash push -q -- cc.asm mod/widgets.inc 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) { $stashed = $true }
try {
    Build "$dir\_w3old.com"
    Write-Host ("pre-W3  build: {0} bytes" -f (Get-Item "$dir\_w3old.com").Length)
} finally {
    if ($stashed) { & git -C $dir stash pop -q 2>&1 | Out-Null }
}

# stage a small dir
$td = "$dir\_w3test"
if (Test-Path $td) { Remove-Item $td -Recurse -Force }
New-Item -ItemType Directory -Path $td | Out-Null
New-Item -ItemType Directory -Path "$td\SUB" | Out-Null
[IO.File]::WriteAllText("$td\AFILE.TXT","a")
[IO.File]::WriteAllText("$td\BFILE.TXT","bb")
[IO.File]::WriteAllText("$td\CFILE.TXT","ccc")

# key script: Down, Down, F9 (open menu bar), Down, Esc, Tab, Up, F10
$keys = [System.Collections.Generic.List[byte]]::new()
function K([byte]$a,[byte]$b){ $script:keys.Add($a); $script:keys.Add($b) }
K 0x00 0x50    # Down
K 0x00 0x50    # Down
K 0x00 0x43    # F9 (open menu bar dropdown)
K 0x00 0x50    # Down (move in dropdown)
K 0x1B 0x01    # Esc (close dropdown)
K 0x09 0x0F    # Tab (switch panel)
K 0x00 0x48    # Up
K 0x00 0x44    # F10 (quit)
[IO.File]::WriteAllBytes("$td\cc.key",$keys.ToArray())

function RunDump($com,$label) {
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
c:\$com /T
exit
"@
    Set-Content -Path "$dir\_run_w3diff.conf" -Value $conf -Encoding ASCII
    $p = Start-Process -FilePath $dbox -ArgumentList @("-conf","$dir\_run_w3diff.conf","-noprimaryconf") -PassThru -WindowStyle Minimized
    if (-not $p.WaitForExit(20000)) { $p.Kill() | Out-Null }
    Start-Sleep -Milliseconds 300
    $out = "$dir\_dump_$label.txt"
    Copy-Item "$td\CCDUMP.TXT" $out -Force
    return $out
}

$newDump = RunDump "_w3new.com" "new"
$oldDump = RunDump "_w3old.com" "old"

$a = [IO.File]::ReadAllText($newDump)
$b = [IO.File]::ReadAllText($oldDump)
if ($a -eq $b) {
    Write-Host "`nW3 IDENTITY: PASS -- post-W3 and pre-W3 /T dumps are byte-identical"
    Write-Host ("  (dump length {0} bytes, frames: {1})" -f $a.Length, ([regex]::Matches($a,'FRAME')).Count)
} else {
    Write-Host "`nW3 IDENTITY: FAIL -- dumps differ"
    Write-Host ("  new={0} bytes  old={1} bytes" -f $a.Length, $b.Length)
    # show first differing line
    $la = $a -split "`n"; $lb = $b -split "`n"
    for ($i=0; $i -lt [Math]::Min($la.Count,$lb.Count); $i++) {
        if ($la[$i] -ne $lb[$i]) { Write-Host ("  first diff at line {0}:`n   new: {1}`n   old: {2}" -f $i,$la[$i],$lb[$i]); break }
    }
}
