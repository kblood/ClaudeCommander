# run_parsers_safety.ps1 -- robustness tests for the Layer-3 parsers/extractors:
#   CCRAR / CCARJ / CCD64 / CCT64 (listing + extract), CCIMG / CCWAV (/D dump),
#   CCFIND / CCGREP / CCSUM / CCDIFF.
# Builds every helper into $env:TEMP\cc_parsers_safety (never the repo root),
# generates valid and deliberately malformed fixtures there with
# [IO.File]::WriteAllBytes, and runs them under DOSBox-staging. Every malformed
# input must TERMINATE (DOSBox exits by itself; a kill = hang = FAIL) with a
# nonzero exit code or an error message; valid inputs must still list/extract/
# decode byte-exact.
#   pwsh -File run_parsers_safety.ps1        -> exit 0 PASS / 1 FAIL
$ErrorActionPreference = "Stop"
$stage = Join-Path $env:TEMP "cc_parsers_safety"
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
$dir  = "C:\LLM\DOS\cc"
$dbox = "$dir\dbstaging\dosbox-staging-v0.82.2\dosbox.exe"
$nasm = "C:\Users\Caldor\AppData\Local\bin\NASM\nasm.exe"
if (-not (Test-Path $nasm)) { $nasm = "nasm" }
New-Item -ItemType Directory -Force -Path $stage | Out-Null
$script:fails = 0

function LE16([int]$v){ [byte]($v -band 0xFF), [byte](($v -shr 8) -band 0xFF) }
function LE32([long]$v){ [byte]($v -band 0xFF), [byte](($v -shr 8) -band 0xFF), [byte](($v -shr 16) -band 0xFF), [byte](($v -shr 24) -band 0xFF) }
function A4([string]$s){ [System.Text.Encoding]::ASCII.GetBytes($s) }

# assemble <src>.asm -> $stage\<COM>.COM ; returns size or throws
function Build-One([string]$src, [string]$com) {
    $o = "$stage\$com.COM"
    if (Test-Path $o) { Remove-Item $o -Force }
    & $nasm -f bin -i "$dir/" "$dir\$src.asm" -o $o 2>&1 | ForEach-Object { Write-Host "  nasm: $_" }
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $o)) { throw "ASSEMBLE FAILED: $src.asm" }
    return (Get-Item $o).Length
}

function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { Write-Host ("  PASS  {0}" -f $name) }
    else     { Write-Host ("  FAIL  {0}  {1}" -f $name, $detail); $script:fails++ }
}

# DOS lines that run $cmd with stdout -> <tag>.OUT and the exit code -> <tag>.RC
# (the RC file holds 0, 1, 2 or 3 = "3 or more").  $tag: <= 5 chars (DOS labels are 8-significant), no dot, unique.
# NB: the staging shell creates a redirect target even when the `if` is false,
# so the RC is written with COPY of pre-made RCn.TXT files, not `echo > file`.
foreach ($n in 0..3) { Set-Content -Path "$stage\RC$n.TXT" -Value "$n" -Encoding ASCII }
function Cmd-Lines([string]$tag, [string]$cmd) {
    return @(
        "if exist $tag.OUT del $tag.OUT",
        "if exist $tag.RC del $tag.RC",
        "$cmd > $tag.OUT",
        "if errorlevel 3 goto ${tag}_3",
        "if errorlevel 2 goto ${tag}_2",
        "if errorlevel 1 goto ${tag}_1",
        "copy RC0.TXT $tag.RC > NUL",
        "goto ${tag}_e",
        ":${tag}_3",
        "copy RC3.TXT $tag.RC > NUL",
        "goto ${tag}_e",
        ":${tag}_2",
        "copy RC2.TXT $tag.RC > NUL",
        "goto ${tag}_e",
        ":${tag}_1",
        "copy RC1.TXT $tag.RC > NUL",
        ":${tag}_e"
    )
}
function Get-Rc([string]$tag) {
    $p = "$stage\$tag.RC"
    if (-not (Test-Path $p)) { return -1 }
    return [int]((Get-Content $p -Raw).Trim())
}
function Get-Out([string]$tag) {
    $p = "$stage\$tag.OUT"
    if (-not (Test-Path $p)) { return $null }
    return (Get-Content $p -Raw)
}

# Run DOS $lines in a fresh DOSBox with C: = $stage. Returns $true when DOSBox
# exited by itself within $ms, $false when it had to be killed (= hang).
function Run-Dos([string]$name, [string[]]$lines, [int]$ms = 20000) {
    $conf = @"
[sdl]
fullscreen = false
[cpu]
core    = normal
cputype = 486
cycles  = max
[autoexec]
@echo off
mount c "$stage"
c:
$($lines -join "`r`n")
exit
"@
    $cp = "$stage\_$name.conf"
    Set-Content -Path $cp -Value $conf -Encoding ASCII
    # --exit: this staging build ignores a bare `exit` at the end of [autoexec]
    $p = Start-Process -FilePath $dbox -ArgumentList @("-conf",$cp,"-noprimaryconf","--exit") -PassThru -WindowStyle Minimized
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $exited = $p.WaitForExit($ms)
    if (-not $exited) { try { $p.Kill() } catch {} ; Start-Sleep -Milliseconds 500 }
    Start-Sleep -Milliseconds 300
    Write-Host ("  [{0}] dosbox {1} after {2:N1}s" -f $name, $(if ($exited) {'exited'} else {'KILLED'}), $sw.Elapsed.TotalSeconds)
    return $exited
}

