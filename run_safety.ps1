# run_safety.ps1 -- headless safety/regression cases for cc's resident core.
#
# Each case stages a fresh DOS "disk" under $env:TEMP\cc_safety\<case>\ (C:, an
# optional D:, and E: = the helper .COMs + the exit marker), writes a cc.key
# script into cc's start directory, runs `E:\CC.COM /T` under DOSBox-staging
# and then asserts mainly on FILE-SYSTEM side effects in the staged host dirs
# (plus CCDUMP.TXT text where the effect is only visible on screen). The
# autoexec writes E:\EXITED.TXT after cc returns, so a hang / crash / DOS
# memory-chain abort shows up as a missing marker.
#
# The cases pin the data-loss / corruption bugs found in the core review:
#   move-xdrive-file, move-into-own-subdir, move-xdrive-copyfail-keeps-source,
#   move-skip-keeps-source, move-ro-dest-keeps-source, f8-on-archive-row,
#   rename-on-archive-row, move-from-archive-row, cmd-runs-in-panel-dir,
#   deep-path, long-command-tail, drives-both-panels, drives-results-shared-heap,
#   help-after-hexview, long-lng-label, long-cmdline-draw.
# The xseg_* cases stress the buffers kept outside cc's 64 KB segment (viewbuf,
# lineoff, res_heap, tree nodes) with exact content checks, including after an
# EXEC that clobbers FS/GS, and walk the DOS MCB chain from inside cc:
#   xseg_view_big, xseg_view_lines, xseg_grep_heap, xseg_find_heap,
#   xseg_exec_fs, xseg_ini, xseg_mcb, xseg_tree, xseg_zipdirs, xseg_nomem.
#   (.\run_safety.ps1 -Only xseg  runs just these; xseg_mcb prints the blocks
#   owned by cc's PSP before and after an EXEC.)
# After cc exits the autoexec also runs `mem`; a collapsed free-conventional
# figure means cc trashed the DOS MCB chain (checked for every case).
# Not covered (not observable in DOSBox-staging): disk-full / short writes
# (`mount -freesize` only reports, it is not enforced) and INT 24h critical
# errors (unmounted drives fail with "invalid drive", no critical error).
#
# Key-flow assumptions: F6/F5/Shift-F6 open a pre-filled name dialog that
# Enter accepts; F8 confirms with 'Y'; the overwrite prompt takes O/S/A/C;
# Ctrl-F6 quick-search + Esc positions the cursor; Alt-F1/Alt-F2 list drives
# as "X:" rows and Enter opens the drive root; a typed command waits for one
# key afterwards.
#
#   .\run_safety.ps1                       # all cases
#   .\run_safety.ps1 -Only move            # cases whose name matches 'move'
#   .\run_safety.ps1 -Flags FEAT_LFN_FULL  # extra nasm -d defines (';'-separated)
#   .\run_safety.ps1 -ShowLog              # print the dump of every failing case
# Exit code: 0 = all cases pass, 1 = at least one failure.
param(
    [string]$Flags = "",
    [switch]$ShowLog,
    [string]$Only = ""
)
$ErrorActionPreference = "Stop"

$repo  = $PSScriptRoot
$stage = Join-Path $env:TEMP "cc_safety"
$nasm  = "C:\Users\Caldor\AppData\Local\bin\NASM\nasm.exe"
if (-not (Test-Path $nasm)) { $nasm = "nasm" }

# DOSBox-staging lives in the main checkout (gitignored), so walk up from the
# script dir (a worktree sits under <main>\.claude\worktrees\<name>).
$dbox = $null
$probe = $repo
while ($probe) {
    $cand = Join-Path $probe "dbstaging\dosbox-staging-v0.82.2\dosbox.exe"
    if (Test-Path $cand) { $dbox = $cand; break }
    $parent = Split-Path $probe -Parent
    if ($parent -eq $probe) { break }
    $probe = $parent
}
if (-not $dbox -and (Test-Path "C:\LLM\DOS\cc\dbstaging\dosbox-staging-v0.82.2\dosbox.exe")) {
    $dbox = "C:\LLM\DOS\cc\dbstaging\dosbox-staging-v0.82.2\dosbox.exe"
}
if (-not $dbox) { Write-Host "DOSBox-staging not found above $repo"; exit 1 }

# ---------------------------------------------------------------------------
# build (once): CC.COM (+ -Flags), CCZIP.COM, CCFIND.COM, CCGREP.COM -> $stage\bin
# ---------------------------------------------------------------------------
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
$bin = Join-Path $stage "bin"
New-Item -ItemType Directory -Path $bin -Force | Out-Null

$na = @("-f", "bin", "-i", "$repo/")
if ($Flags -ne "") { foreach ($f in ($Flags -split "[;, ]+")) { if ($f) { $na += "-d$f" } } }
# NASM resolves %include "mod/x.inc" against its CWD first, so assemble from
# the repo dir (otherwise a caller's CWD could shadow this tree's modules).
Push-Location $repo
try {
    & $nasm @na "$repo\cc.asm" -o "$bin\CC.COM" 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) { Write-Host "ASSEMBLE FAILED (cc.asm)"; exit 1 }
    & $nasm -f bin "$repo\czip.asm" -o "$bin\CCZIP.COM" 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) { Write-Host "ASSEMBLE FAILED (czip.asm)"; exit 1 }
    & $nasm -f bin "$repo\cfind.asm" -o "$bin\CCFIND.COM" 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) { Write-Host "ASSEMBLE FAILED (cfind.asm)"; exit 1 }
    & $nasm -f bin "$repo\cgrep.asm" -o "$bin\CCGREP.COM" 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) { Write-Host "ASSEMBLE FAILED (cgrep.asm)"; exit 1 }
} finally { Pop-Location }
Write-Host ("BUILD OK: CC.COM {0} bytes{1}" -f (Get-Item "$bin\CC.COM").Length,
    $(if ($Flags) { " (flags: $Flags)" } else { "" }))

# ---------------------------------------------------------------------------
# key-script builder
# ---------------------------------------------------------------------------
$script:keys = $null
function Keys-Reset { $script:keys = [System.Collections.Generic.List[byte]]::new() }
function K([int]$a, [int]$s) { $script:keys.Add([byte]$a); $script:keys.Add([byte]$s) }
function Ext([int]$scan)     { K 0 $scan }
function Txt([string]$t)     { foreach ($ch in $t.ToCharArray()) { K ([int][char]$ch) 0 } }
function Enter { K 0x0D 0x1C }
function Esc   { K 0x1B 0x01 }
function Tab   { K 0x09 0x0F }
function Down  { Ext 0x50 }
function F1    { Ext 0x3B }
function F3    { Ext 0x3D }
function F6    { Ext 0x40 }
function F8    { Ext 0x42 }
function F10   { Ext 0x44 }
function ShiftF6 { Ext 0x59 }
function AltF1 { Ext 0x68 }
function AltF2 { Ext 0x69 }
function AltF7 { Ext 0x6E }
# quick-search (Ctrl-F6): land the active panel's cursor on the first entry
# whose name starts with $prefix, then Esc ends the search (Esc is consumed).
function QS([string]$prefix) { Ext 0x63; Txt $prefix; Esc }
# point the RIGHT panel at the root of drive $letter via the Alt-F2 drives
# view (quick-search the "X:" row, Enter). Leaves the right panel active.
function RightToDrive([string]$letter) { AltF2; QS "$($letter):"; Enter }

