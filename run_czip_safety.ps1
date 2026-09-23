# run_czip_safety.ps1 -- safety regression gate for the archive helpers CCZIP
# (czip.asm) and CCPAK (cpak.asm).
#
# Everything (build output, fixtures, DOSBox confs, captures) lives under
# $env:TEMP\cc_czip_safety -- nothing is written to the repo, so this can run
# concurrently with the other run_*.ps1 tests. Fixtures are generated here
# (System.IO.Compression for real-world zips, hand-built bytes for malformed
# ones); each DOS case records its exit code ("<case> EL=0|1" in R.TXT) and
# the host side then checks files / listings.
#
# Cases: path-traversal members ("../", "..\", "a/../../", "...", "C:") never
# written outside the destination and exit 1, while safe members (incl. a
# leading "/" or "\") still extract; multi-member deflated zip XA/X extracts
# every member byte-identical (INFLATE window must not clobber the central
# directory); L listing keeps the "<size> <name>" format cc parses; a huge
# namelen / 300-char name listing terminates cleanly; corrupt deflate data
# (00 00 00 FF FF stall, truncated stream, bad NLEN, BTYPE 3) and an
# encrypted member terminate with an error and leave no partial files; AP
# keeps the old members (also with a short zip comment), refuses an archive
# whose EOCD it cannot find (long comment / junk) instead of recreating it,
# and creates a missing archive; CCPAK traversal, unterminated 56-byte names,
# and the >512-entry truncation warning.
# Exit 0 = PASS, 1 = FAIL.
$ErrorActionPreference = "Stop"
$dir  = "C:\LLM\DOS\cc"
$dbox = "$dir\dbstaging\dosbox-staging-v0.82.2\dosbox.exe"
$nasm = "C:\Users\Caldor\AppData\Local\bin\NASM\nasm.exe"
if (-not (Test-Path $nasm)) { $nasm = "nasm" }
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$root = Join-Path $env:TEMP "cc_czip_safety"
$w    = "$root\w"                       # mounted as C: inside DOSBox
if (Test-Path $root) { Remove-Item $root -Recurse -Force }
New-Item -ItemType Directory -Path "$w\T" -Force | Out-Null
New-Item -ItemType Directory -Path "$w\OUT" -Force | Out-Null

# ---- build (straight into the staging dir) ---------------------------------
foreach ($t in @(@("czip","CCZIP"), @("cpak","CCPAK"))) {
    & $nasm -f bin -i "$dir/" "$dir\$($t[0]).asm" -o "$w\T\$($t[1]).COM" 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Host "ASSEMBLE FAILED: $($t[0]).asm"; exit 1 }
}
Write-Host ("BUILD OK: CCZIP {0} B, CCPAK {1} B -> {2}" -f (Get-Item "$w\T\CCZIP.COM").Length, (Get-Item "$w\T\CCPAK.COM").Length, "$w\T")

# ---- helpers ----------------------------------------------------------------
$rng = New-Object System.Random 4711
function RandBytes([int]$n) { $b = New-Object byte[] $n; $rng.NextBytes($b); return ,$b }
function Ascii([string]$s) { return ,[Text.Encoding]::ASCII.GetBytes($s) }
$words = "alpha beta gamma delta epsilon zeta theta kappa lambda omicron sigma omega quake doom zip pak".Split(' ')
function TextBytes([int]$n) {
    $sb = New-Object System.Text.StringBuilder
    while ($sb.Length -lt $n) {
        [void]$sb.Append($words[$rng.Next($words.Count)])
        if ($rng.Next(12) -eq 0) { [void]$sb.Append("`r`n") } else { [void]$sb.Append(' ') }
    }
    return ,[Text.Encoding]::ASCII.GetBytes($sb.ToString().Substring(0, $n))
}
function RawDeflate([byte[]]$b) {
    $ms = New-Object IO.MemoryStream
    $ds = New-Object IO.Compression.DeflateStream($ms, [IO.Compression.CompressionLevel]::Optimal, $true)
    $ds.Write($b, 0, $b.Length); $ds.Dispose()
    return ,$ms.ToArray()
}
function Put([string]$rel, [byte[]]$data) {
    $p = Join-Path $w $rel
    New-Item -ItemType Directory -Path (Split-Path $p) -Force | Out-Null
    [IO.File]::WriteAllBytes($p, $data)
}
function SameBytes([string]$rel, [byte[]]$exp) {
    $p = Join-Path $w $rel
    if (-not (Test-Path $p)) { return $false }
    $got = [IO.File]::ReadAllBytes($p)
    if ($got.Length -ne $exp.Length) { return $false }
    for ($i = 0; $i -lt $got.Length; $i++) { if ($got[$i] -ne $exp[$i]) { return $false } }
    return $true
}
function Exists([string]$rel) { Test-Path (Join-Path $w $rel) }