# ============================================================================
# each suite runs in its own child scope so its variables can't collide
& {
# ---- CCRAR / CCARJ: block-walk termination, safe extraction, 8.3 names -----
# Assumes harness helpers (Build-One, Cmd-Lines, Run-Dos, Get-Rc, Get-Out,
# Check, LE16, LE32, A4) are loaded and $stage is set.
Write-Host "== CCRAR / CCARJ =="
$sz = Build-One crar CCRAR; Write-Host "  CCRAR.COM $sz bytes"
$sz = Build-One carj CCARJ; Write-Host "  CCARJ.COM $sz bytes"

function RarCrc32([byte[]]$b) {
    $c = [uint32]::MaxValue
    foreach ($x in $b) {
        $c = $c -bxor $x
        for ($k = 0; $k -lt 8; $k++) {
            if ($c -band 1) { $c = ($c -shr 1) -bxor [uint32]3988292384 } else { $c = $c -shr 1 }
        }
    }
    return [uint32]($c -bxor [uint32]::MaxValue)
}
function RarU32([long]$v) { [byte]($v -band 0xFF), [byte](($v -shr 8) -band 0xFF), [byte](($v -shr 16) -band 0xFF), [byte](($v -shr 24) -band 0xFF) }
# block = HEAD_CRC(2) + body (body starts at HEAD_TYPE)
function RarBlock([byte[]]$body) {
    $crc = (RarCrc32 $body) -band 0xFFFF
    return ,([byte[]](LE16 $crc) + $body)
}
function RarFile([string]$name, [byte[]]$data, [int]$method = 0x30, [long]$pack = -1, [int]$nsize = -1) {
    [byte[]]$nb = A4 $name
    if ($pack -lt 0) { $pack = $data.Length }
    if ($nsize -lt 0) { $nsize = $nb.Length }
    $body = New-Object System.Collections.Generic.List[byte]
    $body.Add(0x74); $body.AddRange([byte[]](LE16 0x8000)); $body.AddRange([byte[]](LE16 (32 + $nb.Length)))
    $body.AddRange([byte[]](RarU32 $pack)); $body.AddRange([byte[]](RarU32 ([uint32]$data.Length)))
    $body.Add(0)                                        # HOST_OS
    $body.AddRange([byte[]](RarU32 (RarCrc32 $data)))
    $body.AddRange([byte[]](LE32 0)); $body.Add(20); $body.Add([byte]$method)
    $body.AddRange([byte[]](LE16 $nsize)); $body.AddRange([byte[]](LE32 0x20)); $body.AddRange($nb)
    return ,((RarBlock $body.ToArray()) + $data)
}
function RarArchive($parts, [bool]$end = $true) {
    $a = New-Object System.Collections.Generic.List[byte]
    $a.AddRange([byte[]](0x52,0x61,0x72,0x21,0x1A,0x07,0x00))
    $a.AddRange([byte[]](RarBlock ([byte[]](0x73, 0,0, 13,0, 0,0,0,0,0,0))))
    foreach ($p in $parts) { $a.AddRange([byte[]]$p) }
    if ($end) { $a.AddRange([byte[]](RarBlock ([byte[]](0x7B, 0x00,0x40, 7,0)))) }
    return ,$a.ToArray()
}

# ARJ: 60 EA, size, basic header, CRC32, ext-size 0 [, data]
function ArjBlock([byte[]]$hdr, [byte[]]$data) {
    $b = New-Object System.Collections.Generic.List[byte]
    $b.AddRange([byte[]](0x60,0xEA)); $b.AddRange([byte[]](LE16 $hdr.Length)); $b.AddRange($hdr)
    $b.AddRange([byte[]](RarU32 (RarCrc32 $hdr))); $b.AddRange([byte[]](0,0))
    if ($data) { $b.AddRange($data) }
    return ,$b.ToArray()
}
function ArjFile([string]$name, [byte[]]$data, [int]$first = 30, [long]$comp = -1, [int]$fake = -1) {
    if ($comp -lt 0) { $comp = $data.Length }
    $h = New-Object System.Collections.Generic.List[byte]
    $h.AddRange([byte[]]($first, 11, 1, 0, 0, 0, 0, 0))  # size,ver,min,os,flags,method 0,type 0 (binary),rsvd
    $h.AddRange([byte[]](LE32 0)); $h.AddRange([byte[]](RarU32 $comp)); $h.AddRange([byte[]](RarU32 ([uint32]$data.Length)))
    $h.AddRange([byte[]](RarU32 (RarCrc32 $data))); $h.AddRange([byte[]](0,0, 0x20,0, 0,0))
    for ($i = 30; $i -lt $first; $i++) { $h.Add(0xEE) }    # extra data (e.g. ext file pos)
    $h.AddRange([byte[]](A4 $name)); $h.Add(0); $h.Add(0)  # name, empty comment
    if ($fake -ge 0) { $h[0] = [byte]$fake }            # lie about first_hdr_size
    return ,(ArjBlock $h.ToArray() $data)
}
function ArjArchive($parts) {
    $a = New-Object System.Collections.Generic.List[byte]
    $m = New-Object System.Collections.Generic.List[byte]
    $m.AddRange([byte[]](30, 11, 1, 0, 0, 0, 2, 0)); for ($i = 0; $i -lt 22; $i++) { $m.Add(0) }
    $m.AddRange([byte[]](A4 "T.ARJ")); $m.Add(0); $m.Add(0)
    $a.AddRange([byte[]](ArjBlock $m.ToArray() $null))
    foreach ($p in $parts) { $a.AddRange([byte[]]$p) }
    $a.AddRange([byte[]](0x60,0xEA,0,0))
    return ,$a.ToArray()
}

$rA  = A4 "alpha"; $rB = A4 "bravo!"; $rP1 = A4 "part one"; $rP2 = A4 "part two!!"
$rEv = A4 "evil"; $rDr = A4 "drive"; $rDd = A4 "dots"
$rBig = New-Object byte[] 9000; for ($i = 0; $i -lt 9000; $i++) { $rBig[$i] = [byte](($i * 7) -band 0xFF) }

# valid: two README.TXT in different dirs, two long names equal at 8.3, path
# escapes (..\, drive, "..") and a 9000-byte member (3 read chunks)
$good = RarArchive @(
    (RarFile "a/README.TXT" $rA), (RarFile "b\README.TXT" $rB),
    (RarFile "GAME PART1.DAT" $rP1), (RarFile "GAME PART2.DAT" $rP2),
    (RarFile "..\..\EVIL.TXT" $rEv), (RarFile "C:EVIL2.TXT" $rDr), (RarFile ".." $rDd),
    (RarFile "BIG.BIN" $rBig))
[IO.File]::WriteAllBytes("$stage\GOOD.RAR", $good)
# compressed member (method 0x33): listed, not extractable
[IO.File]::WriteAllBytes("$stage\COMP.RAR", (RarArchive @((RarFile "PACKED.TXT" $rA 0x33))))
# backward ADD_SIZE on a non-file LONG block: hsize 11 + FFFFFFF5 = back to its start
$bk = RarBlock ([byte[]](0x7A, 0x00,0x80, 11,0) + [byte[]](0xF5,0xFF,0xFF,0xFF))
[IO.File]::WriteAllBytes("$stage\BACK.RAR", (RarArchive @($bk, (RarFile "AFTER.TXT" $rA))))
# backward PACK_SIZE on a file block
[IO.File]::WriteAllBytes("$stage\BACK2.RAR", (RarArchive @((RarFile "X.TXT" $rA 0x30 4294967248))))
# truncated inside the big member's data, and inside a block header
$tr = [byte[]]$good[0..($good.Length - 3000)]; [IO.File]::WriteAllBytes("$stage\TRUNC.RAR", $tr)
$full = RarArchive @((RarFile "ONE.TXT" $rA)) $false
[IO.File]::WriteAllBytes("$stage\TRUNCH.RAR", [byte[]]$full[0..30])
# NAME_SIZE 0xFFFF with a 5-byte real name
[IO.File]::WriteAllBytes("$stage\HUGEN.RAR", (RarArchive @((RarFile "N.TXT" $rA 0x30 -1 0xFFFF))))

# ARJ: header with extra data (first_hdr_size 34), same collisions
$agood = ArjArchive @(
    (ArjFile "a\README.TXT" $rA), (ArjFile "b/README.TXT" $rB 34),
    (ArjFile "GAME PART1.DAT" $rP1 34), (ArjFile "GAME PART2.DAT" $rP2),
    (ArjFile "..\EVIL.TXT" $rEv), (ArjFile "BIG.BIN" $rBig))
[IO.File]::WriteAllBytes("$stage\GOOD.ARJ", $agood)
[IO.File]::WriteAllBytes("$stage\BACK.ARJ", (ArjArchive @((ArjFile "X.TXT" $rA 30 4294967264), (ArjFile "Y.TXT" $rB))))
[IO.File]::WriteAllBytes("$stage\BADF.ARJ", (ArjArchive @((ArjFile "X.TXT" $rA 30 -1 200))))
$at = [byte[]]$agood[0..($agood.Length - 3000)]; [IO.File]::WriteAllBytes("$stage\TRUNC.ARJ", $at)

foreach ($d in 'ROUT','ROUT2','ROUT3','AOUT','AOUT2') {
    if (Test-Path "$stage\$d") { Remove-Item "$stage\$d" -Recurse -Force }
    New-Item -ItemType Directory -Path "$stage\$d" | Out-Null
}
foreach ($f in "$stage\EVIL.TXT", "$stage\..\EVIL.TXT", "$stage\EVIL2.TXT") { if (Test-Path $f) { Remove-Item $f -Force } }
[IO.File]::WriteAllBytes("$stage\ROUT2\README.TXT", (A4 "KEEP"))
[IO.File]::WriteAllBytes("$stage\AOUT2\README.TXT", (A4 "KEEP"))

$lines = @()
$lines += Cmd-Lines RL1 "CCRAR.COM L GOOD.RAR"
$lines += Cmd-Lines RXA "CCRAR.COM XA GOOD.RAR ROUT"
$lines += Cmd-Lines RX0 "CCRAR.COM X GOOD.RAR 0 ROUT2"
$lines += Cmd-Lines RXN "CCRAR.COM X GOOD.RAR 99 ROUT2"
$lines += Cmd-Lines RCP "CCRAR.COM X COMP.RAR 0 ROUT2"
$lines += Cmd-Lines RBK "CCRAR.COM L BACK.RAR"
$lines += Cmd-Lines RBK2 "CCRAR.COM L BACK2.RAR"
$lines += Cmd-Lines RTR "CCRAR.COM XA TRUNC.RAR ROUT3"
$lines += Cmd-Lines RTH "CCRAR.COM L TRUNCH.RAR"
$lines += Cmd-Lines RHN "CCRAR.COM L HUGEN.RAR"
$lines += Cmd-Lines AL1 "CCARJ.COM L GOOD.ARJ"
$lines += Cmd-Lines AXA "CCARJ.COM XA GOOD.ARJ AOUT"
$lines += Cmd-Lines AX0 "CCARJ.COM X GOOD.ARJ 0 AOUT2"
$lines += Cmd-Lines ABK "CCARJ.COM L BACK.ARJ"
$lines += Cmd-Lines ABF "CCARJ.COM L BADF.ARJ"
$lines += Cmd-Lines ATR "CCARJ.COM XA TRUNC.ARJ AOUT2"
$lines += Cmd-Lines ANA "CCARJ.COM L GOOD.RAR"
$ok = Run-Dos rararj $lines 40000
Check "rar/arj batch terminates (no hang)" $ok

function RarSame([string]$path, [byte[]]$want) {
    if (-not (Test-Path $path)) { return $false }
    $got = [IO.File]::ReadAllBytes($path)
    return ($got.Length -eq $want.Length) -and (-not (Compare-Object $got $want -SyncWindow 0))
}
function RarNames([string]$d) { (Get-ChildItem $d | ForEach-Object { $_.Name.ToUpper() } | Sort-Object) -join ',' }

# --- RAR positive
$expL = "5 README.TXT`r`n6 README.TXT`r`n8 GAME_PART1.D`r`n10 GAME_PART2.D`r`n4 EVIL.TXT`r`n5 C:EVIL2.TXT`r`n4 ..`r`n9000 BIG.BIN`r`n"
Check "RAR L listing unchanged" ((Get-Out RL1) -ceq $expL) ("got: " + (Get-Out RL1))
Check "RAR L rc 0" ((Get-Rc RL1) -eq 0) "rc=$(Get-Rc RL1)"
Check "RAR XA rc 0" ((Get-Rc RXA) -eq 0) "rc=$(Get-Rc RXA) out=$(Get-Out RXA)"
Check "RAR XA unique 8.3 names" ((RarNames "$stage\ROUT") -eq '_,BIG.BIN,C_EVIL2.TXT,EVIL.TXT,GAME_P~1.DAT,GAME_PAR.DAT,README.TXT,README~1.TXT') (RarNames "$stage\ROUT")
Check "RAR XA bytes" ((RarSame "$stage\ROUT\README.TXT" $rA) -and (RarSame "$stage\ROUT\README~1.TXT" $rB) -and
    (RarSame "$stage\ROUT\GAME_PAR.DAT" $rP1) -and (RarSame "$stage\ROUT\GAME_P~1.DAT" $rP2) -and
    (RarSame "$stage\ROUT\EVIL.TXT" $rEv) -and (RarSame "$stage\ROUT\_" $rDd) -and (RarSame "$stage\ROUT\BIG.BIN" $rBig))
Check "RAR no path escape" (-not (Test-Path "$stage\EVIL.TXT") -and -not (Test-Path "$stage\..\EVIL.TXT") -and -not (Test-Path "$stage\EVIL2.TXT"))
Check "RAR X keeps existing file" ((RarSame "$stage\ROUT2\README.TXT" (A4 "KEEP")) -and (RarSame "$stage\ROUT2\README~1.TXT" $rA) -and (Get-Rc RX0) -eq 0) "rc=$(Get-Rc RX0) $(RarNames "$stage\ROUT2")"
Check "RAR X bad index rc 1" ((Get-Rc RXN) -eq 1) "rc=$(Get-Rc RXN)"
Check "RAR X compressed rc 1" ((Get-Rc RCP) -eq 1) "rc=$(Get-Rc RCP)"
# --- RAR malformed
Check "RAR backward ADD_SIZE: stops, rc 1" ((Get-Rc RBK) -eq 1) "rc=$(Get-Rc RBK) out=$(Get-Out RBK)"
Check "RAR backward PACK_SIZE: stops, rc 1" ((Get-Rc RBK2) -eq 1) "rc=$(Get-Rc RBK2)"
Check "RAR truncated XA: rc 1 + message, partial deleted" (((Get-Rc RTR) -eq 1) -and ((Get-Out RTR) -match 'truncated') -and
    -not (Test-Path "$stage\ROUT3\BIG.BIN")) "rc=$(Get-Rc RTR) out=$(Get-Out RTR) files=$(RarNames "$stage\ROUT3")"
Check "RAR truncated header: rc 1" ((Get-Rc RTH) -eq 1) "rc=$(Get-Rc RTH)"
Check "RAR huge NAME_SIZE: clamped" (((Get-Rc RHN) -eq 0) -and ((Get-Out RHN) -ceq "5 N.TXT`r`n")) "rc=$(Get-Rc RHN) out=$(Get-Out RHN)"

# --- ARJ positive (names at first_hdr_size = 30 and 34)
$expA = "5 README.TXT`r`n6 README.TXT`r`n8 GAME_PART1.D`r`n10 GAME_PART2.D`r`n4 EVIL.TXT`r`n9000 BIG.BIN`r`n"
Check "ARJ L names at first_hdr_size" ((Get-Out AL1) -ceq $expA) ("got: " + (Get-Out AL1))
Check "ARJ L rc 0" ((Get-Rc AL1) -eq 0) "rc=$(Get-Rc AL1)"
Check "ARJ XA rc 0" ((Get-Rc AXA) -eq 0) "rc=$(Get-Rc AXA) out=$(Get-Out AXA)"
Check "ARJ XA unique 8.3 names" ((RarNames "$stage\AOUT") -eq 'BIG.BIN,EVIL.TXT,GAME_P~1.DAT,GAME_PAR.DAT,README.TXT,README~1.TXT') (RarNames "$stage\AOUT")
Check "ARJ XA bytes" ((RarSame "$stage\AOUT\README.TXT" $rA) -and (RarSame "$stage\AOUT\README~1.TXT" $rB) -and
    (RarSame "$stage\AOUT\GAME_PAR.DAT" $rP1) -and (RarSame "$stage\AOUT\GAME_P~1.DAT" $rP2) -and (RarSame "$stage\AOUT\BIG.BIN" $rBig))
Check "ARJ X keeps existing file" ((RarSame "$stage\AOUT2\README.TXT" (A4 "KEEP")) -and (RarSame "$stage\AOUT2\README~1.TXT" $rA) -and (Get-Rc AX0) -eq 0) "rc=$(Get-Rc AX0)"
# --- ARJ malformed
Check "ARJ backward size: stops, rc 1" (((Get-Rc ABK) -eq 1) -and ("$(Get-Out ABK)" -notmatch 'Y.TXT')) "rc=$(Get-Rc ABK) out=$(Get-Out ABK)"
Check "ARJ first_hdr_size > header: rc 1" ((Get-Rc ABF) -eq 1) "rc=$(Get-Rc ABF)"
Check "ARJ truncated XA: rc 1, partial deleted" (((Get-Rc ATR) -eq 1) -and -not (Test-Path "$stage\AOUT2\BIG.BIN")) "rc=$(Get-Rc ATR) out=$(Get-Out ATR)"
Check "ARJ on a non-ARJ file: rc 1" ((Get-Rc ANA) -eq 1) "rc=$(Get-Rc ANA)"
}