# ---------------------------------------------------------------------------
# case staging + DOSBox run
# ---------------------------------------------------------------------------
# New-Case -> hashtable with host dirs C (C:), D (D:), E (E: = bin + marker)
function New-Case([string]$name) {
    $root = Join-Path $stage $name
    $c = Join-Path $root "c"; $d = Join-Path $root "d"; $e = Join-Path $root "e"
    foreach ($p in @($c, $d, $e)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    Copy-Item "$bin\*.COM" $e
    Keys-Reset
    return @{ Name = $name; Root = $root; C = $c; D = $d; E = $e }
}
function HostDir($case, [string]$dosPath) {
    # "C:\SRC" -> <case>\c\SRC
    $drv = $dosPath.Substring(0, 1).ToUpper()
    $rest = $dosPath.Substring(2).TrimStart('\')
    $base = $case[$drv]
    if ($rest) { return (Join-Path $base $rest) } else { return $base }
}
function Put-File($case, [string]$dosPath, $content) {
    $h = HostDir $case $dosPath
    New-Item -ItemType Directory -Path (Split-Path $h -Parent) -Force | Out-Null
    if ($content -is [byte[]]) { [IO.File]::WriteAllBytes($h, $content) }
    else { [IO.File]::WriteAllText($h, [string]$content) }
}
function Put-Dir($case, [string]$dosPath) {
    New-Item -ItemType Directory -Path (HostDir $case $dosPath) -Force | Out-Null
}
function Exists($case, [string]$dosPath) { Test-Path -LiteralPath (HostDir $case $dosPath) }
function ReadText($case, [string]$dosPath) {
    $h = HostDir $case $dosPath
    if (Test-Path -LiteralPath $h -PathType Leaf) { return [IO.File]::ReadAllText($h) } else { return $null }
}

# Run cc /T with the current key script, CWD = $cwd (a C:\ path). All host
# files must already exist (DOSBox-staging caches directory listings).
# Returns @{ Exited; TimedOut; Frames; Raw }.
function Run-CC($case, [string]$cwd, [int]$timeoutMs = 15000) {
    $cwdHost = HostDir $case $cwd
    [IO.File]::WriteAllBytes((Join-Path $cwdHost "cc.key"), $script:keys.ToArray())
    $cdLine = if ($cwd.Length -gt 3) { "cd " + $cwd.Substring(2) } else { "cd \" }
    $conf = @"
[sdl]
fullscreen = false
[dosbox]
startup_verbosity = quiet
[cpu]
core    = normal
cputype = 486
cycles  = max
[mixer]
nosound = true
[autoexec]
@echo off
mount c $($case.C)
mount d $($case.D)
mount e $($case.E)
set PATH=Z:\;E:\
$($cwd.Substring(0,2))
$cdLine
E:\CC.COM /T
echo done> E:\EXITED.TXT
mem > E:\MEM.TXT
exit
"@
    $confPath = Join-Path $case.Root "run.conf"
    Set-Content -Path $confPath -Value $conf -Encoding ASCII
    # -exit: the autoexec's own `exit` does not close DOSBox-staging 0.82 here
    $p = Start-Process -FilePath $dbox -ArgumentList @("-conf", $confPath, "-noprimaryconf", "-exit") `
            -PassThru -WindowStyle Minimized
    $timedOut = $false
    if (-not $p.WaitForExit($timeoutMs)) { $timedOut = $true; try { $p.Kill() } catch {} ; $p.WaitForExit(3000) | Out-Null }
    Start-Sleep -Milliseconds 300
    $dump = Join-Path $cwdHost "CCDUMP.TXT"
    $raw = ""
    $frames = @()
    if (Test-Path $dump) {
        $bytes = [IO.File]::ReadAllBytes($dump)
        $raw = [Text.Encoding]::GetEncoding(28591).GetString($bytes)   # 1 byte = 1 char
        foreach ($chunk in ($raw -split "==== FRAME ====\r\n")) {
            $lines = $chunk -split "\r\n"
            if ($lines.Count -ge 25) { $frames += , ($lines[0..24]) }
        }
    }
    # `mem` after cc exits: a trashed MCB chain (e.g. a draw past the 4000-byte
    # back buffer) shows up as a collapsed free-conventional figure (~65 KB vs
    # ~632 KB), even though DOSBox-staging itself does not abort on it.
    $memKB = -1
    $memPath = Join-Path $case.E "MEM.TXT"
    if (Test-Path $memPath) {
        $m = [regex]::Match([IO.File]::ReadAllText($memPath), '(\d+)\s*KB free conventional')
        if ($m.Success) { $memKB = [int]$m.Groups[1].Value }
    }
    return @{ Exited = (Test-Path (Join-Path $case.E "EXITED.TXT")); TimedOut = $timedOut;
              Frames = $frames; Raw = $raw; MemKB = $memKB }
}

# frame accessors (menubar build: row 1 = top frame/titles, rows 2..21 = files)
function LeftList($f)  { ($f[2..21] | ForEach-Object { $_.Substring(1, 38) }) -join "`n" }
function RightList($f) { ($f[2..21] | ForEach-Object { $_.Substring(40, 39) }) -join "`n" }
function CmdPath($f)   { $r = $f[23]; $i = $r.IndexOf('>'); if ($i -ge 0) { $r.Substring(0, $i) } else { $r } }
function LastFrame($run) { if ($run.Frames.Count) { $run.Frames[$run.Frames.Count - 1] } else { $null } }
function FrameText($f) { $f -join "`n" }

# ---------------------------------------------------------------------------
# result bookkeeping
# ---------------------------------------------------------------------------
$results = [System.Collections.Generic.List[object]]::new()
function Report($case, $run, [string[]]$fails, [string]$okMsg) {
    $ok = ($fails.Count -eq 0)
    $tag = if ($ok) { "PASS" } else { "FAIL" }
    $msg = if ($ok) { $okMsg } else { $fails -join "; " }
    Write-Host ("{0}  {1,-36} {2}" -f $tag, $case.Name, $msg)
    $results.Add([pscustomobject]@{ Name = $case.Name; Ok = $ok })
    if (-not $ok -and $ShowLog -and $run) {
        Write-Host "----- $($case.Name): last frames of CCDUMP.TXT -----"
        $n = $run.Frames.Count
        $from = [Math]::Max(0, $n - 4)
        for ($i = $from; $i -lt $n; $i++) { Write-Host "[frame $i/$n]"; Write-Host (FrameText $run.Frames[$i]) }
        Write-Host "----- end $($case.Name) -----"
    }
}
function Want([string]$name) { return ($Only -eq "" -or $name -match $Only) }
function ExitCheck($run, [System.Collections.Generic.List[string]]$fails) {
    if ($run.TimedOut) { $fails.Add("DOSBox timed out (cc hung?)") }
    elseif (-not $run.Exited) { $fails.Add("no exit marker (cc did not return to the shell)") }
    elseif ($run.MemKB -ge 0 -and $run.MemKB -lt 500) {
        $fails.Add("DOS memory chain damaged: only $($run.MemKB) KB conventional free after cc exited")
    }
    if ($run.Frames.Count -eq 0) { $fails.Add("no CCDUMP frames") }
}
# make control characters visible in a failure message
function Vis([string]$s) { return ([regex]::Replace($s, '[\x00-\x1F\x7F]', { param($m) '<{0:X2}>' -f [int][char]$m.Value })) }
function NewFails { return , ([System.Collections.Generic.List[string]]::new()) }

# ===========================================================================
# CASES
# ===========================================================================

# 1. cross-drive move of a single file (bugs #1/#5: DL=attr clobbered by
#    `mov dx,targpath` before the INT 21h/56h fallback).
if (Want "move-xdrive-file") {
    $c = New-Case "move-xdrive-file"
    $payload = "cross-drive payload 0123456789`r`n" * 20
    Put-File $c "C:\SRC\FILE.TXT" $payload
    RightToDrive "D"          # right panel -> D:\ (right active)
    Tab                       # left (C:\SRC) active
    QS "FILE"
    F6; Enter                 # "Move to other panel as: FILE.TXT" -> accept
    $run = Run-CC $c "C:\SRC"
    $f = NewFails; ExitCheck $run $f
    $dst = ReadText $c "D:\FILE.TXT"
    if ($null -eq $dst) { $f.Add("D:\FILE.TXT missing") }
    elseif ($dst -ne $payload) { $f.Add("D:\FILE.TXT content differs ($($dst.Length) vs $($payload.Length) bytes)") }
    if (Exists $c "C:\SRC\FILE.TXT") { $f.Add("source C:\SRC\FILE.TXT still present") }
    if (Test-Path -LiteralPath (HostDir $c "D:\FILE.TXT") -PathType Container) { $f.Add("D:\FILE.TXT was created as a DIRECTORY") }
    Report $c $run $f "file moved C:\SRC -> D:\ intact"
}

# 2. move a directory into its own subdirectory (#2) -> must be refused.
if (Want "move-into-own-subdir") {
    $c = New-Case "move-into-own-subdir"
    Put-File $c "C:\DIRA\KEEP.TXT" "keep me"
    Put-File $c "C:\DIRA\SUB\INNER.TXT" "inner"
    Tab; QS "DIRA"; Enter; QS "SUB"; Enter   # right panel -> C:\DIRA\SUB
    Tab; QS "DIRA"                           # left cursor on DIRA
    F6; Enter
    $run = Run-CC $c "C:\"
    $f = NewFails; ExitCheck $run $f
    if (-not (Exists $c "C:\DIRA\KEEP.TXT")) { $f.Add("C:\DIRA\KEEP.TXT deleted") }
    if (-not (Exists $c "C:\DIRA\SUB\INNER.TXT")) { $f.Add("C:\DIRA\SUB\INNER.TXT deleted") }
    if (Exists $c "C:\DIRA\SUB\DIRA") { $f.Add("C:\DIRA\SUB\DIRA was created (move not refused)") }
    Report $c $run $f "refused; tree intact"
}

# 3. cross-drive DIRECTORY move whose copy fails (D:\PKG is a plain file, so the
#    mkdir fails) -> the source tree must be kept (#1).
if (Want "move-xdrive-copyfail-keeps-source") {
    $c = New-Case "move-xdrive-copyfail-keeps-source"
    Put-File $c "C:\SRC\PKG\INNER.TXT" "inner payload"
    Put-File $c "D:\PKG" "i am a file, not a folder"
    RightToDrive "D"; Tab
    QS "PKG"
    F6; Enter
    $run = Run-CC $c "C:\SRC"
    $f = NewFails; ExitCheck $run $f
    if (-not (Exists $c "C:\SRC\PKG\INNER.TXT")) { $f.Add("source C:\SRC\PKG\INNER.TXT deleted although the copy failed") }
    if ((ReadText $c "D:\PKG") -ne "i am a file, not a folder") { $f.Add("D:\PKG (file) was altered") }
    Report $c $run $f "copy failed, source kept"
}

# 3b. same-drive move onto an existing same-named file, answer [Skip] at the
#     overwrite prompt -> the source must be kept.
if (Want "move-skip-keeps-source") {
    $c = New-Case "move-skip-keeps-source"
    Put-File $c "C:\SRC\RO.TXT" "source body"
    Put-File $c "C:\DST\RO.TXT" "dest body"
    Tab; QS "DST"; Enter; Tab               # right -> C:\DST
    QS "SRC"; Enter; QS "RO"                # left  -> C:\SRC, cursor RO.TXT
    F6; Enter                               # accept the name
    Txt "S"                                 # overwrite prompt -> Skip
    $run = Run-CC $c "C:\"
    $f = NewFails; ExitCheck $run $f
    if (($run.Raw -notmatch 'File exists - overwrite\?')) { $f.Add("overwrite prompt never shown") }
    if (-not (Exists $c "C:\SRC\RO.TXT")) { $f.Add("source C:\SRC\RO.TXT deleted after Skip") }
    if ((ReadText $c "C:\DST\RO.TXT") -ne "dest body") { $f.Add("C:\DST\RO.TXT changed after Skip") }
    Report $c $run $f "skip kept both files"
}

# 3c. same-drive move onto a READ-ONLY same-named file, answer [Overwrite]: the
#     create fails -> the source must be kept.
if (Want "move-ro-dest-keeps-source") {
    $c = New-Case "move-ro-dest-keeps-source"
    Put-File $c "C:\SRC\RO.TXT" "source body"
    Put-File $c "C:\DST\RO.TXT" "read-only dest"
    (Get-Item -LiteralPath (HostDir $c "C:\DST\RO.TXT")).IsReadOnly = $true
    Tab; QS "DST"; Enter; Tab
    QS "SRC"; Enter; QS "RO"
    F6; Enter
    Txt "O"                                 # overwrite prompt -> Overwrite
    $run = Run-CC $c "C:\"
    $f = NewFails; ExitCheck $run $f
    if (($run.Raw -notmatch 'File exists - overwrite\?')) { $f.Add("overwrite prompt never shown") }
    if (-not (Exists $c "C:\SRC\RO.TXT")) { $f.Add("source C:\SRC\RO.TXT deleted although the overwrite failed") }
    if ((ReadText $c "C:\DST\RO.TXT") -ne "read-only dest") { $f.Add("read-only C:\DST\RO.TXT changed") }
    Report $c $run $f "failed overwrite kept the source"
}

# 4. F8 / Shift-F6 / F6 on a member row of an archive panel must never touch
#    the same-named REAL file in the archive's folder (#3).
function New-ZipCase([string]$name) {
    $c = New-Case $name
    Put-File $c "C:\WORK\FOO.TXT" "REAL FILE - must survive"
    Put-Dir  $c "C:\WORK\DEST"
    Put-File $c "C:\WORK\cc.ini" "[open]`r`nzip = CCZIP`r`n"
    $zipHost = HostDir $c "C:\WORK\T.ZIP"
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $fs = [IO.File]::Open($zipHost, [IO.FileMode]::Create)
    $za = [IO.Compression.ZipArchive]::new($fs, [IO.Compression.ZipArchiveMode]::Create)
    $en = $za.CreateEntry("FOO.TXT")
    $w = [IO.StreamWriter]::new($en.Open()); $w.Write("archive member body"); $w.Dispose()
    $za.Dispose(); $fs.Dispose()
    return $c
}
function ZipOpened($run) {
    # some frame shows the archive panel: title T.ZIP and a FOO.TXT row
    foreach ($fr in $run.Frames) { if ($fr[1] -match 'T\.ZIP' -and (LeftList $fr) -match 'FOO') { return $true } }
    return $false
}
if (Want "f8-on-archive-row") {
    $c = New-ZipCase "f8-on-archive-row"
    QS "T."; Enter              # open T.ZIP as a folder (CCZIP via cc.ini [open])
    Down                        # ".." -> FOO.TXT member
    F8; Txt "Y"                 # delete? -> Yes
    $run = Run-CC $c "C:\WORK"
    $f = NewFails; ExitCheck $run $f
    if (-not (ZipOpened $run)) { $f.Add("archive panel never showed FOO.TXT (key flow broken)") }
    if ((ReadText $c "C:\WORK\FOO.TXT") -ne "REAL FILE - must survive") { $f.Add("REAL C:\WORK\FOO.TXT deleted by F8 on the archive row") }
    if (-not (Exists $c "C:\WORK\T.ZIP")) { $f.Add("T.ZIP deleted") }
    Report $c $run $f "real file untouched"
}
if (Want "rename-on-archive-row") {
    $c = New-ZipCase "rename-on-archive-row"
    QS "T."; Enter; Down
    ShiftF6; Txt "BAR.TXT"; Enter
    $run = Run-CC $c "C:\WORK"
    $f = NewFails; ExitCheck $run $f
    if (-not (ZipOpened $run)) { $f.Add("archive panel never showed FOO.TXT (key flow broken)") }
    if (-not (Exists $c "C:\WORK\FOO.TXT")) { $f.Add("REAL C:\WORK\FOO.TXT renamed away by Shift-F6 on the archive row") }
    if (Exists $c "C:\WORK\BAR.TXT") { $f.Add("C:\WORK\BAR.TXT created") }
    Report $c $run $f "real file untouched"
}
if (Want "move-from-archive-row") {
    $c = New-ZipCase "move-from-archive-row"
    Tab; QS "DEST"; Enter; Tab              # right -> C:\WORK\DEST
    QS "T."; Enter; Down                    # left: archive, cursor FOO.TXT
    F6; Enter
    $run = Run-CC $c "C:\WORK"
    $f = NewFails; ExitCheck $run $f
    if (-not (ZipOpened $run)) { $f.Add("archive panel never showed FOO.TXT (key flow broken)") }
    if ((ReadText $c "C:\WORK\FOO.TXT") -ne "REAL FILE - must survive") { $f.Add("REAL C:\WORK\FOO.TXT moved/deleted by F6 on the archive row") }
    $moved = ReadText $c "C:\WORK\DEST\FOO.TXT"
    if ($moved -eq "REAL FILE - must survive") { $f.Add("the REAL file landed in DEST") }
    Report $c $run $f "real file untouched"
}

# 5. a typed command runs in the ACTIVE PANEL's directory (#4).
if (Want "cmd-runs-in-panel-dir") {
    $c = New-Case "cmd-runs-in-panel-dir"
    Put-Dir $c "C:\SUB"
    Put-Dir $c "C:\RUN"                     # cc starts here (the DOS current dir)
    K 0x08 0x0E                             # Backspace (empty line) -> left panel C:\
    QS "SUB"; Enter                         # -> C:\SUB
    Txt "echo x > MARK.TXT"; Enter
    K 0x20 0x39                             # "Press any key" after the command
    $run = Run-CC $c "C:\RUN"
    $f = NewFails; ExitCheck $run $f
    $inSub = $false
    foreach ($fr in $run.Frames) { if ((CmdPath $fr) -eq "C:\SUB" -and $fr[23] -match 'echo x') { $inSub = $true } }
    if (-not $inSub) { $f.Add("never typed the command in C:\SUB (key flow broken)") }
    if (-not (Exists $c "C:\SUB\MARK.TXT")) {
        $where = @()
        if (Exists $c "C:\RUN\MARK.TXT") { $where += "C:\RUN (launch dir)" }
        if (Exists $c "C:\MARK.TXT") { $where += "C:\" }
        $f.Add("C:\SUB\MARK.TXT missing" + $(if ($where) { "; landed in " + ($where -join ", ") } else { "" }))
    }
    Report $c $run $f "command ran in C:\SUB"
}

# 6. a directory chain deeper than the 67-char P_PATH buffer (#9).
if (Want "deep-path") {
    $c = New-Case "deep-path"
    $names = 1..9 | ForEach-Object { "L$_" + ("X" * 6) }         # L1XXXXXX .. L9XXXXXX
    $deep = "C:\" + ($names -join "\")                           # 2 + 9*9 = 83 chars
    Put-File $c ($deep + "\BOTTOM.TXT") "bottom"
    Put-File $c "C:\RIGHTMRK.TXT" "right panel marker"
    foreach ($n in $names) { QS "L"; Enter }                     # descend the chain
    K 0x08 0x0E; K 0x08 0x0E                                     # Backspace x2 -> up
    Tab                                                          # look at the right panel
    $run = Run-CC $c "C:\"
    $f = NewFails; ExitCheck $run $f
    $bad = @(); $maxLen = 0
    for ($i = 0; $i -lt $run.Frames.Count; $i++) {
        $fr = $run.Frames[$i]
        $p = (CmdPath $fr).TrimEnd()
        if ($p -notmatch '^C:\\') { continue }                   # dialog/viewer frames
        if ($p.Length -gt $maxLen) { $maxLen = $p.Length }
        if (-not $deep.StartsWith($p) -or ($p.Length -gt 3 -and $deep.Length -gt $p.Length -and $deep[$p.Length] -ne '\')) {
            $bad += "frame ${i}: path '$(Vis $p)'"
        }
    }
    if ($bad.Count) { $f.Add("corrupt panel path (" + (($bad | Select-Object -First 1) -join "") + ")") }
    if ($maxLen -gt 67) { $f.Add("panel path reached $maxLen chars (> 67-byte P_PATH)") }
    $lf = LastFrame $run
    if ($lf) {
        if ((RightList $lf) -notmatch 'RIGHTMRK') { $f.Add("right panel no longer lists C:\ (RIGHTMRK.TXT missing)") }
        if ($lf[1].Substring(40) -notmatch ' C:\\ ') { $f.Add("right panel title is not 'C:\'") }
    }
    Report $c $run $f "deepest shown path $maxLen chars; panels sane"
}

# 7. a command line at the 127-char cap: " /C " + 127 chars + CR is 133 bytes
#    in the 132-byte cmdtail, so the CR lands on comspec_buf[0] (#8) and the
#    EXEC of that very command fails. The command is "md M1" padded with
#    spaces, so it still works if a fix truncates the tail; the NEXT command
#    must run as well.
if (Want "long-command-tail") {
    $c = New-Case "long-command-tail"
    Txt ("md M1" + (" " * 125)); Enter      # 130 typed, capped at 127 by cmd_addchar
    K 0x20 0x39                             # "Press any key" after the command
    Txt "echo y > M2.TXT"; Enter
    K 0x20 0x39
    $run = Run-CC $c "C:\"
    $f = NewFails; ExitCheck $run $f
    if (-not (Test-Path -LiteralPath (HostDir $c "C:\M1") -PathType Container)) { $f.Add("127-char command did not run (C:\M1 missing: EXEC tail overflowed into COMSPEC)") }
    if (-not (Exists $c "C:\M2.TXT")) { $f.Add("next command did not run (C:\M2.TXT missing)") }
    Report $c $run $f "both commands ran"
}

# 8a. Alt-F1 drives view in the left panel, then Alt-F2 in the right: the two
#     SRC_RESULT panels would share res_heap (#11) -> the first must be reset
#     to a real directory listing.
if (Want "drives-both-panels") {
    $c = New-Case "drives-both-panels"
    Put-File $c "C:\LEFTMRK.TXT" "x"
    AltF1; AltF2
    $run = Run-CC $c "C:\"
    $f = NewFails; ExitCheck $run $f
    $lf = LastFrame $run
    if ($lf) {
        $l = LeftList $lf
        if ($l -notmatch 'LEFTMRK') { $f.Add("left panel still shows a stale drives list (no LEFTMRK.TXT)") }
        if ((RightList $lf) -notmatch 'D:') { $f.Add("right panel does not show the drives list") }
    }
    Report $c $run $f "left panel reset to C:\ listing"
}

# 8b. Alt-F7 find results in the right panel, then Alt-F1 drives view on the
#     left: the drives list overwrites the results' res_heap paths (#11).
if (Want "drives-results-shared-heap") {
    $c = New-Case "drives-results-shared-heap"
    Put-File $c "C:\SUB\TARGET.TXT" "found me"
    Put-File $c "C:\RMARK.TXT" "x"
    AltF7; Txt "TARGET.TXT"; Enter          # results -> right panel (focused)
    AltF1                                   # drives -> left panel (reuses res_heap)
    $run = Run-CC $c "C:\"
    $f = NewFails; ExitCheck $run $f
    $sawResult = $false
    foreach ($fr in $run.Frames) { if ((RightList $fr) -match 'TARGET\.TXT') { $sawResult = $true } }
    if (-not $sawResult) { $f.Add("find results never shown (key flow / CCFIND broken)") }
    $lf = LastFrame $run
    if ($lf) {
        $r = RightList $lf
        if ($r -match 'TARGET') { $f.Add("right panel still shows the stale results list (paths now point into the drives heap)") }
        elseif ($r -notmatch 'RMARK') { $f.Add("right panel not reset to a real listing") }
    }
    Report $c $run $f "results panel reset when the heap was reused"
}

# 9. F1 help after leaving the viewer in hex mode must render as TEXT (#15).
if (Want "help-after-hexview") {
    $c = New-Case "help-after-hexview"
    Copy-Item "$repo\cc.hlp" (HostDir $c "C:\cc.hlp")
    Put-File $c "C:\VIEWME.TXT" "some text to view`r`nline two`r`n"
    QS "VIEWME"; F3                         # built-in pager (text)
    Txt "h"                                 # -> hex
    Esc                                     # leave the viewer
    F1                                      # help
    Esc
    $run = Run-CC $c "C:\"
    $f = NewFails; ExitCheck $run $f
    $sawHex = $false; $helpText = $false
    foreach ($fr in $run.Frames) {
        $t = FrameText $fr
        if ($t -match '\[ Hex \]') { $sawHex = $true }
        if ($t -match 'Claude Commander \(cc\) -- Keyboard Help') { $helpText = $true }
    }
    if (-not $sawHex) { $f.Add("viewer never switched to hex (key flow broken)") }
    if (-not $helpText) { $f.Add("F1 help did not render as text (shown as hex dump)") }
    Report $c $run $f "help rendered as text"
}

# 10a. over-long cc.lng F-key labels (#7): slot 1 is 14 chars (spills into
#      slot 2's cells) and slot 10 is ~85 chars, which runs past the end of
#      the 4000-byte back buffer into the next MCB. Expect each label clipped
#      to its 8-cell slot and an intact DOS memory chain after exit.
if (Want "long-lng-label") {
    $c = New-Case "long-lng-label"
    $lng = "1HelpLongLabel`r`n2Menu`r`n3View`r`n4Edit`r`n5Copy`r`n6Move`r`n7MkDir`r`n8Del`r`n9Menu`r`n10" + ("Q" * 90) + "`r`n"
    Put-File $c "C:\cc.lng" $lng
    $run = Run-CC $c "C:\"
    $f = NewFails; ExitCheck $run $f
    $lf = LastFrame $run
    if ($lf) {
        $row = $lf[24]
        if (-not $row.StartsWith("1HelpLon")) { $f.Add("cc.lng not applied? F-key row '$(Vis $row.Substring(0,24))'") }
        elseif ($row.Substring(8, 8) -ne "2Menu   ") { $f.Add("slot-1 label spilled into slot 2: '$(Vis $row.Substring(0,24))'") }
    }
    Report $c $run $f "labels clipped to their slots; memory chain intact"
}

# 10b. a very long typed command line under a long prompt path: "path>" + 127
#      chars wraps from row 23 past the end of the back buffer (#7).
if (Want "long-cmdline-draw") {
    $c = New-Case "long-cmdline-draw"
    $deepCwd = "C:\AAAAAAAA\BBBBBBBB\CCCCCCCC\DDDDDDDD"     # 38-char prompt path
    Put-Dir $c $deepCwd
    Txt ("Z" * 130)                         # typed, capped at 127
    Esc                                     # clear the line again
    $run = Run-CC $c $deepCwd
    $f = NewFails; ExitCheck $run $f
    $sawLong = $false
    foreach ($fr in $run.Frames) {
        if ($fr[23] -match 'Z{20}') { $sawLong = $true }
        if ($fr[0] -match 'Z{3}') { $f.Add("command text wrapped onto row 0"); break }
    }
    if (-not $sawLong) { $f.Add("typed command never shown (key flow broken)") }
    Report $c $run $f "command line clipped; memory chain intact"
}

# ===========================================================================
# xseg_* cases: the buffers that live (or are moving) OUTSIDE cc's 64 KB
# program segment -- viewbuf (F3 pager text, cc.ini parse, archive listing,
# results-file parse), lineoff (pager line table) and res_heap (results-panel
# full paths). A wrong segment register on any access shows up as blank or
# garbage text where exact file content is expected, so every assertion here
# compares rendered rows byte-for-byte against the staged files. FS must also
# survive (be reloaded after) every EXEC: xseg_exec_fs runs a helper that
# clobbers FS/GS first. xseg_mcb walks the DOS MCB chain from inside cc.
# ===========================================================================
function Home  { Ext 0x47 }
function EndK  { Ext 0x4F }
function PgDn  { Ext 0x51 }
function Up    { Ext 0x48 }
function AltF8 { Ext 0x6F }
function AnyKey { K 0x20 0x39 }            # the "press any key" after a typed command

# assemble a tiny helper .COM from NASM source into the case's E:\ (on PATH)
function Build-Com($case, [string]$name, [string]$src) {
    $asm = Join-Path $case.Root "$name.asm"
    [IO.File]::WriteAllText($asm, $src)
    & $nasm -f bin $asm -o (Join-Path $case.E "$name.COM") 2>&1 | Out-Host
    return ($LASTEXITCODE -eq 0)
}
# FSCLOB: drop a marker, then leave FS/GS pointing at the BIOS ROM (F000h) and
# exit. DOSBox passes FS through EXEC/COMMAND.COM untouched, so a cc that fails
# to reload FS then reads/writes xseg data at F000:xxxx. ROM is write-protected
# there, so the file text read "into" it is lost and the pager shows ROM bytes.
# (A RAM value such as 1234h would NOT catch it: the read and the render would
# both go through the same wrong-but-writable segment and still agree.)
$src_fsclob = @'
        org     100h
        mov     ah, 3Ch
        xor     cx, cx
        mov     dx, mark
        int     21h
        jc      .go
        mov     bx, ax
        mov     ah, 3Eh
        int     21h
.go:    mov     ax, 0F000h
        mov     fs, ax
        mov     gs, ax
        mov     ax, 4C00h
        int     21h
mark    db 'C:\FSRAN.TXT', 0
'@
# TAILHIT: write the command tail (PSP:80h) into a marker file; optionally
# print a fake "<size> <name>" archive listing to stdout (an [open] helper).
function Src-TailHit([string]$marker, [string]$listing) {
    $lst = ""
    if (-not $listing) { $listing = "0" }
    else {
        $lst = @"
        mov     ah, 40h
        mov     bx, 1
        mov     cx, lst_end - lst
        mov     dx, lst
        int     21h
"@
    }
    return @"
        org     100h
        mov     ah, 3Ch
        xor     cx, cx
        mov     dx, mark
        int     21h
        jc      .lst
        mov     bx, ax
        mov     cl, [80h]
        xor     ch, ch
        mov     dx, 81h
        mov     ah, 40h
        int     21h
        mov     ah, 3Eh
        int     21h
.lst:
$lst
        mov     ax, 4C00h
        int     21h
mark    db '$marker', 0
lst     db $listing
lst_end:
"@
}
# MCBWALK <outfile>: our PSP, 3 parent PSPs (PSP:16h), the first MCB (List of
# Lists - 2), then one "MCB seg sig owner size name" line per arena block,
# stopping at 'Z' or a bad signature ("BAD seg"). Ends with "END count".
$src_mcbwalk = @'
        org     100h
start:  cld
        mov     si, 81h                 ; output file name from the tail
.sk:    lodsb
        cmp     al, ' '
        je      .sk
        cmp     al, 9
        je      .sk
        dec     si
        mov     di, fname
.cp:    lodsb
        cmp     al, ' '
        jbe     .cpe
        stosb
        jmp     .cp
.cpe:   mov     byte [di], 0
        cmp     di, fname
        jne     .open
        mov     si, defname
        mov     di, fname
        call    cpz
        mov     byte [di], 0
.open:  mov     ah, 3Ch
        xor     cx, cx
        mov     dx, fname
        int     21h
        jc      quit
        mov     [fh], ax
        mov     ah, 62h
        int     21h                     ; bx = our PSP
        mov     [cur], bx
        mov     si, s_psp
        mov     ax, bx
        call    kv
        mov     byte [pdig], '1'
.par:   push    ds
        mov     ds, [cur]
        mov     ax, [16h]               ; parent PSP
        pop     ds
        mov     [cur], ax
        mov     dl, [pdig]
        mov     [s_parent+6], dl
        mov     si, s_parent
        call    kv
        inc     byte [pdig]
        cmp     byte [pdig], '4'
        jb      .par
        mov     ah, 52h
        int     21h
        mov     ax, [es:bx-2]           ; first MCB segment
        push    cs
        pop     es
        mov     [seg_], ax
        mov     si, s_first
        call    kv
        mov     word [cnt], 0
.walk:  push    ds
        mov     ds, [cs:seg_]
        xor     si, si
        mov     di, hdr
        mov     cx, 16
        rep     movsb                   ; copy the 16-byte arena header
        pop     ds
        mov     al, [hdr]
        cmp     al, 'M'
        je      .ok
        cmp     al, 'Z'
        je      .ok
        mov     si, s_bad
        mov     ax, [seg_]
        call    kv
        jmp     .fin
.ok:    inc     word [cnt]
        mov     di, line
        mov     si, s_mcb
        call    cpz
        mov     ax, [seg_]
        call    hex4
        mov     al, ' '
        stosb
        mov     al, [hdr]
        stosb
        mov     al, ' '
        stosb
        mov     ax, [hdr+1]
        call    hex4
        mov     al, ' '
        stosb
        mov     ax, [hdr+3]
        call    hex4
        mov     al, ' '
        stosb
        mov     si, hdr+8
        mov     cx, 8
.nm:    lodsb
        or      al, al
        jz      .nme
        cmp     al, 20h
        jb      .nb
        cmp     al, 7Eh
        jbe     .ns
.nb:    mov     al, '_'
.ns:    stosb
        loop    .nm
.nme:   call    wline
        cmp     byte [hdr], 'Z'
        je      .fin
        cmp     word [cnt], 400
        jae     .fin
        mov     ax, [seg_]
        add     ax, [hdr+3]
        jc      .ovf
        add     ax, 1
        jc      .ovf
        mov     [seg_], ax
        jmp     .walk
.ovf:   mov     si, s_bad
        mov     ax, 0FFFFh
        call    kv
.fin:   mov     si, s_end
        mov     ax, [cnt]
        call    kv
        mov     bx, [fh]
        mov     ah, 3Eh
        int     21h
quit:   mov     ax, 4C00h
        int     21h
kv:     push    ax                      ; "label XXXX" line
        mov     di, line
        call    cpz
        pop     ax
        call    hex4
wline:  mov     ax, 0A0Dh
        stosw
        mov     cx, di
        sub     cx, line
        mov     ah, 40h
        mov     bx, [fh]
        mov     dx, line
        int     21h
        ret
cpz:    lodsb
        or      al, al
        jz      .d
        stosb
        jmp     cpz
.d:     ret
hex4:   mov     cx, 4
.l:     rol     ax, 4
        push    ax
        and     al, 0Fh
        add     al, '0'
        cmp     al, '9'
        jbe     .dg
        add     al, 7
.dg:    stosb
        pop     ax
        loop    .l
        ret
defname db 'MCB.TXT', 0
s_psp   db 'PSP ', 0
s_parent db 'PARENTx ', 0
s_first db 'FIRST ', 0
s_mcb   db 'MCB ', 0
s_bad   db 'BAD ', 0
s_end   db 'END ', 0
fh      dw 0
cur     dw 0
seg_    dw 0
cnt     dw 0
pdig    db 0
hdr     times 16 db 0
fname   times 80 db 0
line    times 100 db 0
'@

# --- pager helpers ----------------------------------------------------------
# Expected pager text row for the line starting at $off of the first $vlen
# bytes (view_build_lines/render_view: CR skipped, controls as '.', <= 80 cols).
function PagerRow([byte[]]$b, [int]$off, [int]$vlen) {
    $sb = [Text.StringBuilder]::new()
    for ($p = $off; $p -lt $vlen -and $sb.Length -lt 80; $p++) {
        $c = $b[$p]
        if ($c -eq 0x0A) { break }
        if ($c -eq 0x0D) { continue }
        if ($c -lt 0x20) { [void]$sb.Append('.') } else { [void]$sb.Append([char]$c) }
    }
    return $sb.ToString().TrimEnd()
}
# line start offsets exactly as view_build_lines builds lineoff (MAX_VLINES cap)
function PagerLines([byte[]]$b, [int]$vlen, [int]$maxLines = 1024) {
    $starts = [System.Collections.Generic.List[int]]::new()
    if ($vlen -le 0) { return , $starts }
    $starts.Add(0)
    for ($p = 0; $p -lt $vlen; $p++) {
        if ($b[$p] -eq 0x0A -and ($p + 1) -lt $vlen -and $starts.Count -lt $maxLines) { $starts.Add($p + 1) }
    }
    return , $starts
}
# expected hex row (hex_format_row): "OOOOOOOO  hh hh .. hh  ascii16"
function HexRow([byte[]]$b, [int]$off, [int]$vlen) {
    $sb = [Text.StringBuilder]::new()
    [void]$sb.Append(("{0:X8}  " -f $off))
    for ($i = 0; $i -lt 16; $i++) {
        $p = $off + $i
        if ($p -lt $vlen) { [void]$sb.Append(("{0:X2} " -f $b[$p])) } else { [void]$sb.Append("   ") }
    }
    [void]$sb.Append(' ')
    for ($i = 0; $i -lt 16; $i++) {
        $p = $off + $i
        if ($p -ge $vlen) { [void]$sb.Append(' ') }
        elseif ($b[$p] -lt 0x20 -or $b[$p] -gt 0x7E) { [void]$sb.Append('.') }
        else { [void]$sb.Append([char]$b[$p]) }
    }
    return $sb.ToString().TrimEnd()
}
function IsViewFrame($f, [string]$name, [string]$mode = "View") {
    return ($f[0] -match ('^ ' + [regex]::Escape($name) + '\s+\[ ' + $mode + ' \]'))
}
function FirstFrame($run, [int]$from, [scriptblock]$pred) {
    for ($i = $from; $i -lt $run.Frames.Count; $i++) { if (& $pred $run.Frames[$i]) { return $i } }
    return -1
}
# compare pager rows 1..23 of frame $f with the expected strings (missing = blank)
function CheckRows($f, [string[]]$want, [string]$what, $fails) {
    for ($r = 1; $r -le 23; $r++) {
        $exp = if (($r - 1) -lt $want.Count) { $want[$r - 1].TrimEnd() } else { "" }
        $got = $f[$r].TrimEnd()
        if ($got -cne $exp) { $fails.Add("$what row ${r}: got '$(Vis $got)' want '$(Vis $exp)'"); return }
    }
}

# 11. F3 on a 12 KB text file: the pager holds the first VIEW_MAX (8192) bytes
#     in viewbuf; End must land on the line holding byte 8191, cut exactly
#     there, and nothing past 8 KB may show. H (hex) must show the exact bytes
#     at offset 0 and, after End, at 0x1FF0 (the last 16 bytes of the buffer).
if (Want "xseg_view_big") {
    $c = New-Case "xseg_view_big"
    $alpha = "abcdefghijklmnopqrstuvwxyz0123456789-+=#"
    for ($shift = 0; $shift -lt 200; $shift++) {
        $sb = [Text.StringBuilder]::new(); $i = 0
        while ($sb.Length -lt 12288) {
            $i++
            $n = 4 + (($i * 37) % 61) + $(if ($i -eq 1) { $shift % 60 } else { 0 })
            $fill = -join (0..($n - 1) | ForEach-Object { $alpha[($i + $_) % $alpha.Length] })
            [void]$sb.Append(("L{0:D4} {1}`r`n" -f $i, $fill))
        }
        $big = [Text.Encoding]::ASCII.GetBytes($sb.ToString())
        $ls = PagerLines $big 8192
        $last = $ls[$ls.Count - 1]
        # want byte 8191 mid-text, >= 8 chars of the cut line visible, and
        # the real line continuing past the 8 KB cap
        if ($big[8191] -ne 0x0D -and $big[8191] -ne 0x0A -and $big[8192] -ne 0x0D -and $big[8192] -ne 0x0A -and (8192 - $last) -ge 8) { break }
    }
    Put-File $c "C:\BIG.TXT" $big
    $vlen = 8192
    $lastRow = PagerRow $big $last $vlen
    $lastNo = [int]$lastRow.Substring(1, 4)
    QS "BIG"; F3                 # v0: top of file
    EndK                         # v1: last line (cut at 8192)
    Txt "h"                      # h0: hex, offset 0
    EndK                         # h1: hex, offset 0x1FF0
    Esc
    $run = Run-CC $c "C:\"
    $f = NewFails; ExitCheck $run $f
    $v0 = FirstFrame $run 0 { param($fr) IsViewFrame $fr "BIG.TXT" }
    if ($v0 -lt 0 -or $v0 + 3 -ge $run.Frames.Count) { $f.Add("viewer frames missing (v0=$v0 of $($run.Frames.Count))") }
    else {
        $want0 = @(0..22 | ForEach-Object { PagerRow $big $ls[$_] $vlen })
        CheckRows $run.Frames[$v0] $want0 "top page" $f
        $fr1 = $run.Frames[$v0 + 1]
        if (-not (IsViewFrame $fr1 "BIG.TXT")) { $f.Add("frame after End is not the text viewer") }
        else { CheckRows $fr1 @($lastRow) "End page" $f }
        $fr2 = $run.Frames[$v0 + 2]
        if (-not (IsViewFrame $fr2 "BIG.TXT" "Hex")) { $f.Add("H did not switch to hex") }
        else { CheckRows $fr2 @(0..22 | ForEach-Object { HexRow $big ($_ * 16) $vlen }) "hex top" $f }
        $fr3 = $run.Frames[$v0 + 3]
        if (-not (IsViewFrame $fr3 "BIG.TXT" "Hex")) { $f.Add("frame after hex End is not the hex viewer") }
        else { CheckRows $fr3 @(HexRow $big 0x1FF0 $vlen) "hex End" $f }
        foreach ($fr in $run.Frames) {
            if (-not (IsViewFrame $fr "BIG.TXT")) { continue }
            foreach ($m in [regex]::Matches((($fr[1..23]) -join "`n"), 'L(\d{4}) ')) {
                if ([int]$m.Groups[1].Value -gt $lastNo) { $f.Add("text past the 8 KB cap shown (L$($m.Groups[1].Value))"); break }
            }
        }
    }
    Report $c $run $f ("{0} lines in 8 KB, End -> L{1:D4} cut at byte 8191; hex rows 0/1FF0 exact" -f $ls.Count, $lastNo)
}

# 12. F3 on a 1500-line file (7 B/line, 10.5 KB): the pager's line table is
#     capped at MAX_VLINES = 1024, so End must show L1024 (and never L1025+);
#     Home/PgDn walk the table; hex End still shows the raw bytes at 0x1FF0.
if (Want "xseg_view_lines") {
    $c = New-Case "xseg_view_lines"
    $txt = -join (1..1500 | ForEach-Object { "L{0:D4}`r`n" -f $_ })
    $b = [Text.Encoding]::ASCII.GetBytes($txt)
    Put-File $c "C:\LINES.TXT" $b
    QS "LINES"; F3               # v0: L0001..
    EndK                         # v1: L1024 only
    Home                         # v2: L0001..
    PgDn                         # v3: L0024..
    Txt "h"                      # h0: hex offset 0
    EndK                         # h1: hex 0x1FF0
    Esc
    $run = Run-CC $c "C:\"
    $f = NewFails; ExitCheck $run $f
    $v0 = FirstFrame $run 0 { param($fr) IsViewFrame $fr "LINES.TXT" }
    if ($v0 -lt 0 -or $v0 + 5 -ge $run.Frames.Count) { $f.Add("viewer frames missing (v0=$v0 of $($run.Frames.Count))") }
    else {
        $frs = $run.Frames
        CheckRows $frs[$v0]     @(1..23  | ForEach-Object { "L{0:D4}" -f $_ }) "top page" $f
        CheckRows $frs[$v0 + 1] @("L1024") "End page" $f
        CheckRows $frs[$v0 + 2] @(1..23  | ForEach-Object { "L{0:D4}" -f $_ }) "Home page" $f
        CheckRows $frs[$v0 + 3] @(24..46 | ForEach-Object { "L{0:D4}" -f $_ }) "PgDn page" $f
        if (-not (IsViewFrame $frs[$v0 + 4] "LINES.TXT" "Hex")) { $f.Add("H did not switch to hex") }
        else { CheckRows $frs[$v0 + 4] @(0..22 | ForEach-Object { HexRow $b ($_ * 16) 8192 }) "hex top" $f }
        CheckRows $frs[$v0 + 5] @(HexRow $b 0x1FF0 8192) "hex End" $f
        foreach ($fr in $frs) {
            if ((IsViewFrame $fr "LINES.TXT") -and ((($fr[1..23]) -join "`n") -match 'L(102[5-9]|10[3-9]\d|1[1-9]\d\d)')) {
                $f.Add("line past the MAX_VLINES cap shown ($($Matches[0]))"); break
            }
        }
    }
    Report $c $run $f "End -> L1024 (cap), Home/PgDn/hex exact"
}

# --- results-heap helpers ---------------------------------------------------
# a tree whose full paths are 58 chars (59 heap bytes each): 60 files over 3
# leaf dirs, so ~51 rows fill res_heap (RESHEAP_MAX 3072, heap_putc stops at
# 3068) and the rest is cut to a "...(more)" row. Each file has exactly one
# NEEDLE line (grep dedup never re-stores a path) at line 3 + (k mod 7), so a
# viewer jump is never confused with "top of file".
$xsegGrepDirs = @("LEAF0001", "LEAF0002", "LEAF0003") | ForEach-Object { "C:\GR\LONGDIR1\LONGDIR2\LONGDIR3\LONGDIR4\$_" }
function New-HeapTree($case) {
    for ($k = 1; $k -le 60; $k++) {
        $dir = $xsegGrepDirs[($k - 1) % 3]
        $hit = 3 + ($k % 7)
        $lines = for ($l = 1; $l -le 12; $l++) {
            if ($l -eq $hit) { "G{0:D2} NEEDLE here on line {1}" -f $k, $l } else { "G{0:D2} filler line {1}" -f $k, $l }
        }
        Put-File $case ("$dir\G{0:D2}.TXT" -f $k) (($lines -join "`r`n") + "`r`n")
    }
}
# simulate results_load's packing of a CCFIND/CCGREP output file: returns the
# rows (@{Name; Path; Line}) that fit, plus whether a "...(more)" row follows
function Expect-Results([string]$outText, [bool]$grep) {
    $rows = [System.Collections.Generic.List[object]]::new()
    $used = 0; $more = $false; $lastPath = $null
    $bytes = [Text.Encoding]::GetEncoding(28591).GetBytes($outText)
    if ($bytes.Length -gt 8192) { $outText = [Text.Encoding]::GetEncoding(28591).GetString($bytes, 0, 8192) }
    foreach ($ln in ($outText -split "\r?\n")) {
        if ($ln -eq "") { continue }
        $path = $ln; $lineNo = 0
        if ($grep) {
            $m = [regex]::Match($ln, '^([^:]*:[^:]*):(\d*)')
            if (-not $m.Success) { continue }
            $path = $m.Groups[1].Value; $lineNo = [int]("0" + $m.Groups[2].Value)
            if ($path -eq $lastPath) { continue }
        }
        if ($used + $path.Length -gt 3068) { $more = $true; break }
        $used += $path.Length + 1
        $lastPath = $path
        $name = Split-Path $path -Leaf
        if ($name.Length -gt 12) { $name = $name.Substring(0, 12) }
        $rows.Add(@{ Name = $name; Path = $path; Line = $lineNo })
        if ($rows.Count -ge 511) { $more = $true; break }
    }
    return @{ Rows = $rows; More = $more; Used = $used }
}
# right-panel file rows of a frame: "NAME ... <size>" cells (trimmed)
function RightCells($f) {
    @($f[2..21] | ForEach-Object { $_.Substring(40, 39).Trim([char]0xB3, ' ') } | Where-Object { $_ -ne "" })
}
# which file rows of the expected list were seen, in any frame
function SeenNames($run, [int]$from) {
    $seen = @{}
    for ($i = $from; $i -lt $run.Frames.Count; $i++) {
        foreach ($cell in (RightCells $run.Frames[$i])) { if ($cell -match '^(G\d\d\.TXT)\s+(.*)$') { $seen[$Matches[1]] = $Matches[2].Trim() } }
    }
    return $seen
}

# 13. Alt-F8 grep over 60 files with 58-char paths -> res_heap fills and the
#     list is cut with "...(more)". Every listed row must carry the right name
#     and first-match line; the LAST file row (its path sits at the very end
#     of the heap) must open the viewer on that file at the matched line.
if (Want "xseg_grep_heap") {
    $c = New-Case "xseg_grep_heap"
    New-HeapTree $c
    QS "GR"; Enter                          # left -> C:\GR
    AltF8; Txt "NEEDLE"; Enter              # results -> right panel, focused
    PgDn; PgDn; PgDn                        # page through the list
    EndK; Up                                # last row = "...(more)", Up = last file row
    Enter                                   # grep row -> viewer at the line
    Esc
    $run = Run-CC $c "C:\" 30000
    $f = NewFails; ExitCheck $run $f
    $out = ReadText $c "C:\GREPOUT.TXT"
    if ($null -eq $out) { $f.Add("C:\GREPOUT.TXT missing (grep never ran)") }
    else {
        $exp = Expect-Results $out $true
        $rows = $exp.Rows
        if ($rows.Count -lt 40 -or -not $exp.More) { $f.Add("test setup: expected the heap to overflow ($($rows.Count) rows, more=$($exp.More), $($exp.Used) B)") }
        $seen = SeenNames $run 0
        $bad = @()
        foreach ($r in $rows) {
            if (-not $seen.ContainsKey($r.Name)) { $bad += "$($r.Name) missing" }
            elseif ($seen[$r.Name] -notmatch ('^' + $r.Line + ' B$')) { $bad += "$($r.Name) size col '$($seen[$r.Name])' (want $($r.Line) B)" }
        }
        $extra = @($seen.Keys | Where-Object { $n = $_; -not ($rows | Where-Object { $_.Name -eq $n }) })
        if ($extra.Count) { $bad += "unexpected rows: $($extra -join ',')" }
        if ($bad.Count) { $f.Add("results rows wrong: " + (($bad | Select-Object -First 4) -join "; ")) }
        if (-not ($run.Frames | Where-Object { @(RightCells $_) -match '^\.\.\.\(more\)' })) { $f.Add("no '...(more)' row shown") }
        # garbage check: any right-panel cell in a results frame must be '..',
        # a G-file row or the status row (which renders with the <UP> tag)
        $junk = $null
        foreach ($fr in $run.Frames) {
            $cells = RightCells $fr
            if (-not ($cells | Where-Object { $_ -match '^G\d\d\.TXT' })) { continue }
            foreach ($cell in $cells) { if ($cell -notmatch '^(\.\.\s+<UP>|G\d\d\.TXT\s+\d+ B|\.\.\.\(more\)\s+<UP>)$') { $junk = $cell; break } }
            if ($junk) { break }
        }
        if ($junk) { $f.Add("garbage row in the results panel: '$(Vis $junk)'") }
        $lr = $rows[$rows.Count - 1]
        $vi = FirstFrame $run 0 { param($fr) IsViewFrame $fr $lr.Name }
        if ($vi -lt 0) { $f.Add("Enter on the last row ($($lr.Name)) never opened the viewer") }
        else {
            $want = "{0} NEEDLE here on line {1}" -f $lr.Name.Substring(0, 3), $lr.Line
            $want2 = "{0} filler line {1}" -f $lr.Name.Substring(0, 3), ($lr.Line + 1)
            $got = $run.Frames[$vi][1].TrimEnd(); $got2 = $run.Frames[$vi][2].TrimEnd()
            if ($got -cne $want -or $got2 -cne $want2) { $f.Add("viewer rows '$(Vis $got)' / '$(Vis $got2)' want '$want' / '$want2'") }
        }
    }
    $okMsg = if ($out) { "{0} rows ({1} heap B) + more; last row {2} -> viewer at line {3}" -f $rows.Count, $exp.Used, $lr.Name, $lr.Line } else { "" }
    Report $c $run $f $okMsg
}

# 14. Alt-F7 find over the same tree: the rows' paths fill res_heap the same
#     way. F3 on the LAST file row views that file (path from the heap end);
#     Enter jumps the panel into its folder (P_PATH copied from the heap) with
#     the cursor on it, and F3 there must view the same file again.
if (Want "xseg_find_heap") {
    $c = New-Case "xseg_find_heap"
    New-HeapTree $c
    QS "GR"; Enter
    AltF7; Txt "G*.TXT"; Enter
    PgDn; PgDn; PgDn                        # page through the list
    EndK; Up
    F3; Esc                                 # view from the results row
    Enter                                   # find jump -> real folder
    F3; Esc                                 # view from the real folder
    $run = Run-CC $c "C:\" 30000
    $f = NewFails; ExitCheck $run $f
    $out = ReadText $c "C:\FINDOUT.TXT"
    if ($null -eq $out) { $f.Add("C:\FINDOUT.TXT missing (find never ran)") }
    else {
        $exp = Expect-Results $out $false
        $rows = $exp.Rows
        if ($rows.Count -lt 40 -or -not $exp.More) { $f.Add("test setup: expected the heap to overflow ($($rows.Count) rows, more=$($exp.More))") }
        $seen = SeenNames $run 0
        $miss = @($rows | Where-Object { -not $seen.ContainsKey($_.Name) } | ForEach-Object { $_.Name })
        # the last page must list the tail of the expected rows in order
        $lr = $rows[$rows.Count - 1]
        $vs = @()
        for ($i = 0; $i -lt $run.Frames.Count; $i++) { if (IsViewFrame $run.Frames[$i] $lr.Name) { $vs += $i } }
        if ($vs.Count -lt 2) { $f.Add("viewer on the last row ($($lr.Name)) opened $($vs.Count)x, want 2 (results F3 + after the jump)") }
        $want = "{0} filler line 1" -f $lr.Name.Substring(0, 3)   # find rows open at the top
        foreach ($i in $vs) { $got = $run.Frames[$i][1].TrimEnd(); if ($got -cne $want) { $f.Add("viewer frame $i top line '$(Vis $got)' want '$want'"); break } }
        # after the jump the right panel is the real leaf folder (title)
        $leaf = Split-Path (Split-Path $lr.Path -Parent) -Leaf
        if (-not ($run.Frames | Where-Object { $_[1].Substring(40) -match $leaf })) { $f.Add("panel never titled with the jump folder $leaf") }
        $tail = @($rows | Select-Object -Last 5 | ForEach-Object { $_.Name })
        $tailOk = $false
        foreach ($fr in $run.Frames) {
            $names = @(RightCells $fr | ForEach-Object { ($_ -split '\s+')[0] })
            $k = [array]::IndexOf($names, "...(more)")
            if ($k -ge 5 -and (($names[($k - 5)..($k - 1)]) -join ',') -eq ($tail -join ',')) { $tailOk = $true; break }
        }
        if (-not $tailOk) { $f.Add("last page does not end with $($tail -join ',') + ...(more)") }
        if ($miss.Count) { $f.Add("rows never shown: $($miss -join ',')") }
    }
    $okMsg = if ($out) { "{0} rows ({1} heap B) + more; F3/jump on {2} exact" -f $rows.Count, $exp.Used, $lr.Name } else { "" }
    Report $c $run $f $okMsg
}

# 15. EXEC a helper that leaves FS/GS = F000h (ROM), then use every out-of-segment
#     path: F3 text, H hex, and an Alt-F8 grep -> results -> viewer jump. cc
#     must reload its FS after the EXEC or all of these render garbage.
if (Want "xseg_exec_fs") {
    $c = New-Case "xseg_exec_fs"
    $f = NewFails
    if (-not (Build-Com $c "FSCLOB" $src_fsclob)) { $f.Add("FSCLOB.COM did not assemble") }
    $tl = @(1..30 | ForEach-Object { "fs text line {0:D2} {1}" -f $_, ("#" * ($_ % 17)) })
    $tb = [Text.Encoding]::ASCII.GetBytes((($tl -join "`r`n") + "`r`n"))
    Put-File $c "C:\FS\TEXT.TXT" $tb
    Put-File $c "C:\FS\SUB\HAY.TXT" "hay 1`r`nhay 2`r`nhay 3`r`nhay 4`r`nhay 5 NEEDLE after exec`r`nhay 6`r`n"
    QS "FS"; Enter                          # left -> C:\FS
    Txt "FSCLOB"; Enter; AnyKey             # EXEC: FS/GS clobbered
    QS "TEXT"; F3                           # built-in pager
    Txt "h"                                 # hex
    Esc
    AltF8; Txt "NEEDLE"; Enter              # grep (another EXEC) -> results
    Enter                                   # row -> viewer at line 5
    Esc
    $run = Run-CC $c "C:\" 20000
    ExitCheck $run $f
    if (-not (Exists $c "C:\FSRAN.TXT")) { $f.Add("FSCLOB never ran (C:\FSRAN.TXT missing)") }
    $v = FirstFrame $run 0 { param($fr) IsViewFrame $fr "TEXT.TXT" }
    if ($v -lt 0) { $f.Add("F3 viewer on TEXT.TXT never shown") }
    else {
        CheckRows $run.Frames[$v] @(0..22 | ForEach-Object { $tl[$_] }) "text after EXEC" $f
        if ($v + 1 -ge $run.Frames.Count -or -not (IsViewFrame $run.Frames[$v + 1] "TEXT.TXT" "Hex")) { $f.Add("H did not switch to hex") }
        else { CheckRows $run.Frames[$v + 1] @(0..22 | ForEach-Object { HexRow $tb ($_ * 16) $tb.Length }) "hex after EXEC" $f }
    }
    if (-not ($run.Frames | Where-Object { (RightCells $_) -match '^HAY\.TXT\s+5 B$' })) { $f.Add("grep results row 'HAY.TXT 5 B' never shown") }
    $h = FirstFrame $run 0 { param($fr) IsViewFrame $fr "HAY.TXT" }
    if ($h -lt 0) { $f.Add("results Enter never opened HAY.TXT") }
    elseif ($run.Frames[$h][1].TrimEnd() -cne "hay 5 NEEDLE after exec" -or $run.Frames[$h][2].TrimEnd() -cne "hay 6") {
        $f.Add("HAY.TXT viewer rows '$(Vis $run.Frames[$h][1].TrimEnd())' / '$(Vis $run.Frames[$h][2].TrimEnd())'")
    }
    Report $c $run $f "text/hex/grep-jump exact after an FS-clobbering EXEC"
}

# 16. a ~7.9 KB cc.ini (read whole into viewbuf) whose [open] / [view] maps
#     sit after ~7.5 KB of comment padding. F3 on a .VHX file must run the
#     [view] helper with the file path; Enter on a .OHX file must run the
#     [open] helper, whose stdout listing (via CCVFS.LST -> viewbuf) must show
#     as the container's members.
if (Want "xseg_ini") {
    $c = New-Case "xseg_ini"
    $f = NewFails
    if (-not (Build-Com $c "VIEWHIT" (Src-TailHit "C:\VIEWHIT.TXT" ""))) { $f.Add("VIEWHIT.COM did not assemble") }
    if (-not (Build-Com $c "OPENHIT" (Src-TailHit "C:\OPENHIT.TXT" "'1234 ALPHAMEM.TXT',13,10,'567 BRAVOMEM.DAT',13,10"))) { $f.Add("OPENHIT.COM did not assemble") }
    $pad = [Text.StringBuilder]::new()
    $n = 0
    while ($pad.Length -lt 7400) { $n++; [void]$pad.Append(("; padding comment {0:D3} -- {1}`r`n" -f $n, ("=" * (10 + ($n * 13) % 40)))) }
    $ini = $pad.ToString() +
        "[tools]`r`nChecksum = CCSUM`r`n" +
        "# more padding between sections -------------------------------------`r`n" +
        "[open]`r`nzip = CCZIP`r`nohx = OPENHIT`r`n" +
        "; ------------------------------------------------------------------`r`n" +
        "[view]`r`nvhx = VIEWHIT`r`n"
    $viewOff = $ini.IndexOf("vhx = VIEWHIT")
    Put-File $c "C:\INI\cc.ini" $ini
    Put-File $c "C:\INI\PICTURE.VHX" "not really a picture"
    Put-File $c "C:\INI\PACK.OHX" "not really an archive"
    QS "PICTURE"; F3; AnyKey                # [view] helper, then "press any key"
    QS "PACK"; Enter                        # [open] helper -> member listing
    $run = Run-CC $c "C:\INI"
    ExitCheck $run $f
    $vh = ReadText $c "C:\VIEWHIT.TXT"
    if ($null -eq $vh) { $f.Add("[view] helper never ran (C:\VIEWHIT.TXT missing)") }
    elseif ($vh.Trim() -ne "C:\INI\PICTURE.VHX") { $f.Add("[view] helper tail '$(Vis $vh)'") }
    $oh = ReadText $c "C:\OPENHIT.TXT"
    if ($null -eq $oh) { $f.Add("[open] helper never ran (C:\OPENHIT.TXT missing)") }
    elseif ($oh.Trim() -notmatch '^L C:\\INI\\PACK\.OHX\b') { $f.Add("[open] helper tail '$(Vis $oh)'") }
    $lst = $false
    foreach ($fr in $run.Frames) { $l = LeftList $fr; if ($l -match 'ALPHAMEM\.TXT' -and $l -match 'BRAVOMEM\.DAT') { $lst = $true; break } }
    if (-not $lst) { $f.Add("archive panel never listed ALPHAMEM.TXT + BRAVOMEM.DAT") }
    Report $c $run $f ("cc.ini {0} B, [view] map at byte {1}: both helpers ran, listing shown" -f $ini.Length, $viewOff)
}

# 17. walk the DOS MCB chain from a typed command, before and after another
#     EXEC (FSCLOB). The chain must be intact (M... Z, no bad signature) and
#     the blocks owned by cc's PSP (cc = the grandparent: cc -> COMMAND /C ->
#     MCBWALK) must be the same after the EXEC. Prints the cc-owned blocks.
function Read-McbWalk([string]$text) {
    $r = @{ Psp = $null; Parents = @(); Blocks = @(); Bad = $false; End = $false }
    foreach ($ln in ($text -split "\r?\n")) {
        if ($ln -match '^PSP ([0-9A-F]{4})$') { $r.Psp = [Convert]::ToInt32($Matches[1], 16) }
        elseif ($ln -match '^PARENT\d ([0-9A-F]{4})$') { $r.Parents += [Convert]::ToInt32($Matches[1], 16) }
        elseif ($ln -match '^MCB ([0-9A-F]{4}) ([MZ]) ([0-9A-F]{4}) ([0-9A-F]{4}) ?(.*)$') {
            $r.Blocks += [pscustomobject]@{ Seg = [Convert]::ToInt32($Matches[1], 16); Sig = $Matches[2]
                Owner = [Convert]::ToInt32($Matches[3], 16); Size = [Convert]::ToInt32($Matches[4], 16); Name = $Matches[5]; Line = $ln }
        }
        elseif ($ln -match '^BAD ') { $r.Bad = $true }
        elseif ($ln -match '^END ') { $r.End = $true }
    }
    return $r
}
if (Want "xseg_mcb") {
    $c = New-Case "xseg_mcb"
    $f = NewFails
    if (-not (Build-Com $c "FSCLOB" $src_fsclob)) { $f.Add("FSCLOB.COM did not assemble") }
    if (-not (Build-Com $c "MCBWALK" $src_mcbwalk)) { $f.Add("MCBWALK.COM did not assemble") }
    Txt "MCBWALK C:\MCB1.TXT"; Enter; AnyKey
    Txt "FSCLOB"; Enter; AnyKey
    Txt "MCBWALK C:\MCB2.TXT"; Enter; AnyKey
    $run = Run-CC $c "C:\" 20000
    ExitCheck $run $f
    $sum = @()
    foreach ($tag in @("MCB1", "MCB2")) {
        $t = ReadText $c "C:\$tag.TXT"
        if ($null -eq $t) { $f.Add("C:\$tag.TXT missing (MCBWALK did not run)"); continue }
        $w = Read-McbWalk $t
        if ($w.Bad) { $f.Add("${tag}: MCB chain has a bad signature") }
        if (-not $w.End -or $w.Blocks.Count -eq 0) { $f.Add("${tag}: walk incomplete") ; continue }
        if ($w.Blocks[$w.Blocks.Count - 1].Sig -ne 'Z') { $f.Add("${tag}: chain does not end with Z") }
        for ($i = 1; $i -lt $w.Blocks.Count; $i++) {
            $p = $w.Blocks[$i - 1]
            if ($w.Blocks[$i].Seg -ne $p.Seg + $p.Size + 1) { $f.Add("${tag}: block $i not contiguous"); break }
            if ($p.Sig -ne 'M') { $f.Add("${tag}: 'Z' before the end"); break }
        }
        # cc's PSP: the first ancestor whose arena name is "CC"
        $ccPsp = $null
        foreach ($pp in $w.Parents) {
            $blk = $w.Blocks | Where-Object { $_.Seg -eq $pp - 1 }
            if ($blk -and $blk.Owner -eq $pp -and $blk.Name -match '^CC$') { $ccPsp = $pp; break }
        }
        if ($null -eq $ccPsp) { $f.Add("${tag}: cc's PSP not found in the parent chain ($(($w.Parents | ForEach-Object { '{0:X4}' -f $_ }) -join ','))"); continue }
        $own = @($w.Blocks | Where-Object { $_.Owner -eq $ccPsp })
        $paras = 0; foreach ($o in $own) { $paras += $o.Size + 1 }
        $sum += [pscustomobject]@{ Tag = $tag; Psp = $ccPsp; N = $own.Count; Paras = $paras; Lines = @($own | ForEach-Object { $_.Line }); Total = $w.Blocks.Count
            Parents = (($w.Parents | ForEach-Object { '{0:X4}' -f $_ }) -join '>') }
    }
    if ($sum.Count -eq 2) {
        if ($sum[0].N -ne $sum[1].N -or $sum[0].Paras -ne $sum[1].Paras) {
            $f.Add("cc-owned memory changed across an EXEC: $($sum[0].N) blocks/$($sum[0].Paras) paras -> $($sum[1].N)/$($sum[1].Paras)")
        }
    }
    foreach ($s in $sum) {
        Write-Host ("      {0}: cc PSP {1:X4} (parents {2}), {3} arena blocks total; cc owns {4} blocks, {5} paras ({6} B):" -f $s.Tag, $s.Psp, $s.Parents, $s.Total, $s.N, $s.Paras, ($s.Paras * 16))
        foreach ($l in $s.Lines) { Write-Host "        $l" }
    }
    $okMsg = if ($sum.Count -eq 2) { "cc PSP {0:X4}: {1} blocks/{2} paras at start, {3}/{4} after EXEC; chain intact" -f $sum[0].Psp, $sum[0].N, $sum[0].Paras, $sum[1].N, $sum[1].Paras } else { "" }
    Report $c $run $f $okMsg
}

# 18. Alt-F10 tree browser: its nodes {name, depth} live in the viewbuf/xseg
#     scratch and Enter rebuilds the path from them. Tree from C:\T (left
#     panel): rows must list every dir, indented, in preorder; Down x2 + Enter
#     -> C:\T\AA\BB\CC. Tree from C:\ (right panel, 29 nodes, scrolls): End +
#     Enter -> the last node, C:\T\ZZ\YY\XX. Each target holds a marker file.
function AltF10 { Ext 0x71 }
function TreeNodes([string]$hostRoot, [int]$depth = 0) {
    # ordinal order (= NTFS / DOSBox FindFirst order); culture sorting would
    # e.g. put "AA" last under da-DK
    $names = [string[]]@(Get-ChildItem -LiteralPath $hostRoot -Directory | ForEach-Object { $_.Name.ToUpper() })
    [Array]::Sort($names, [StringComparer]::Ordinal)
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($nm in $names) {
        $out.Add(@($nm, $depth))
        foreach ($x in (TreeNodes (Join-Path $hostRoot $nm) ($depth + 1))) { $out.Add($x) }
    }
    return , $out.ToArray()
}
function TreeRows($nodes, [int]$top) {
    $rows = @()
    for ($i = $top; $i -lt [Math]::Min($nodes.Count, $top + 23); $i++) { $rows += (" " + (" " * (2 * $nodes[$i][1])) + $nodes[$i][0]) }
    return , $rows
}
if (Want "xseg_tree") {
    $c = New-Case "xseg_tree"
    Put-File $c "C:\T\AA\BB\CC\DEEP.TXT" "deep"
    Put-Dir  $c "C:\T\AA\ZZ"
    foreach ($i in 1..20) { Put-Dir $c ("C:\T\QQ\S{0:D2}" -f $i) }
    Put-File $c "C:\T\ZZ\YY\XX\LAST.TXT" "last"
    $nT = TreeNodes (HostDir $c "C:\T")
    $nC = TreeNodes (HostDir $c "C:\")
    QS "T"; Enter                           # left -> C:\T
    AltF10                                  # t0: tree of C:\T
    Down; Down; Enter                       # -> C:\T\AA\BB\CC
    Tab                                     # right panel (C:\) active
    AltF10                                  # t1: tree of C:\
    EndK                                    # t2: last node, scrolled
    Enter                                   # -> C:\T\ZZ\YY\XX
    $run = Run-CC $c "C:\"
    $f = NewFails; ExitCheck $run $f
    $t0 = FirstFrame $run 0 { param($fr) $fr[0] -match '^ Tree: C:\\T\s*$' }
    if ($t0 -lt 0) { $f.Add("tree of C:\T never shown") }
    else { CheckRows $run.Frames[$t0] (TreeRows $nT 0) "tree C:\T" $f }
    $l = FirstFrame $run 0 { param($fr) $fr[1].Substring(0, 40) -match ' C:\\T\\AA\\BB\\CC ' -and (LeftList $fr) -match 'DEEP\.TXT' }
    if ($l -lt 0) { $f.Add("left panel never reached C:\T\AA\BB\CC (with DEEP.TXT)") }
    $t1 = FirstFrame $run ([Math]::Max(0, $t0 + 1)) { param($fr) $fr[0] -match '^ Tree: C:\\\s*$' }
    if ($t1 -lt 0 -or $t1 + 1 -ge $run.Frames.Count) { $f.Add("tree of C:\ never shown") }
    else {
        CheckRows $run.Frames[$t1] (TreeRows $nC 0) "tree C:\ top" $f
        CheckRows $run.Frames[$t1 + 1] (TreeRows $nC ([Math]::Max(0, $nC.Count - 23))) "tree C:\ End" $f
    }
    $lf = LastFrame $run
    if ($lf -and -not ($lf[1].Substring(40) -match ' C:\\T\\ZZ\\YY\\XX ' -and (RightList $lf) -match 'LAST\.TXT')) {
        $f.Add("right panel did not end in C:\T\ZZ\YY\XX (title '$(Vis $lf[1].Substring(40).Trim())')")
    }
    Report $c $run $f ("{0}/{1}-node trees exact; Enter -> CC and -> XX" -f $nT.Count, $nC.Count)
}

# 19. a zip with members in sub-folders: the member listing is parsed from
#     CCVFS.LST in viewbuf and each level is filtered by P_CPATH. Root must
#     show dir A + X.TXT; Enter on A -> dir B + Y.TXT; Enter on B -> C.TXT.
if (Want "xseg_zipdirs") {
    $c = New-Case "xseg_zipdirs"
    Put-File $c "C:\WORK\cc.ini" "[open]`r`nzip = CCZIP`r`n"
    $zipHost = HostDir $c "C:\WORK\Z.ZIP"
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $fs = [IO.File]::Open($zipHost, [IO.FileMode]::Create)
    $za = [IO.Compression.ZipArchive]::new($fs, [IO.Compression.ZipArchiveMode]::Create)
    foreach ($m in @(@("a/b/c.txt", "deepest member"), @("a/y.txt", "middle member"), @("x.txt", "root member"))) {
        $en = $za.CreateEntry($m[0])
        $w = [IO.StreamWriter]::new($en.Open()); $w.Write($m[1]); $w.Dispose()
    }
    $za.Dispose(); $fs.Dispose()
    QS "Z."; Enter                          # open Z.ZIP as a folder
    Down; Enter                             # ".." -> A, enter it
    Down; Enter                             # ".." -> B, enter it
    $run = Run-CC $c "C:\WORK"
    $f = NewFails; ExitCheck $run $f
    function ZipLevel($run, [string[]]$want) {
        foreach ($fr in $run.Frames) {
            if ($fr[1] -notmatch 'Z\.ZIP') { continue }
            $names = @($fr[2..21] | ForEach-Object { $_.Substring(1, 38).Trim([char]0xB3, ' ') } | Where-Object { $_ -ne "" } | ForEach-Object { ($_ -split '\s+')[0].ToUpper() })
            if (($names -join ',') -eq ($want -join ',')) { return $true }
        }
        return $false
    }
    if (-not (ZipLevel $run @("..", "A", "X.TXT"))) { $f.Add("zip root never listed exactly '..,A,X.TXT'") }
    if (-not (ZipLevel $run @("..", "B", "Y.TXT"))) { $f.Add("zip A/ never listed exactly '..,B,Y.TXT'") }
    if (-not (ZipLevel $run @("..", "C.TXT"))) { $f.Add("zip A/B/ never listed exactly '..,C.TXT'") }
    Report $c $run $f "root -> A -> B levels listed exactly"
}

# 20. xseg is a MANDATORY DOS allocation at startup: with too little memory cc
#     must print "Not enough memory." and exit with errorlevel 8 before touching
#     the video mode / dump file, leaving the MCB chain intact. EATMEM leaves
#     only KEEPFREE paragraphs free, then EXECs "E:\CC.COM /D" and records the
#     errorlevel. 3800 paras (~59 KB) fits cc's image + back buffer but not
#     xseg; 5000 paras is the positive control (/D renders and dumps one frame).
$src_eatmem = @'
        org     100h
        mov     sp, 0FFEh
        mov     bx, 100h                ; keep 4 KB for ourselves
        mov     ah, 4Ah
        int     21h
        mov     bx, 0FFFFh              ; -> bx = largest free block
        mov     ah, 48h
        int     21h
        sub     bx, KEEPFREE
        jbe     .run
        mov     ah, 48h                 ; hold all but KEEPFREE paragraphs
        int     21h
.run:   mov     [epb+4], cs
        mov     [epb+8], cs
        mov     [epb+12], cs
        mov     dx, prog
        mov     bx, epb
        mov     ax, 4B00h
        int     21h
        mov     ax, cs
        mov     ds, ax
        mov     es, ax
        mov     ss, ax
        mov     sp, 0FFEh
        mov     byte [rc], 'E'          ; EXEC itself failed
        jc      .wr
        mov     ah, 4Dh
        int     21h                     ; al = child's errorlevel
        xor     ah, ah
        mov     cl, 100
        div     cl
        add     al, '0'
        mov     [rc], al
        mov     al, ah
        xor     ah, ah
        mov     cl, 10
        div     cl
        add     ax, '00'
        mov     [rc+1], ax
.wr:    mov     ah, 3Ch
        xor     cx, cx
        mov     dx, outname
        int     21h
        jc      .x
        mov     bx, ax
        mov     ah, 40h
        mov     cx, msglen
        mov     dx, msg
        int     21h
        mov     ah, 3Eh
        int     21h
.x:     mov     ax, 4C00h
        int     21h
prog    db 'E:\CC.COM', 0
tail    db 3, ' /D', 0Dh
outname db 'E:\RC.TXT', 0
msg     db 'RC='
rc      db '???', 0Dh, 0Ah
msglen  equ $-msg
epb     dw 0, tail, 0, 5Ch, 0, 6Ch, 0
'@
if (Want "xseg_nomem") {
    $f = NewFails
    $okParts = @()
    foreach ($lv in @(@{ N = 3800; Want = "RC=008"; Dump = $false }, @{ N = 5000; Want = "RC=000"; Dump = $true })) {
        $c = New-Case ("xseg_nomem_{0}" -f $lv.N)
        $eatSrc = "KEEPFREE equ    $($lv.N)`r`n" + $src_eatmem
        if (-not (Build-Com $c "EATMEM" $eatSrc)) { $f.Add("EATMEM.COM did not assemble"); continue }
        $conf = @"
[sdl]
fullscreen = false
[dosbox]
startup_verbosity = quiet
[cpu]
core    = normal
cputype = 486
cycles  = max
[mixer]
nosound = true
[autoexec]
@echo off
mount c $($c.C)
mount e $($c.E)
c:
E:\EATMEM.COM > E:\OUT.TXT
mem > E:\MEM.TXT
exit
"@
        $confPath = Join-Path $c.Root "run.conf"
        Set-Content -Path $confPath -Value $conf -Encoding ASCII
        $p = Start-Process -FilePath $dbox -ArgumentList @("-conf", $confPath, "-noprimaryconf", "-exit") -PassThru -WindowStyle Minimized
        if (-not $p.WaitForExit(15000)) { try { $p.Kill() } catch {}; $f.Add("LEAVE=$($lv.N): DOSBox timed out") }
        Start-Sleep -Milliseconds 300
        $rc  = ReadText $c "E:\RC.TXT";  $rc  = if ($rc)  { $rc.Trim() }  else { "<none>" }
        $out = ReadText $c "E:\OUT.TXT"; $out = if ($out) { $out.Trim() } else { "" }
        $mem = ReadText $c "E:\MEM.TXT"
        $m = if ($mem) { [regex]::Match($mem, '(\d+)\s*KB free conventional') } else { $null }
        $dump = Exists $c "C:\CCDUMP.TXT"
        if ($rc -ne $lv.Want) { $f.Add("LEAVE=$($lv.N): got '$rc' want '$($lv.Want)'") }
        if ($dump -ne $lv.Dump) { $f.Add("LEAVE=$($lv.N): CCDUMP.TXT present=$dump, want $($lv.Dump)") }
        if (-not $lv.Dump -and $out -notmatch 'Not enough memory') { $f.Add("LEAVE=$($lv.N): no 'Not enough memory' message (stdout '$(Vis $out)')") }
        if (-not $m -or -not $m.Success -or [int]$m.Groups[1].Value -lt 500) { $f.Add("LEAVE=$($lv.N): memory chain damaged afterwards") }
        $okParts += "$($lv.N) paras -> $rc"
    }
    Report @{ Name = "xseg_nomem" } $null $f ("clean refusal; " + ($okParts -join ", ") + "; chain intact")
}

# ---------------------------------------------------------------------------
$pass = @($results | Where-Object { $_.Ok }).Count
$fail = @($results | Where-Object { -not $_.Ok }).Count
Write-Host ""
Write-Host ("SAFETY: {0} passed, {1} failed, {2} total" -f $pass, $fail, $results.Count)
if ($fail -gt 0) { exit 1 } else { exit 0 }