# Hand-built zip: entries are hashtables  N=name M=method F=flags D=data
# U=usize (default D.Length) NL=namelen override (central directory only).
# CRCs are left 0 (CCZIP does not check them).
function New-RawZip([string]$rel, [object[]]$ents) {
    $ms = New-Object IO.MemoryStream
    $bw = New-Object IO.BinaryWriter($ms)
    $offs = @()
    foreach ($e in $ents) {
        $nb = [Text.Encoding]::ASCII.GetBytes($e.N)
        $u  = if ($e.ContainsKey('U')) { $e.U } else { $e.D.Length }
        $offs += [uint32]$ms.Position
        $bw.Write([uint32]0x04034b50); $bw.Write([uint16]20); $bw.Write([uint16]$e.F); $bw.Write([uint16]$e.M)
        $bw.Write([uint16]0); $bw.Write([uint16]0x21); $bw.Write([uint32]0)
        $bw.Write([uint32]$e.D.Length); $bw.Write([uint32]$u)
        $bw.Write([uint16]$nb.Length); $bw.Write([uint16]0); $bw.Write($nb); $bw.Write([byte[]]$e.D)
    }
    $cdofs = [uint32]$ms.Position
    for ($i = 0; $i -lt $ents.Count; $i++) {
        $e = $ents[$i]
        $nb = [Text.Encoding]::ASCII.GetBytes($e.N)
        $u  = if ($e.ContainsKey('U')) { $e.U } else { $e.D.Length }
        $nl = if ($e.ContainsKey('NL')) { $e.NL } else { $nb.Length }
        $bw.Write([uint32]0x02014b50); $bw.Write([uint16]20); $bw.Write([uint16]20); $bw.Write([uint16]$e.F); $bw.Write([uint16]$e.M)
        $bw.Write([uint16]0); $bw.Write([uint16]0x21); $bw.Write([uint32]0)
        $bw.Write([uint32]$e.D.Length); $bw.Write([uint32]$u)
        $bw.Write([uint16]$nl); $bw.Write([uint16]0); $bw.Write([uint16]0); $bw.Write([uint16]0); $bw.Write([uint16]0)
        $bw.Write([uint32]0); $bw.Write([uint32]$offs[$i]); $bw.Write($nb)
    }
    $cdsize = [uint32]($ms.Position - $cdofs)
    $bw.Write([uint32]0x06054b50); $bw.Write([uint16]0); $bw.Write([uint16]0)
    $bw.Write([uint16]$ents.Count); $bw.Write([uint16]$ents.Count); $bw.Write($cdsize); $bw.Write($cdofs); $bw.Write([uint16]0)
    $bw.Flush()
    Put $rel $ms.ToArray()
}
# Real-world zip via System.IO.Compression (deflated members). $members is an
# ordered name->bytes map; a name ending in '/' becomes a directory entry.
function New-NetZipBytes($members) {
    $ms = New-Object IO.MemoryStream
    $za = New-Object IO.Compression.ZipArchive($ms, [IO.Compression.ZipArchiveMode]::Create, $true)
    foreach ($k in $members.Keys) {
        $e = $za.CreateEntry($k, [IO.Compression.CompressionLevel]::Optimal)
        $s = $e.Open(); $d = [byte[]]$members[$k]; $s.Write($d, 0, $d.Length); $s.Dispose()
    }
    $za.Dispose()
    return ,$ms.ToArray()
}
# Hand-built PAK: $ents = @(@(name, [byte[]]data), ...); a 56-char name gets
# no NUL terminator, exactly as the format allows.
function New-Pak([string]$rel, [object[]]$ents) {
    $ms = New-Object IO.MemoryStream
    $bw = New-Object IO.BinaryWriter($ms)
    $bw.Write([Text.Encoding]::ASCII.GetBytes("PACK")); $bw.Write([uint32]0); $bw.Write([uint32]0)
    $pos = @()
    foreach ($e in $ents) { $pos += [uint32]$ms.Position; $bw.Write([byte[]]$e[1]) }
    $dirofs = [uint32]$ms.Position
    for ($i = 0; $i -lt $ents.Count; $i++) {
        $nm = New-Object byte[] 56
        $nb = [Text.Encoding]::ASCII.GetBytes($ents[$i][0]); [Array]::Copy($nb, $nm, [Math]::Min(56, $nb.Length))
        $bw.Write($nm); $bw.Write($pos[$i]); $bw.Write([uint32]$ents[$i][1].Length)
    }
    $dirlen = [uint32]($ms.Position - $dirofs)
    $bw.Flush()
    $b = $ms.ToArray()
    [BitConverter]::GetBytes($dirofs).CopyTo($b, 4); [BitConverter]::GetBytes($dirlen).CopyTo($b, 8)
    Put $rel $b
}