# ============================================================================
# each suite runs in its own child scope so its variables can't collide
& {
# ---- CCD64 / CCT64 ----------------------------------------------------------
# assumes harness.ps1 is dot-sourced and $stage is set
Write-Host "== CCD64 / CCT64 =="
$null = Build-One cd64 CCD64
$null = Build-One ct64 CCT64

# --- D64 helpers ---
function D64Idx([int]$t, [int]$s) {
    $n = 0
    for ($i = 1; $i -lt $t; $i++) { $n += $(if ($i -le 17) {21} elseif ($i -le 24) {19} elseif ($i -le 30) {18} else {17}) }
    return $n + $s
}
function D64Put([byte[]]$img, [int]$t, [int]$s, [int]$off, [byte[]]$b) {
    [Array]::Copy($b, 0, $img, (D64Idx $t $s) * 256 + $off, $b.Length)
}
function D64Name([string]$n) {
    $b = New-Object byte[] 16
    for ($i = 0; $i -lt 16; $i++) { $b[$i] = 0xA0 }
    $a = [Text.Encoding]::ASCII.GetBytes($n); [Array]::Copy($a, $b, $a.Length); return ,$b
}
# dir entry $e (0..7) in dir sector 18/$ds: PRG starting at $t/$s, $blocks
function D64Entry([byte[]]$img, [int]$ds, [int]$e, [string]$name, [int]$t, [int]$s, [int]$blocks) {
    $x = New-Object byte[] 30
    $x[0] = 0x82; $x[1] = $t; $x[2] = $s
    [Array]::Copy((D64Name $name), 0, $x, 3, 16)
    $x[28] = $blocks -band 0xFF; $x[29] = $blocks -shr 8
    D64Put $img 18 $ds ($e * 32 + 2) $x
}
function D64Data([int]$n, [int]$seed) {
    $b = New-Object byte[] $n; for ($i = 0; $i -lt $n; $i++) { $b[$i] = [byte](($i * 7 + $seed) -band 0xFF) }; return ,$b
}
# write $data as a chain over the (t,s) pairs in $secs
function D64Chain([byte[]]$img, [int[][]]$secs, [byte[]]$data) {
    $p = 0
    for ($k = 0; $k -lt $secs.Count; $k++) {
        $t = $secs[$k][0]; $s = $secs[$k][1]
        $n = [Math]::Min(254, $data.Length - $p)
        if ($k -lt $secs.Count - 1) { $hd = [byte[]]($secs[$k+1][0], $secs[$k+1][1]) }
        else { $hd = [byte[]](0, ($n + 1)) }
        D64Put $img $t $s 0 $hd
        D64Put $img $t $s 2 ($data[$p..($p + $n - 1)])
        $p += $n
    }
}
function D64New { $i = New-Object byte[] 174848; D64Put $i 18 1 0 ([byte[]](0, 0xFF)); return ,$i }

# valid image: two names that collide at 8.3 plus a 3-sector file
$dA = D64Data 100 1; $dB = D64Data 60 2; $dC = D64Data 558 3
$g = D64New
D64Entry $g 1 0 "GAME PART1" 1 0 1
D64Entry $g 1 1 "GAME PART2" 1 1 1
D64Entry $g 1 2 "BIGFILE"    2 0 3
D64Chain $g @(,@(1,0)) $dA
D64Chain $g @(,@(1,1)) $dB
D64Chain $g @(@(2,0),@(2,5),@(3,1)) $dC
[IO.File]::WriteAllBytes("$stage\DGOOD.D64", $g)

# file chain link to track 99 (old code rewrote a stale sector 700 times)
$b = D64New
D64Entry $b 1 0 "BADLINK" 1 0 2
D64Put $b 1 0 0 ([byte[]](99, 0)); D64Put $b 1 0 2 (D64Data 254 4)
D64Entry $b 1 1 "OKFILE" 1 1 1
D64Chain $b @(,@(1,1)) $dB
[IO.File]::WriteAllBytes("$stage\DBADT.D64", $b)

# cyclic file chain 1/0 -> 1/1 -> 1/0
$c = D64New
D64Entry $c 1 0 "CYCLE" 1 0 2
D64Put $c 1 0 0 ([byte[]](1, 1)); D64Put $c 1 1 0 ([byte[]](1, 0))
[IO.File]::WriteAllBytes("$stage\DCYC.D64", $c)

# directory chain loops on itself (18/1 -> 18/1)
$dcy = D64New
D64Entry $dcy 1 0 "ONE" 1 0 1
D64Chain $dcy @(,@(1,0)) $dA
D64Put $dcy 18 1 0 ([byte[]](18, 1))
[IO.File]::WriteAllBytes("$stage\DDCYC.D64", $dcy)

# directory chain to an invalid sector (18/25: track 18 has 19)
$di = D64New
D64Entry $di 1 0 "ONE" 1 0 1
D64Chain $di @(,@(1,0)) $dA
D64Put $di 18 1 0 ([byte[]](18, 25))
[IO.File]::WriteAllBytes("$stage\DDBAD.D64", $di)

# truncated: directory intact, file chain runs into track 30 (past the end)
$t = D64New
D64Entry $t 1 0 "TRUNC" 1 0 2
D64Put $t 1 0 0 ([byte[]](30, 0)); D64Put $t 1 0 2 (D64Data 254 5)
[IO.File]::WriteAllBytes("$stage\DTRUNC.D64", $t[0..99999])
[IO.File]::WriteAllBytes("$stage\DTINY.D64", $t[0..999])

# --- T64 helpers ---
function T64Img([int]$maxent, [object[]]$recs, [int]$pad) {
    # $recs: @(name, load, end, offset) ; data appended by caller
    $h = New-Object byte[] (64 + $maxent * 32)
    $sig = [Text.Encoding]::ASCII.GetBytes("C64S tape image file"); [Array]::Copy($sig, $h, $sig.Length)
    $h[32] = 1; $h[33] = 1; $h[34] = $maxent -band 0xFF; $h[35] = $maxent -shr 8
    $h[36] = $recs.Count
    for ($i = 0; $i -lt $recs.Count -and $i -lt $maxent; $i++) {
        $r = $recs[$i]; $o = 64 + $i * 32
        $h[$o] = 1; $h[$o+1] = 0x82
        [Array]::Copy([byte[]](LE16 $r[1]), 0, $h, $o+2, 2)
        [Array]::Copy([byte[]](LE16 $r[2]), 0, $h, $o+4, 2)
        [Array]::Copy([byte[]](LE32 $r[3]), 0, $h, $o+8, 4)
        $nm = [Text.Encoding]::ASCII.GetBytes($r[0].PadRight(16))
        [Array]::Copy($nm, 0, $h, $o+16, 16)
    }
    return ,$h
}
$tA = D64Data 50 11; $tB = D64Data 30 12; $tC = D64Data 5000 13
$base = 64 + 3 * 32
$tg = T64Img 3 @(@("GAME PART1", 0x0801, (0x0801+50), $base),
                 @("GAME PART2", 0x0801, (0x0801+30), ($base+50)),
                 @("LONGER",     0x1000, (0x1000+5000), ($base+80))) 0
[IO.File]::WriteAllBytes("$stage\TGOOD.T64", [byte[]]($tg + $tA + $tB + $tC))

# bogus: rec0 offset far past EOF, rec1 end<load (clamped to EOF), and the
# header claims 1000 entries although the file ends after 2 records + data
$tbad = T64Img 2 @(@("FAROFF", 0x0801, 0x0900, 0x00FFFFFF),
                 @("WRAPEND", 0x0801, 0x0010, 128)) 0
$tbad[34] = 0xE8; $tbad[35] = 0x03
# data byte 0 = 0, so the slot after rec1 (overlapping the data) reads as free
[IO.File]::WriteAllBytes("$stage\TBAD.T64", [byte[]]($tbad + (D64Data 40 0)))
[IO.File]::WriteAllBytes("$stage\TTINY.T64", [byte[]](0x43, 0x36, 0x34))

foreach ($d in 'DOUT','TOUT','XOUT','KOUT','KOUT2') {
    if (Test-Path "$stage\$d") { Remove-Item "$stage\$d" -Recurse -Force }
    New-Item -ItemType Directory -Path "$stage\$d" | Out-Null
}
# X onto an existing file must never overwrite: KOUT holds the targets already;
# in KOUT2 GAME.PRG and every GAME~1..~9.PRG are taken, so X must fail
[IO.File]::WriteAllBytes("$stage\KOUT\BIGFILE.PRG", (A4 "KEEP"))
[IO.File]::WriteAllBytes("$stage\KOUT\LONGER.PRG", (A4 "KEEP"))
foreach ($n in @("GAME.PRG") + (1..9 | ForEach-Object { "GAME~$_.PRG" })) { [IO.File]::WriteAllBytes("$stage\KOUT2\$n", (A4 "KEEP")) }
$L = @()
$L += Cmd-Lines DL   "CCD64.COM L DGOOD.D64"
$L += Cmd-Lines DXA  "CCD64.COM XA DGOOD.D64 DOUT"
$L += Cmd-Lines DX1  "CCD64.COM X DGOOD.D64 2 XOUT"
$L += Cmd-Lines DX9  "CCD64.COM X DGOOD.D64 9 XOUT"
$L += Cmd-Lines DBT  "CCD64.COM XA DBADT.D64 XOUT"
$L += Cmd-Lines DCY  "CCD64.COM X DCYC.D64 0 XOUT"
$L += Cmd-Lines DDC  "CCD64.COM L DDCYC.D64"
$L += Cmd-Lines DDB  "CCD64.COM L DDBAD.D64"
$L += Cmd-Lines DTR  "CCD64.COM X DTRUNC.D64 0 XOUT"
$L += Cmd-Lines DTI  "CCD64.COM L DTINY.D64"
$L += Cmd-Lines TL   "CCT64.COM L TGOOD.T64"
$L += Cmd-Lines TXA  "CCT64.COM XA TGOOD.T64 TOUT"
$L += Cmd-Lines TX9  "CCT64.COM X TGOOD.T64 9 XOUT"
$L += Cmd-Lines TBL  "CCT64.COM L TBAD.T64"
$L += Cmd-Lines TBX  "CCT64.COM XA TBAD.T64 XOUT"
$L += Cmd-Lines TTI  "CCT64.COM L TTINY.T64"
$L += Cmd-Lines DXK  "CCD64.COM X DGOOD.D64 2 KOUT"
$L += Cmd-Lines TXK  "CCT64.COM X TGOOD.T64 2 KOUT"
$L += Cmd-Lines TXF  "CCT64.COM X TGOOD.T64 0 KOUT2"
$ok = Run-Dos d64t64 $L 30000
Check "d64/t64: all runs terminate" $ok

function D64Same([string]$p, [byte[]]$exp) {
    if (-not (Test-Path $p)) { return $false }
    $g = [IO.File]::ReadAllBytes($p)
    return ($g.Length -eq $exp.Length) -and (-not (Compare-Object $g $exp -SyncWindow 0))
}
$o = Get-Out DL
Check "D64 L listing" ((Get-Rc DL) -eq 0 -and $o -eq "254 GAME_PAR.PRG`r`n254 GAME_PAR.PRG`r`n762 BIGFILE.PRG`r`n") "rc=$(Get-Rc DL) out=[$o]"
Check "D64 XA rc 0" ((Get-Rc DXA) -eq 0) "rc=$(Get-Rc DXA) $(Get-Out DXA)"
Check "D64 XA GAME_PAR.PRG" (D64Same "$stage\DOUT\GAME_PAR.PRG" $dA)
Check "D64 XA collision -> GAME_P~1.PRG" (D64Same "$stage\DOUT\GAME_P~1.PRG" $dB)
Check "D64 XA 3-sector BIGFILE.PRG" (D64Same "$stage\DOUT\BIGFILE.PRG" $dC)
Check "D64 X #2" ((Get-Rc DX1) -eq 0 -and (D64Same "$stage\XOUT\BIGFILE.PRG" $dC)) "rc=$(Get-Rc DX1)"
Check "D64 X missing index -> rc 1" ((Get-Rc DX9) -eq 1) "rc=$(Get-Rc DX9)"
Check "D64 link to track 99 -> rc 1, msg, no partial" ((Get-Rc DBT) -eq 1 -and (Get-Out DBT) -match 'bad sector chain' -and -not (Test-Path "$stage\XOUT\BADLINK.PRG")) "rc=$(Get-Rc DBT) $(Get-Out DBT)"
Check "D64 good file after a bad one still extracted" (D64Same "$stage\XOUT\OKFILE.PRG" $dB)
Check "D64 cyclic chain -> rc 1, no partial" ((Get-Rc DCY) -eq 1 -and -not (Test-Path "$stage\XOUT\CYCLE.PRG")) "rc=$(Get-Rc DCY)"
Check "D64 cyclic dir -> listed once, rc 1" ((Get-Rc DDC) -eq 1 -and (Get-Out DDC) -eq "254 ONE.PRG`r`n") "rc=$(Get-Rc DDC) out=[$(Get-Out DDC)]"
Check "D64 bad dir link -> listed once, rc 1" ((Get-Rc DDB) -eq 1 -and (Get-Out DDB) -eq "254 ONE.PRG`r`n") "rc=$(Get-Rc DDB) out=[$(Get-Out DDB)]"
Check "D64 truncated image chain -> rc 1, no partial" ((Get-Rc DTR) -eq 1 -and -not (Test-Path "$stage\XOUT\TRUNC.PRG")) "rc=$(Get-Rc DTR)"
Check "D64 tiny image -> rc 1, empty listing" ((Get-Rc DTI) -eq 1 -and -not (Get-Out DTI)) "rc=$(Get-Rc DTI) out=[$(Get-Out DTI)]"

$o = Get-Out TL
Check "T64 L listing" ((Get-Rc TL) -eq 0 -and $o -eq "52 GAME.PRG`r`n32 GAME.PRG`r`n5002 LONGER.PRG`r`n") "rc=$(Get-Rc TL) out=[$o]"
Check "T64 XA rc 0" ((Get-Rc TXA) -eq 0) "rc=$(Get-Rc TXA) $(Get-Out TXA)"
Check "T64 XA GAME.PRG" (D64Same "$stage\TOUT\GAME.PRG" ([byte[]](1,8) + $tA))
Check "T64 XA collision -> GAME~1.PRG" (D64Same "$stage\TOUT\GAME~1.PRG" ([byte[]](1,8) + $tB))
Check "T64 XA 5000-byte LONGER.PRG" (D64Same "$stage\TOUT\LONGER.PRG" ([byte[]](0,0x10) + $tC))
Check "T64 X missing index -> rc 1" ((Get-Rc TX9) -eq 1) "rc=$(Get-Rc TX9)"
$o = Get-Out TBL
Check "T64 bogus: listing bounded, rc 1" ((Get-Rc TBL) -eq 1 -and ($o -split "`r`n" | Where-Object { $_ }).Count -eq 2) "rc=$(Get-Rc TBL) out=[$o]"
Check "T64 bogus XA: rc 1, msg, no FAROFF file" ((Get-Rc TBX) -eq 1 -and (Get-Out TBX) -match 'past end' -and -not (Test-Path "$stage\XOUT\FAROFF.PRG")) "rc=$(Get-Rc TBX) $(Get-Out TBX)"
Check "T64 bogus XA: clamped record extracted" ((Test-Path "$stage\XOUT\WRAPEND.PRG") -and (Get-Item "$stage\XOUT\WRAPEND.PRG").Length -eq 42)
Check "T64 tiny -> rc 1, empty listing" ((Get-Rc TTI) -eq 1 -and -not (Get-Out TTI)) "rc=$(Get-Rc TTI) out=[$(Get-Out TTI)]"
$keep = A4 "KEEP"
Check "D64 X onto existing: original kept, BIGFIL~1.PRG written" ((Get-Rc DXK) -eq 0 -and (D64Same "$stage\KOUT\BIGFILE.PRG" $keep) -and (D64Same "$stage\KOUT\BIGFIL~1.PRG" $dC)) "rc=$(Get-Rc DXK) $(Get-Out DXK)"
Check "T64 X onto existing: original kept, LONGER~1.PRG written" ((Get-Rc TXK) -eq 0 -and (D64Same "$stage\KOUT\LONGER.PRG" $keep) -and (D64Same "$stage\KOUT\LONGER~1.PRG" ([byte[]](0,0x10) + $tC))) "rc=$(Get-Rc TXK) $(Get-Out TXK)"
$k2 = @(Get-ChildItem "$stage\KOUT2" | Where-Object { -not (D64Same $_.FullName $keep) })
Check "T64 X with GAME.PRG + GAME~1..~9 taken: rc 1, nothing overwritten or added" ((Get-Rc TXF) -eq 1 -and $k2.Count -eq 0 -and @(Get-ChildItem "$stage\KOUT2").Count -eq 10) "rc=$(Get-Rc TXF) changed=$($k2.Name -join ',')"
}

# ============================================================================
# each suite runs in its own child scope so its variables can't collide
& {
# ---- CCIMG / CCWAV: malformed images + WAVs must terminate with an error;
#      valid ones (run_img.ps1 / run_wav.ps1 fixtures + a top-down BMP) must
#      still decode byte-exact via the /D dump mode.  (fork C fragment)
Write-Host "== CCIMG / CCWAV =="
$null = Build-One cimg CCIMG
$null = Build-One cwav CCWAV

# ---------- image fixtures (17x5, same pixels/palette as run_img.ps1) ------
$ImgW = 17; $ImgH = 5
$ImgPix = New-Object System.Collections.Generic.List[int]
for ($r=0; $r -lt $ImgH; $r++) { for ($c=0; $c -lt $ImgW; $c++) { if ($c -lt 10) { $ImgPix.Add(0xC5) } else { $ImgPix.Add($c) } } }
$ImgPix = $ImgPix.ToArray()

# BMP: $h = height as stored (negative = top-down), $bpp/$comp header fields,
#      $cut = keep only the first $cut bytes (0 = whole file)
function Img-Bmp([string]$name, [int]$w, [int]$h, [int]$bpp = 8, [int]$comp = 0, [int]$cut = 0) {
    $b = New-Object System.Collections.Generic.List[byte]
    $off = 14 + 40 + 256*4
    $absH = [Math]::Abs($h)
    $rowbytes = [int]([Math]::Floor(($w + 3) / 4)) * 4
    $b.AddRange([byte[]](0x42,0x4D)); $b.AddRange([byte[]](LE32 ($off + $rowbytes*$absH)))
    $b.AddRange([byte[]](LE32 0)); $b.AddRange([byte[]](LE32 $off))
    $b.AddRange([byte[]](LE32 40)); $b.AddRange([byte[]](LE32 $w)); $b.AddRange([byte[]](LE32 ([long]$h -band 0xFFFFFFFFL)))
    $b.AddRange([byte[]](LE16 1)); $b.AddRange([byte[]](LE16 $bpp)); $b.AddRange([byte[]](LE32 $comp))
    $b.AddRange([byte[]](LE32 ($rowbytes*$absH))); $b.AddRange([byte[]](LE32 0)); $b.AddRange([byte[]](LE32 0))
    $b.AddRange([byte[]](LE32 0)); $b.AddRange([byte[]](LE32 0))
    for ($i=0; $i -lt 256; $i++) { $b.AddRange([byte[]]($i,$i,$i,0)) }
    if ($w -eq $ImgW -and $absH -eq $ImgH) {
        $rows = if ($h -lt 0) { 0..($ImgH-1) } else { ($ImgH-1)..0 }
        foreach ($r in $rows) {
            for ($c=0; $c -lt $w; $c++) { $b.Add([byte]$ImgPix[$r*$w+$c]) }
            for ($p=$w; $p -lt $rowbytes; $p++) { $b.Add([byte]0) }
        }
    } else { for ($i=0; $i -lt 100; $i++) { $b.Add([byte]($i -band 0xFF)) } }
    $a = $b.ToArray()
    if ($cut -gt 0) { $a = $a[0..($cut-1)] }
    [IO.File]::WriteAllBytes("$stage\$name", $a)
}

function Img-Pcx([string]$name, [int]$xmax, [int]$ymax, [int]$bits = 8, [bool]$full = $true) {
    $p = New-Object System.Collections.Generic.List[byte]
    $hdr = New-Object byte[] 128
    $hdr[0]=0x0A; $hdr[1]=5; $hdr[2]=1; $hdr[3]=[byte]$bits
    $hdr[8]=[byte]($xmax -band 0xFF); $hdr[9]=[byte](($xmax -shr 8) -band 0xFF)
    $hdr[10]=[byte]($ymax -band 0xFF); $hdr[11]=[byte](($ymax -shr 8) -band 0xFF)
    $hdr[65]=1
    $bpl = if ((($xmax+1) % 2) -eq 0) { $xmax+1 } else { $xmax+2 }
    $hdr[66]=[byte]($bpl -band 0xFF); $hdr[67]=[byte](($bpl -shr 8) -band 0xFF)
    $p.AddRange($hdr)
    if ($full) {
        for ($r=0; $r -lt $ImgH; $r++) {
            $line = New-Object byte[] $bpl
            for ($c=0; $c -lt $ImgW; $c++) { $line[$c] = [byte]$ImgPix[$r*$ImgW+$c] }
            $i = 0
            while ($i -lt $bpl) {
                $v = $line[$i]; $run = 1
                while (($i+$run) -lt $bpl -and $line[$i+$run] -eq $v -and $run -lt 63) { $run++ }
                if ($run -gt 1 -or $v -ge 0xC0) { $p.Add([byte](0xC0 -bor $run)); $p.Add([byte]$v) } else { $p.Add([byte]$v) }
                $i += $run
            }
        }
        $p.Add([byte]0x0C)
        for ($i=0; $i -lt 256; $i++) { $p.AddRange([byte[]]($i,$i,$i)) }
    } else { for ($i=0; $i -lt 60; $i++) { $p.Add([byte]0xC5) } }   # truncated: no tail
    [IO.File]::WriteAllBytes("$stage\$name", $p.ToArray())
}

# LZW encoder (from run_img.ps1) -> byte stream for a valid image
function Img-Lzw([int[]]$idx, [int]$minCodeSize) {
    $clear = 1 -shl $minCodeSize; $eoi = $clear + 1; $codeSize = $minCodeSize + 1; $next = $eoi + 1
    $dict = @{}; $codes = New-Object System.Collections.Generic.List[int]; $widths = New-Object System.Collections.Generic.List[int]
    $codes.Add($clear); $widths.Add($codeSize)
    $prefix = $idx[0]
    for ($i=1; $i -lt $idx.Count; $i++) {
        $k = $idx[$i]; $key = "$prefix,$k"
        if ($dict.ContainsKey($key)) { $prefix = $dict[$key] }
        else {
            $codes.Add($prefix); $widths.Add($codeSize); $dict[$key] = $next; $next++
            if ($next -ge (1 -shl $codeSize) -and $codeSize -lt 12) { $codeSize++ }
            $prefix = $k
        }
    }
    $codes.Add($prefix); $widths.Add($codeSize); $codes.Add($eoi); $widths.Add($codeSize)
    return ,(Img-Pack $codes.ToArray() $widths.ToArray())
}
function Img-Pack([int[]]$codes, [int[]]$widths) {
    $bytes = New-Object System.Collections.Generic.List[byte]; $acc = 0; $nb = 0
    for ($i=0; $i -lt $codes.Count; $i++) {
        $acc = $acc -bor ($codes[$i] -shl $nb); $nb += $widths[$i]
        while ($nb -ge 8) { $bytes.Add([byte]($acc -band 0xFF)); $acc = $acc -shr 8; $nb -= 8 }
    }
    if ($nb -gt 0) { $bytes.Add([byte]($acc -band 0xFF)) }
    return ,($bytes.ToArray())
}
function Img-Gif([string]$name, [int]$minCode, [byte[]]$lzw) {
    $g = New-Object System.Collections.Generic.List[byte]
    $g.AddRange([System.Text.Encoding]::ASCII.GetBytes("GIF87a"))
    $g.AddRange([byte[]](LE16 $ImgW)); $g.AddRange([byte[]](LE16 $ImgH)); $g.AddRange([byte[]](0x87,0,0))
    for ($i=0; $i -lt 256; $i++) { $g.AddRange([byte[]]($i,$i,$i)) }
    $g.Add([byte]0x2C); $g.AddRange([byte[]](LE16 0)); $g.AddRange([byte[]](LE16 0))
    $g.AddRange([byte[]](LE16 $ImgW)); $g.AddRange([byte[]](LE16 $ImgH)); $g.Add([byte]0)
    $g.Add([byte]$minCode)
    $p = 0
    while ($p -lt $lzw.Count) {
        $n = [Math]::Min(255, $lzw.Count - $p); $g.Add([byte]$n)
        for ($j=0; $j -lt $n; $j++) { $g.Add([byte]$lzw[$p+$j]) }
        $p += $n
    }
    $g.AddRange([byte[]](0, 0x3B))
    [IO.File]::WriteAllBytes("$stage\$name", $g.ToArray())
}

# expected RAW for the valid 17x5 image
$ImgExp = New-Object System.Collections.Generic.List[byte]
$ImgExp.AddRange([byte[]](LE16 $ImgW)); $ImgExp.AddRange([byte[]](LE16 $ImgH))
foreach ($v in $ImgPix) { $ImgExp.Add([byte]$v) }
for ($i=0; $i -lt 256; $i++) { $ImgExp.AddRange([byte[]]($i,$i,$i)) }
$ImgExp = $ImgExp.ToArray()

Img-Bmp "OK.BMP"  $ImgW $ImgH
Img-Bmp "TD.BMP"  $ImgW (-$ImgH)                      # top-down
Img-Pcx "OK.PCX"  ($ImgW-1) ($ImgH-1)
Img-Gif "OK.GIF"  8 (Img-Lzw $ImgPix 8)
Img-Bmp "HUGE.BMP" 65535 65535                         # header says 65535x65535, 100 data bytes
Img-Bmp "HUGETD.BMP" 65535 -65535                      # same, top-down
Img-Bmp "B24.BMP" $ImgW $ImgH 24                       # unsupported bpp
Img-Bmp "RLE.BMP" $ImgW $ImgH 8 1                      # unsupported compression
Img-Pcx "HUGE.PCX" 65533 65533 8 $false                # 65534x65534 (bpl 65534), 60 data bytes, no tail
Img-Pcx "P4.PCX"  ($ImgW-1) ($ImgH-1) 4                # 4 bpp -> reject
# GIF: literal, then code 300 while nextcode = 258 (9-bit codes)
Img-Gif "BIG.GIF" 8 (Img-Pack @(256, 65, 300, 257) @(9, 9, 9, 9))
# GIF: min code size 12
Img-Gif "MC12.GIF" 12 (Img-Pack @(4096, 1, 4097) @(13, 13, 13))
# GIF: first code after clear is a non-literal (259), then KwKwK on it -> the
#      old decoder unwound an uninitialised prefix[] chain (loop/overrun)
Img-Gif "LOOP.GIF" 8 (Img-Pack @(256, 258, 259, 260, 261, 257) @(9, 9, 9, 9, 9, 9))

# ---------- WAV fixtures -------------------------------------------------------
function Wav-Build([string]$name, [object[]]$chunks) {       # chunks: @(id, [byte[]]body, [long]sizeOverride or -1)
    $body = New-Object System.Collections.Generic.List[byte]
    $body.AddRange([byte[]](A4 "WAVE"))
    foreach ($c in $chunks) {
        $body.AddRange([byte[]](A4 $c[0]))
        $sz = if ($c[2] -ge 0) { $c[2] } else { $c[1].Length }
        $body.AddRange([byte[]](LE32 $sz))
        $body.AddRange([byte[]]$c[1])
        if (($c[1].Length % 2) -eq 1) { $body.Add([byte]0) }
    }
    $w = New-Object System.Collections.Generic.List[byte]
    $w.AddRange([byte[]](A4 "RIFF")); $w.AddRange([byte[]](LE32 $body.Count)); $w.AddRange($body.ToArray())
    [IO.File]::WriteAllBytes("$stage\$name", $w.ToArray())
}
function Wav-Fmt([int]$rate, [int]$ch, [int]$bits) {
    $ba = $ch * ($bits/8)
    return [byte[]]((LE16 1) + (LE16 $ch) + (LE32 $rate) + (LE32 ($rate*$ba)) + (LE16 $ba) + (LE16 $bits))
}
function Wav-Exp([int]$rate, [int]$ch, [int]$bits, [byte[]]$pcm) {
    return [byte[]]((LE32 $rate) + (LE16 $ch) + (LE16 $bits) + (LE32 $pcm.Length) + $pcm)
}
$WavA = [byte[]](0..49)
$WavB = New-Object System.Collections.Generic.List[byte]
for ($i=0; $i -lt 20; $i++) { $WavB.AddRange([byte[]](LE16 ((($i*1000) - 10000) -band 0xFFFF))); $WavB.AddRange([byte[]](LE16 ((5000 - ($i*500)) -band 0xFFFF))) }
$WavB = $WavB.ToArray()
Wav-Build "OK8.WAV"  @(@("fmt ", (Wav-Fmt 11025 1 8), -1), @("fact", [byte[]](0x11,0x22,0x33,0x44), -1), @("junk", [byte[]](0xAA,0xBB,0xCC), -1), @("data", $WavA, -1))
Wav-Build "OK16.WAV" @(@("fmt ", (Wav-Fmt 22050 2 16), -1), @("junk", [byte[]](1,2,3), -1), @("data", $WavB, -1))
# chunk whose size wraps the 32-bit position back to its own header
Wav-Build "WRAP.WAV" @(@("fmt ", (Wav-Fmt 11025 1 8), -1), @("junk", [byte[]](0,0,0,0), 0xFFFFFFF8L), @("data", $WavA, -1))
# odd size FFFFFFFF (+ pad byte wraps to 0)
Wav-Build "ODD.WAV"  @(@("fmt ", (Wav-Fmt 11025 1 8), -1), @("junk", [byte[]](0,0,0,0), 0xFFFFFFFFL), @("data", $WavA, -1))
# fmt chunk shorter than 16 bytes
Wav-Build "SFMT.WAV" @(@("fmt ", [byte[]]((LE16 1) + (LE16 1) + (LE32 11025)), -1), @("data", $WavA, -1))
# a long run of zero-size chunks, then EOF (no data chunk)
$WavZ = @(,@("fmt ", (Wav-Fmt 11025 1 8), -1)); for ($i=0; $i -lt 200; $i++) { $WavZ += ,@("zero", [byte[]]@(), -1) }
Wav-Build "ZERO.WAV" $WavZ
# chunk size far past EOF
Wav-Build "FAR.WAV"  @(@("fmt ", (Wav-Fmt 11025 1 8), -1), @("junk", [byte[]](0,0), 0x7FFFFFF0L))

# ---------- one DOSBox run ---------------------------------------------------
function Img-Case([string]$tag, [string]$cmd, [string]$raw) {
    $l = @("if exist $raw.RAW del $raw.RAW") + (Cmd-Lines $tag $cmd)
    $l += "if exist $raw.RAW ren $raw.RAW $tag.RAW"
    return $l
}
Get-ChildItem "$stage\I*.RAW","$stage\W*.RAW" -ErrorAction SilentlyContinue | Remove-Item -Force
$L  = @()
$L += Img-Case "IOB" "CCIMG.COM /D OK.BMP"      CCIMG
$L += Img-Case "ITD" "CCIMG.COM /D TD.BMP"      CCIMG
$L += Img-Case "IOP" "CCIMG.COM /D OK.PCX"      CCIMG
$L += Img-Case "IOG" "CCIMG.COM /D OK.GIF"      CCIMG
$L += Img-Case "IHB" "CCIMG.COM /D HUGE.BMP"    CCIMG
$L += Img-Case "IHT" "CCIMG.COM /D HUGETD.BMP"  CCIMG
$L += Img-Case "IB24" "CCIMG.COM /D B24.BMP"    CCIMG
$L += Img-Case "IRLE" "CCIMG.COM /D RLE.BMP"    CCIMG
$L += Img-Case "IHP" "CCIMG.COM /D HUGE.PCX"    CCIMG
$L += Img-Case "IP4" "CCIMG.COM /D P4.PCX"      CCIMG
$L += Img-Case "IBG" "CCIMG.COM /D BIG.GIF"     CCIMG
$L += Img-Case "IMC" "CCIMG.COM /D MC12.GIF"    CCIMG
$L += Img-Case "ILP" "CCIMG.COM /D LOOP.GIF"    CCIMG
# view mode (no /D): malformed input must fail before any mode switch/keywait
$L += Img-Case "IVG" "CCIMG.COM BIG.GIF"        CCIMG
$L += Img-Case "IVB" "CCIMG.COM B24.BMP"        CCIMG
$L += Img-Case "WO8" "CCWAV.COM /D OK8.WAV"     CCWAV
$L += Img-Case "WO16" "CCWAV.COM /D OK16.WAV"   CCWAV
$L += Img-Case "WWR" "CCWAV.COM /D WRAP.WAV"    CCWAV
$L += Img-Case "WOD" "CCWAV.COM /D ODD.WAV"     CCWAV
$L += Img-Case "WSF" "CCWAV.COM /D SFMT.WAV"    CCWAV
$L += Img-Case "WZR" "CCWAV.COM /D ZERO.WAV"    CCWAV
$L += Img-Case "WFR" "CCWAV.COM /D FAR.WAV"     CCWAV
$L += Img-Case "WVW" "CCWAV.COM WRAP.WAV"       CCWAV
# play with a bogus BLASTER DMA channel (D9 / trailing D): must fall back to D1
$L += "set BLASTER=A220 I7 D9 T6"
$L += Img-Case "WB9" "CCWAV.COM OK8.WAV"        CCWAV
$L += "set BLASTER=A220 I7 T6 D"
$L += Img-Case "WBE" "CCWAV.COM OK8.WAV"        CCWAV
$ok = Run-Dos "imgwav" $L 60000
Check "ccimg/ccwav batch terminated (no hang)" $ok

function Img-Raw([string]$tag) { $p = "$stage\$tag.RAW"; if (Test-Path $p) { return ,[IO.File]::ReadAllBytes($p) } else { return $null } }
function Img-Same($a, $b) { if ($null -eq $a -or $a.Length -ne $b.Length) { return $false }; for ($i=0; $i -lt $a.Length; $i++) { if ($a[$i] -ne $b[$i]) { return $false } }; return $true }

foreach ($t in @("IOB","ITD","IOP","IOG")) {
    Check "ccimg $t decodes byte-exact, rc 0" ((Img-Same (Img-Raw $t) $ImgExp) -and (Get-Rc $t) -eq 0) ("rc={0}" -f (Get-Rc $t))
}
foreach ($t in @("IHB","IHT","IHP")) {
    $o = Get-Out $t
    Check "ccimg $t truncated -> stops at EOF, rc 1 + message" ((Get-Rc $t) -eq 1 -and $o -match 'truncated') ("rc={0} out={1}" -f (Get-Rc $t), $o)
}
foreach ($t in @("IB24","IRLE","IP4","IBG","IMC","ILP","IVG","IVB")) {
    $o = Get-Out $t
    Check "ccimg $t rejected, rc 1 + message, no RAW" ((Get-Rc $t) -eq 1 -and $o -match 'CCIMG:' -and $null -eq (Img-Raw $t)) ("rc={0} out={1}" -f (Get-Rc $t), $o)
}
Check "ccwav WO8 byte-exact"  ((Img-Same (Img-Raw "WO8")  (Wav-Exp 11025 1 8 $WavA))  -and (Get-Rc "WO8") -eq 0)  ("rc={0}" -f (Get-Rc "WO8"))
Check "ccwav WO16 byte-exact" ((Img-Same (Img-Raw "WO16") (Wav-Exp 22050 2 16 $WavB)) -and (Get-Rc "WO16") -eq 0) ("rc={0}" -f (Get-Rc "WO16"))
foreach ($t in @("WWR","WOD","WSF","WZR","WFR","WVW")) {
    $o = Get-Out $t
    Check "ccwav $t rejected, rc 1 + message" ((Get-Rc $t) -eq 1 -and $o -match 'CCWAV:') ("rc={0} out={1}" -f (Get-Rc $t), $o)
}
foreach ($t in @("WB9","WBE")) { Check "ccwav $t bogus BLASTER D -> plays, rc 0" ((Get-Rc $t) -eq 0) ("rc={0}" -f (Get-Rc $t)) }
}