$bat = New-Object System.Collections.Generic.List[string]
function Run([string]$name, [string]$cmd) {
    $bat.Add("$cmd > C:\OUT\$name.TXT")
    $bat.Add("if errorlevel 1 echo $name EL=1 >> C:\R.TXT")
    $bat.Add("if not errorlevel 1 echo $name EL=0 >> C:\R.TXT")
}
# one DOSBox session over the current $bat; returns $true if it exited by itself
function Invoke-Dos([string]$tag, [int]$timeoutMs) {
    $bat.Add("echo DONE-$tag >> C:\R.TXT")
    $conf = @"
[sdl]
fullscreen = false
[cpu]
core    = normal
cputype = 486
cycles  = max
[autoexec]
@echo off
mount c $w
c:
$($bat -join "`r`n")
rem DOSBox-staging blocks EXIT right after a quick program ("Exit blocked
rem because program quit after only N seconds"): idle 3 s so it really exits.
choice /t:y,3 /c:yn > nul
exit
"@
    $confPath = "$root\run_czip_safety_$tag.conf"
    Set-Content -Path $confPath -Value $conf -Encoding ASCII
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process -FilePath $dbox -ArgumentList @("-conf",$confPath,"-noprimaryconf") -PassThru -WindowStyle Minimized -WorkingDirectory $root
    $ok = $p.WaitForExit($timeoutMs)
    if (-not $ok) { $p.Kill() | Out-Null; Write-Host "WARNING: DOSBox session '$tag' timed out after $timeoutMs ms (a helper hung?)" }
    else { Write-Host ("DOSBox session '{0}' finished in {1:N1} s" -f $tag, $sw.Elapsed.TotalSeconds) }
    Start-Sleep -Milliseconds 400
    $bat.Clear()
    return $ok
}

# ---- stage inputs + build the DOS script ------------------------------------
# A. CCZIP path traversal (hand-built: exact names, stored + deflated)
$good = Ascii "good data"; $abs = Ascii "abs data"; $lead = Ascii "lead data"; $fine = TextBytes 3000
New-RawZip "TRAV.ZIP" @(
    @{N="../EVIL1.TXT"; M=0; D=(Ascii "evil1")},
    @{N="..\EVIL2.TXT"; M=0; D=(Ascii "evil2")},
    @{N="SUB/../../EVIL3.TXT"; M=0; D=(Ascii "evil3")},
    @{N="C:EVIL4.TXT"; M=0; D=(Ascii "evil4")},
    @{N=".../EVIL5.TXT"; M=0; D=(Ascii "evil5")},
    @{N="../EVILD.TXT"; M=8; D=(RawDeflate (TextBytes 2000)); U=2000},
    @{N="GOOD.TXT"; M=0; D=$good},
    @{N="/ABS.TXT"; M=0; D=$abs},
    @{N="\LEAD.TXT"; M=0; D=$lead},
    @{N="OK/FINE.TXT"; M=8; D=(RawDeflate $fine); U=$fine.Length}
)
New-Item -ItemType Directory -Path "$w\D1\D2" -Force | Out-Null
New-Item -ItemType Directory -Path "$w\D3\D4" -Force | Out-Null
Run "TRAVXA" "C:\T\CCZIP.COM XA TRAV.ZIP C:\D1\D2"
Run "TRAVX0" "C:\T\CCZIP.COM X TRAV.ZIP 0 C:\D3\D4"
Run "TRAVX6" "C:\T\CCZIP.COM X TRAV.ZIP 6 C:\D3\D4"

# B. multi-member deflated zip (System.IO.Compression) -- XA must get them all
$m = [ordered]@{
    "M1.TXT"     = (TextBytes 70000)        # > 32K: window wraps
    "M2.BIN"     = (RandBytes 20000)        # incompressible -> stored blocks
    "M3.TXT"     = (Ascii "hello multi")
    "SUB/"       = (New-Object byte[] 0)    # directory entry (skipped)
    "SUB/M4.TXT" = (TextBytes 40000)
    "M5.TXT"     = (Ascii "fifth")
    "EMPTY.TXT"  = (New-Object byte[] 0)
}
Put "MULTI.ZIP" (New-NetZipBytes $m)
Run "MULTIXA" "C:\T\CCZIP.COM XA MULTI.ZIP C:\MOUT"
Run "MULTIX3" "C:\T\CCZIP.COM X MULTI.ZIP 3 C:\XOUT"
Run "MULTIL"  "C:\T\CCZIP.COM L MULTI.ZIP"
Run "MULTIH"  "C:\T\CCZIP.COM MULTI.ZIP"

# C. listing bounds: 300-char name (display-truncated) then namelen FFFFh
$longName = ("L" * 296) + ".TXT"
New-RawZip "HUGE.ZIP" @(
    @{N="FIRST.TXT"; M=0; D=(Ascii "first")},
    @{N=$longName; M=0; D=(Ascii "long")},
    @{N="HUGE.TXT"; M=0; D=(Ascii "huge"); NL=0xFFFF},
    @{N="AFTER.TXT"; M=0; D=(Ascii "after")}
)
Run "HUGEL"  "C:\T\CCZIP.COM L HUGE.ZIP"
Run "HUGEH"  "C:\T\CCZIP.COM HUGE.ZIP"
Run "HUGEXA" "C:\T\CCZIP.COM XA HUGE.ZIP C:\HOUT"

# D. AP (append)
$old1 = TextBytes 3000; $old2 = Ascii "old two"; $new1 = Ascii "new one data"
$base = New-NetZipBytes ([ordered]@{ "OLD1.TXT" = $old1; "OLD2.TXT" = $old2 })
function WithComment([byte[]]$zip, [int]$n) {
    $b = New-Object byte[] ($zip.Length + $n)
    [Array]::Copy($zip, $b, $zip.Length)
    [BitConverter]::GetBytes([uint16]$n).CopyTo($b, $zip.Length - 2)
    for ($i = 0; $i -lt $n; $i++) { $b[$zip.Length + $i] = 0x78 }   # 'x'
    return ,$b
}
Put "APOK.ZIP" $base
$apcmt = WithComment $base 1000;  Put "APCMT.ZIP" $apcmt
$apbig = WithComment $base 5000;  Put "APBIG.ZIP" $apbig      # EOCD beyond the 4K tail scan
$apgarb = RandBytes 3000;          Put "APGARB.ZIP" $apgarb    # no EOCD at all
Put "APSRC\NEW1.TXT" $new1
Put "AP.LST" (Ascii "C:\APSRC\NEW1.TXT`r`n")
Run "APOK"   "C:\T\CCZIP.COM AP APOK.ZIP @AP.LST"
Run "APOKL"  "C:\T\CCZIP.COM L APOK.ZIP"
Run "APCMT"  "C:\T\CCZIP.COM AP APCMT.ZIP @AP.LST"
Run "APBIG"  "C:\T\CCZIP.COM AP APBIG.ZIP @AP.LST"
Run "APGARB" "C:\T\CCZIP.COM AP APGARB.ZIP @AP.LST"
Run "APNEW"  "C:\T\CCZIP.COM AP APNEW.ZIP @AP.LST"
Run "APNEWL" "C:\T\CCZIP.COM L APNEW.ZIP"

# E. CCPAK traversal + unterminated 56-byte name + truncation warning
$name56 = "AAAAAAAA/BBBBBBBB/CCCCCCCC/DDDDDDDD/EEEEEEEE/FFFFFFF.TXT"
if ($name56.Length -ne 56) { Write-Host "fixture bug: name56 is $($name56.Length) chars"; exit 1 }
$pgood = Ascii "pak good"; $pabs = Ascii "pak abs"; $p56 = Ascii "fifty-six"
New-Pak "PTRAV.PAK" @(
    @("../EVIL6.TXT", (Ascii "evil6")),
    @("maps/../../EVIL7.TXT", (Ascii "evil7")),
    @("C:EVIL8.TXT", (Ascii "evil8")),
    @("progs/good.txt", $pgood),
    @("/abs.txt", $pabs),
    @($name56, $p56)
)
New-Item -ItemType Directory -Path "$w\P1\P2" -Force | Out-Null
Run "PAKXA" "C:\T\CCPAK.COM XA PTRAV.PAK C:\P1\P2"
Run "PAKX0" "C:\T\CCPAK.COM X PTRAV.PAK 0 C:\P1\P2"
Run "PAKL"  "C:\T\CCPAK.COM L PTRAV.PAK"
$bigents = @(); for ($i = 0; $i -lt 513; $i++) { $bigents += ,@(("F{0:D3}.TXT" -f $i), [byte[]]@([byte]65)) }
New-Pak "BIG.PAK" $bigents
Run "PAKBIGH" "C:\T\CCPAK.COM BIG.PAK"
Run "PAKBIGL" "C:\T\CCPAK.COM L BIG.PAK"

# G. never overwrite: X / XA onto existing files -> NAME~n (base cut to 6,
#    extension kept); all of NAME + NAME~1..~9 taken -> that member fails
$keep = Ascii "KEEP"
Put "OV1\M3.TXT" $keep                                  # stored member
Put "OV1\M1.TXT" $keep                                  # deflated member
Run "OVZX3" "C:\T\CCZIP.COM X MULTI.ZIP 2 C:\OV1"
Run "OVZX0" "C:\T\CCZIP.COM X MULTI.ZIP 0 C:\OV1"
Put "OV2\M5.TXT" $keep
Put "OV2\SUB\M4.TXT" $keep
Run "OVZXA" "C:\T\CCZIP.COM XA MULTI.ZIP C:\OV2"
$lname = Ascii "long name"; $noext = Ascii "no ext"; $full = Ascii "full"; $after = Ascii "after"
New-RawZip "OVW.ZIP" @(
    @{N="LONGNAME.TXT"; M=0; D=$lname},
    @{N="NOEXT"; M=0; D=$noext},
    @{N="FULL.TXT"; M=0; D=$full},
    @{N="AFTER.TXT"; M=0; D=$after}
)
Put "OV3\LONGNAME.TXT" $keep; Put "OV3\LONGNA~1.TXT" $keep  # ~1 taken too -> ~2
Put "OV3\NOEXT" $keep
Put "OV3\FULL.TXT" $keep; for ($i = 1; $i -le 9; $i++) { Put "OV3\FULL~$i.TXT" $keep }
Run "OVWXA" "C:\T\CCZIP.COM XA OVW.ZIP C:\OV3"
Run "OVWX2" "C:\T\CCZIP.COM X OVW.ZIP 2 C:\OV3"
Put "OV4\PROGS\GOOD.TXT" $keep
Run "OVPX3" "C:\T\CCPAK.COM X PTRAV.PAK 3 C:\OV4"
Put "OV5\PROGS\GOOD.TXT" $keep; for ($i = 1; $i -le 9; $i++) { Put "OV5\PROGS\GOOD~$i.TXT" $keep }
Run "OVPXF" "C:\T\CCPAK.COM X PTRAV.PAK 3 C:\OV5"

$mainOk = Invoke-Dos "main" 90000

# F. corrupt / hostile deflate data -- its own session: the old code spun forever
$tfull = RawDeflate (TextBytes 20000)
$ttrunc = New-Object byte[] ([int]($tfull.Length * 0.4)); [Array]::Copy($tfull, $ttrunc, $ttrunc.Length)
New-RawZip "BAD.ZIP" @(
    @{N="STALL.BIN"; M=8; D=[byte[]](0,0,0,0xFF,0xFF); U=0},              # empty non-final stored block, then EOF
    @{N="TRUNC.BIN"; M=8; D=$ttrunc; U=20000},                              # stream cut at 40%
    @{N="NLEN.BIN";  M=8; D=[byte[]](1,5,0,0,0,65,66,67,68,69); U=5},       # stored LEN=5, NLEN=0
    @{N="RESV.BIN";  M=8; D=[byte[]](7,0); U=0},                            # BTYPE 3
    @{N="ENC.BIN";   M=0; F=1; D=(Ascii "secret"); U=6},                    # encrypted flag
    @{N="GOOD.TXT";  M=0; D=$good}
)
Run "BADXA" "C:\T\CCZIP.COM XA BAD.ZIP C:\BOUT"
Run "BADX0" "C:\T\CCZIP.COM X BAD.ZIP 0 C:\B0OUT"
$badOk = Invoke-Dos "corrupt" 30000

# ---- verdicts -----------------------------------------------------------------
if (-not (Test-Path "$w\R.TXT")) { Write-Host "FAIL: no R.TXT produced"; exit 1 }
$r = Get-Content "$w\R.TXT" -Raw
$el = @{}
foreach ($mm in [regex]::Matches($r, '(?m)^(\S+) EL=(\d)')) { $el[$mm.Groups[1].Value] = [int]$mm.Groups[2].Value }
function Out1([string]$name) { $f = "$w\OUT\$name.TXT"; if (Test-Path $f) { ([string](Get-Content $f -Raw)) -replace '\s+$','' } else { "<none>" } }
function Lines([string]$name) { $f = "$w\OUT\$name.TXT"; if (Test-Path $f) { @(Get-Content $f | Where-Object { $_ -ne "" }) } else { @() } }
function Count([string]$text, [string]$pat) { [regex]::Matches($text, $pat).Count }

$script:pass = 0; $script:fail = 0
function Check([string]$name, [bool]$cond, [string]$detail = "") {
    if ($cond) { Write-Host ("  PASS  {0}" -f $name); $script:pass++ }
    else       { Write-Host ("  FAIL  {0}  {1}" -f $name, $detail); $script:fail++ }
}
function EL([string]$case, [int]$want) {
    $got = if ($el.ContainsKey($case)) { $el[$case] } else { -1 }
    Check "$case exit=$want" ($got -eq $want) ("(got {0}; out: {1})" -f $got, (Out1 $case))
}
$evil = @(Get-ChildItem -Path $w -Recurse -File -Filter "EVIL*")

Write-Host "`n--- CCZIP: path traversal ---"
EL "TRAVXA" 1
Check "no EVIL* file anywhere under the staging root" ($evil.Count -eq 0) (($evil | ForEach-Object { $_.FullName }) -join ", ")
Check "6 unsafe members reported" ((Count (Out1 "TRAVXA") 'unsafe name skipped') -eq 6) ("out: " + (Out1 "TRAVXA"))
Check "GOOD.TXT extracted" (SameBytes "D1\D2\GOOD.TXT" $good)
Check "'/ABS.TXT' -> D1\D2\ABS.TXT" (SameBytes "D1\D2\ABS.TXT" $abs)
Check "'\LEAD.TXT' -> D1\D2\LEAD.TXT" (SameBytes "D1\D2\LEAD.TXT" $lead)
Check "deflated OK/FINE.TXT sub-dir member byte-identical" (SameBytes "D1\D2\OK\FINE.TXT" $fine)
EL "TRAVX0" 1
EL "TRAVX6" 0; Check "X of a safe member still works" (SameBytes "D3\D4\GOOD.TXT" $good)
Write-Host ("  msg: " + ((Out1 "TRAVXA") -split "`r`n")[0])

Write-Host "`n--- CCZIP: multi-member deflated XA / X / L ---"
EL "MULTIXA" 0
foreach ($k in $m.Keys) {
    if ($k.EndsWith("/")) { continue }
    Check "XA $k byte-identical ($($m[$k].Length) B)" (SameBytes ("MOUT\" + $k.Replace('/','\')) ([byte[]]$m[$k]))
}
EL "MULTIX3" 0; Check "X 3 -> SUB\M4.TXT byte-identical" (SameBytes "XOUT\SUB\M4.TXT" ([byte[]]$m["SUB/M4.TXT"]))
EL "MULTIL" 0
$wantL = @("70000 M1.TXT", "20000 M2.BIN", "11 M3.TXT", "40000 SUB/M4.TXT", "5 M5.TXT", "0 EMPTY.TXT")
$gotL = @(Lines "MULTIL")
Check "L output is exactly the '<size> <name>' lines cc parses" (($gotL -join "|") -eq ($wantL -join "|")) ("got: " + ($gotL -join " | "))
EL "MULTIH" 0; Check "human listing has 7 lines incl. the dir entry" (@(Lines "MULTIH").Count -eq 7)

Write-Host "`n--- CCZIP: listing bounds ---"
EL "HUGEL" 0
$hl = @(Lines "HUGEL")
Check "L: FIRST.TXT listed" ($hl.Count -ge 1 -and $hl[0] -eq "5 FIRST.TXT") ("got: " + ($hl -join " | "))
Check "L: 300-char name truncated to 128 chars" ($hl.Count -ge 2 -and $hl[1] -eq ("4 " + $longName.Substring(0,128)))
Check "L: walk stops at the namelen=FFFFh entry (2 lines)" ($hl.Count -eq 2) ("got {0} lines" -f $hl.Count)
EL "HUGEH" 0; Check "human listing: 2 lines" (@(Lines "HUGEH").Count -eq 2)
Check "XA on HUGE.ZIP: FIRST.TXT extracted, walk bounded" (SameBytes "HOUT\FIRST.TXT" (Ascii "first"))

Write-Host "`n--- CCZIP: AP (append) ---"
function ZipEntries([string]$rel) {
    try {
        $za = [IO.Compression.ZipFile]::OpenRead((Join-Path $w $rel))
        $h = [ordered]@{}
        foreach ($e in $za.Entries) {
            $s = $e.Open(); $ms = New-Object IO.MemoryStream; $s.CopyTo($ms); $s.Dispose()
            $h[$e.FullName] = $ms.ToArray()
        }
        $za.Dispose(); return $h
    } catch { return $null }
}
function SameArr([byte[]]$a, [byte[]]$b) { if ($null -eq $a -or $null -eq $b -or $a.Length -ne $b.Length) { return $false }; for ($i=0;$i -lt $a.Length;$i++){ if ($a[$i] -ne $b[$i]) { return $false } }; return $true }
function EocdAtEnd([string]$rel) { $b = [IO.File]::ReadAllBytes((Join-Path $w $rel)); $n = $b.Length; return ($n -ge 22 -and $b[$n-22] -eq 0x50 -and $b[$n-21] -eq 0x4B -and $b[$n-20] -eq 5 -and $b[$n-19] -eq 6 -and $b[$n-2] -eq 0 -and $b[$n-1] -eq 0) }
EL "APOK" 0
Check "L after AP lists old + new" (((Lines "APOKL") -join "|") -eq "3000 OLD1.TXT|7 OLD2.TXT|12 NEW1.TXT") ("got: " + ((Lines "APOKL") -join " | "))
$zo = ZipEntries "APOK.ZIP"
Check "APOK.ZIP opens in .NET with old + new content intact" ($null -ne $zo -and $zo.Count -eq 3 -and (SameArr $zo["OLD1.TXT"] $old1) -and (SameArr $zo["OLD2.TXT"] $old2) -and (SameArr $zo["NEW1.TXT"] $new1))
EL "APCMT" 0
$zc = ZipEntries "APCMT.ZIP"
Check "short-comment zip: 3 intact members after AP" ($null -ne $zc -and $zc.Count -eq 3 -and (SameArr $zc["OLD1.TXT"] $old1) -and (SameArr $zc["NEW1.TXT"] $new1))
Check "short-comment zip: file truncated after the new EOCD (old tail gone)" (EocdAtEnd "APCMT.ZIP")
EL "APBIG" 1; Check "EOCD not found (5000-B comment): archive left byte-identical" (SameBytes "APBIG.ZIP" $apbig)
EL "APGARB" 1; Check "junk file: left byte-identical, not recreated" (SameBytes "APGARB.ZIP" $apgarb)
Write-Host ("  msg: " + (Out1 "APBIG"))
EL "APNEW" 0; Check "missing archive is created" (((Lines "APNEWL") -join "|") -eq "12 NEW1.TXT")

Write-Host "`n--- CCPAK ---"
EL "PAKXA" 1
Check "3 unsafe entries reported" ((Count (Out1 "PAKXA") 'unsafe name skipped') -eq 3) ("out: " + (Out1 "PAKXA"))
Check "progs/good.txt extracted" (SameBytes "P1\P2\PROGS\GOOD.TXT" $pgood)
Check "'/abs.txt' -> P1\P2\ABS.TXT" (SameBytes "P1\P2\ABS.TXT" $pabs)
Check "unterminated 56-byte name extracted to its exact path" (SameBytes ("P1\P2\" + $name56.Replace('/','\')) $p56)
EL "PAKX0" 1
EL "PAKL" 0
$pl = @(Lines "PAKL")
Check "L: 6 lines, 56-byte name bounded" ($pl.Count -eq 6 -and $pl[5] -eq ("9 " + $name56)) ("got: " + ($pl -join " | "))
EL "PAKBIGH" 0
Check "513-entry PAK: truncation warning shown" ((Out1 "PAKBIGH") -match 'more than 512 entries')
$bl = @(Lines "PAKBIGL")
Check "513-entry PAK: L has exactly 512 '<size> <name>' lines (warning kept off stdout)" ($bl.Count -eq 512 -and @($bl | Where-Object { $_ -notmatch '^\d+ F\d{3}\.TXT$' }).Count -eq 0) ("got {0} lines" -f $bl.Count)
Check "no EVIL* from CCPAK either" ($evil.Count -eq 0)

Write-Host "`n--- never overwrite (X / XA onto existing files) ---"
function Keeps([string[]]$rels) { foreach ($x in $rels) { if (-not (SameBytes $x $keep)) { return $false } }; return $true }
function Names([string]$rel) { (Get-ChildItem (Join-Path $w $rel) -File | ForEach-Object { $_.Name.ToUpper() } | Sort-Object) -join ',' }
EL "OVZX3" 0; Check "CCZIP X stored: M3.TXT kept, M3~1.TXT written" ((Keeps "OV1\M3.TXT") -and (SameBytes "OV1\M3~1.TXT" ([byte[]]$m["M3.TXT"]))) (Names "OV1")
EL "OVZX0" 0; Check "CCZIP X deflated: M1.TXT kept, M1~1.TXT written (70000 B)" ((Keeps "OV1\M1.TXT") -and (SameBytes "OV1\M1~1.TXT" ([byte[]]$m["M1.TXT"]))) (Names "OV1")
EL "OVZXA" 0
Check "CCZIP XA: clashing M5.TXT / SUB\M4.TXT kept, ~1 copies written" ((Keeps @("OV2\M5.TXT","OV2\SUB\M4.TXT")) -and (SameBytes "OV2\M5~1.TXT" ([byte[]]$m["M5.TXT"])) -and (SameBytes "OV2\SUB\M4~1.TXT" ([byte[]]$m["SUB/M4.TXT"])))
Check "CCZIP XA: non-clashing members written under their own names" ((SameBytes "OV2\M1.TXT" ([byte[]]$m["M1.TXT"])) -and (SameBytes "OV2\M3.TXT" ([byte[]]$m["M3.TXT"])) -and -not (Exists "OV2\M1~1.TXT"))
EL "OVWXA" 1
Check "CCZIP: LONGNAME.TXT + LONGNA~1.TXT taken -> LONGNA~2.TXT" ((Keeps @("OV3\LONGNAME.TXT","OV3\LONGNA~1.TXT")) -and (SameBytes "OV3\LONGNA~2.TXT" $lname)) (Names "OV3")
Check "CCZIP: extension-less NOEXT -> NOEXT~1" ((Keeps "OV3\NOEXT") -and (SameBytes "OV3\NOEXT~1" $noext)) (Names "OV3")
$fk = @("OV3\FULL.TXT") + (1..9 | ForEach-Object { "OV3\FULL~$_.TXT" })
Check "CCZIP: FULL.TXT + FULL~1..~9 taken -> member fails, all 10 untouched" (Keeps $fk) (Names "OV3")
Check "CCZIP: member after the failed one still extracted" (SameBytes "OV3\AFTER.TXT" $after)
Check "CCZIP: failure reported" ((Out1 "OVWXA") -match 'FULL\.TXT') ("out: " + (Out1 "OVWXA"))
EL "OVWX2" 1
$ov3want = (@("AFTER.TXT","FULL.TXT") + (1..9 | ForEach-Object { "FULL~$_.TXT" }) + @("LONGNA~1.TXT","LONGNA~2.TXT","LONGNAME.TXT","NOEXT","NOEXT~1") | Sort-Object) -join ','
Check "CCZIP OV3 holds exactly the expected 15 files" ((Names "OV3") -eq $ov3want) (Names "OV3")
EL "OVPX3" 0; Check "CCPAK X: PROGS\GOOD.TXT kept, GOOD~1.TXT written" ((Keeps "OV4\PROGS\GOOD.TXT") -and (SameBytes "OV4\PROGS\GOOD~1.TXT" $pgood)) (Names "OV4\PROGS")
EL "OVPXF" 1
Check "CCPAK X all ~1..~9 taken: 10 files untouched, nothing added" ((Keeps (@("OV5\PROGS\GOOD.TXT") + (1..9 | ForEach-Object { "OV5\PROGS\GOOD~$_.TXT" }))) -and @(Get-ChildItem "$w\OV5\PROGS").Count -eq 10) (Names "OV5\PROGS")

Write-Host "`n--- CCZIP: corrupt deflate / encrypted ---"
Check "corrupt-data session terminated by itself (no INFLATE spin)" $badOk
EL "BADXA" 1
$bo = Out1 "BADXA"
Check "4 members reported corrupt/truncated" ((Count $bo 'corrupt or truncated') -eq 4) ("out: $bo")
Check "encrypted member reported" ($bo -match 'encrypted member skipped: ENC\.BIN')
Check "GOOD.TXT after the bad members still extracted" (SameBytes "BOUT\GOOD.TXT" $good)
$left = @("STALL.BIN","TRUNC.BIN","NLEN.BIN","RESV.BIN","ENC.BIN") | Where-Object { Exists "BOUT\$_" }
Check "no partial output left for failed members" ($left.Count -eq 0) ("left: " + ($left -join ", "))
EL "BADX0" 1

Check "main session ran to the end" ($mainOk -and $r -match 'DONE-main')
Check "corrupt session ran to the end" ($r -match 'DONE-corrupt')
Write-Host ("`nCZIP SAFETY: {0} passed, {1} failed" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { Write-Host "CZIP SAFETY: FAIL"; exit 1 }
Write-Host "CZIP SAFETY: PASS"
exit 0