# ============================================================================
# each suite runs in its own child scope so its variables can't collide
& {
# ---- CCFIND / CCGREP / CCSUM / CCDIFF ---------------------------------------
Write-Host "== find / grep / sum / diff =="
$null = Build-One cfind CCFIND
$null = Build-One cgrep CCGREP
$null = Build-One csum  CCSUM
$null = Build-One cdiff CCDIFF

# QT: 700 dirs, each with a subdir S holding F.TXT. Level-1 paths "C:\QT\DIR00001.EXT"
# (19 bytes queued) + level-2 "C:\QT\DIR00001.EXT\S" (21) = 28 KB in total: more
# than the 16 KB queue, so this only finds all 700 if dequeued space is reclaimed.
$qt = "$stage\QT"
if (Test-Path $qt) { Remove-Item $qt -Recurse -Force }
New-Item -ItemType Directory -Path $qt | Out-Null
$FindN = 700
for ($i = 1; $i -le $FindN; $i++) {
    $d = "$qt\DIR{0:D5}.EXT\S" -f $i
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    [IO.File]::WriteAllText("$d\F.TXT", "line one`r`nthe needle is here`r`n")
}
[IO.File]::WriteAllText("$qt\README",   "readme`r`nanother needle`r`n")
[IO.File]::WriteAllText("$qt\MAKEFILE", "all:`r`n")
[IO.File]::WriteAllText("$qt\A.TXT",    "a`r`n")
# QS: 900 sibling dirs = 17 KB of pending paths -> must drop some, and the
# warning must NOT land in stdout (cc parses every stdout line as a hit).
$qs = "$stage\QS"
if (-not (Test-Path "$qs\DIR00900.EXT")) {
    for ($i = 1; $i -le 900; $i++) { New-Item -ItemType Directory -Path ("$qs\DIR{0:D5}.EXT" -f $i) -Force | Out-Null }
}
[IO.File]::WriteAllBytes("$stage\A.BIN", [byte[]](1,2,3,4,5))
[IO.File]::WriteAllBytes("$stage\B.BIN", [byte[]](1,2,3,9,5))
[IO.File]::WriteAllBytes("$stage\C.BIN", [byte[]](1,2,3))
[IO.File]::WriteAllBytes("$stage\E.BIN", [System.Text.Encoding]::ASCII.GetBytes("123456789"))

$lines  = @()
$lines += Cmd-Lines FQ   "CCFIND.COM F.TXT C:\QT"
$lines += Cmd-Lines FS   "CCFIND.COM *.* C:\QT"
$lines += Cmd-Lines FL   "CCFIND.COM ************************************F.TXT C:\QT"
$lines += Cmd-Lines FK   "CCFIND.COM *.* C:\QS"
$lines += Cmd-Lines GQ   "CCGREP.COM needle C:\QT"
$lines += Cmd-Lines GN   "CCGREP.COM zqxjzq C:\QT"
$lines += Cmd-Lines SE   "CCSUM.COM E.BIN"
$lines += Cmd-Lines SX   "CCSUM.COM NOPE.BIN"
$lines += Cmd-Lines DS   "CCDIFF.COM A.BIN A.BIN"
$lines += Cmd-Lines DD   "CCDIFF.COM A.BIN B.BIN"
$lines += Cmd-Lines DL   "CCDIFF.COM A.BIN C.BIN"
$lines += Cmd-Lines DX   "CCDIFF.COM A.BIN NOPE.BIN"
$ok = Run-Dos findgrep $lines 60000
Check "find/grep/sum/diff batch terminates" $ok

function FindRows([string]$tag) {
    $o = Get-Out $tag
    if ($null -eq $o) { return @() }
    return @($o -split "`r?`n" | Where-Object { $_ -ne '' })
}
$r = FindRows FQ
Check "CCFIND reclaims queue space: all $FindN F.TXT found" ($r.Count -eq $FindN) "got $($r.Count)"
Check "CCFIND rows are full paths" (@($r | Where-Object { $_ -notmatch '^C:\\QT\\DIR\d{5}\.EXT\\S\\F\.TXT$' }).Count -eq 0)
$r = FindRows FS
Check "CCFIND *.* matches extensionless README"   (@($r | Where-Object { $_ -eq 'C:\QT\README' }).Count -eq 1)
Check "CCFIND *.* matches extensionless MAKEFILE" (@($r | Where-Object { $_ -eq 'C:\QT\MAKEFILE' }).Count -eq 1)
Check "CCFIND *.* still matches A.TXT"            (@($r | Where-Object { $_ -eq 'C:\QT\A.TXT' }).Count -eq 1)
$r = FindRows FL
Check "CCFIND long (41-char) pattern not truncated / no overrun" ($r.Count -eq $FindN) "got $($r.Count)"
$r = FindRows FK
Check "CCFIND queue overflow: terminates, rc 0" ((Get-Rc FK) -eq 0) "rc=$(Get-Rc FK)"
Check "CCFIND overflow warning kept off stdout" (@($r | Where-Object { $_ -notmatch '^C:\\QS\\' }).Count -eq 0) "rows: $($r -join ' | ')"
$r = FindRows GQ
Check "CCGREP finds needle in all F.TXT + README" ($r.Count -eq ($FindN + 1)) "got $($r.Count)"
Check "CCGREP README hit uses the default *.* mask" (@($r | Where-Object { $_ -eq 'C:\QT\README:2:another needle' }).Count -eq 1)
Check "CCGREP rc 0 when matched" ((Get-Rc GQ) -eq 0) "rc=$(Get-Rc GQ)"
Check "CCGREP rc 1 when no match" ((Get-Rc GN) -eq 1) "rc=$(Get-Rc GN)"
Check "CCGREP no-match output empty" ((FindRows GN).Count -eq 0)
Check "CCSUM crc32('123456789') = CBF43926" ((Get-Out SE) -match '^CBF43926  9  E\.BIN') "out=$(Get-Out SE)"
Check "CCSUM rc 0 / missing file rc 1" (((Get-Rc SE) -eq 0) -and ((Get-Rc SX) -eq 1)) "rc=$(Get-Rc SE)/$(Get-Rc SX)"
Check "CCDIFF identical -> rc 0" (((Get-Rc DS) -eq 0) -and ((Get-Out DS) -match 'identical')) "rc=$(Get-Rc DS)"
Check "CCDIFF byte differs -> rc 1" (((Get-Rc DD) -eq 1) -and ((Get-Out DD) -match 'differ at offset 3: 04 vs 09')) "rc=$(Get-Rc DD) out=$(Get-Out DD)"
Check "CCDIFF length differs -> rc 1" (((Get-Rc DL) -eq 1) -and ((Get-Out DL) -match 'offset 3 \(lengths differ\)')) "rc=$(Get-Rc DL) out=$(Get-Out DL)"
Check "CCDIFF missing file -> rc 2" ((Get-Rc DX) -eq 2) "rc=$(Get-Rc DX)"
}

if ($script:fails -gt 0) { Write-Host ("FAIL: {0} check(s) failed" -f $script:fails); exit 1 }
Write-Host "PASS: all parser safety checks passed"
exit 0
