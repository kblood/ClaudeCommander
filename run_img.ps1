$ErrorActionPreference = "Stop"
$dir  = "C:\LLM\cc"
$dbox = "$dir\dbstaging\dosbox-staging-v0.82.2\dosbox.exe"
$nasm = "C:\Users\Caldor\AppData\Local\bin\NASM\nasm.exe"
if (-not (Test-Path $nasm)) { $nasm = "nasm" }

& $nasm -f bin "$dir\cimg.asm" -o "$dir\ccimg.com" 2>&1
if ($LASTEXITCODE -ne 0) { Write-Host "ASSEMBLE FAILED"; exit 1 }
Write-Host ("BUILD OK: {0} bytes" -f (Get-Item "$dir\ccimg.com").Length)

# ---- known test image: 17x5, row-major. cols 0..9 = 0xC5 (a high-value run),
#      cols 10..16 = distinct 10..16. Identical rows -> exercises PCX RLE runs,
#      GIF LZW dictionary reuse, and BMP 17%4 row padding (3 pad bytes). --------
$W = 17; $H = 5
$pix = New-Object System.Collections.Generic.List[int]
for ($r=0; $r -lt $H; $r++) {
    for ($c=0; $c -lt $W; $c++) {
        if ($c -lt 10) { $pix.Add(0xC5) } else { $pix.Add($c) }
    }
}
$pix = $pix.ToArray()
# palette: entry i = (i, i, i)
$palR = 0..255; $palG = 0..255; $palB = 0..255

function LE16([int]$v){ [byte]($v -band 0xFF), [byte](($v -shr 8) -band 0xFF) }
function LE32([int]$v){ [byte]($v -band 0xFF), [byte](($v -shr 8) -band 0xFF), [byte](($v -shr 16) -band 0xFF), [byte](($v -shr 24) -band 0xFF) }

# ===== BMP (8-bit BI_RGB, bottom-up) =======================================
$bmp = New-Object System.Collections.Generic.List[byte]
$off = 14 + 40 + 256*4
$rowbytes = [int]([Math]::Floor(($W + 3) / 4)) * 4   # padded to 4-byte boundary
$pad = $rowbytes - $W
$fsize = $off + $rowbytes * $H
$bmp.AddRange([byte[]](0x42,0x4D))             # 'BM'
$bmp.AddRange([byte[]](LE32 $fsize))
$bmp.AddRange([byte[]](LE32 0))                # reserved
$bmp.AddRange([byte[]](LE32 $off))             # bfOffBits
$bmp.AddRange([byte[]](LE32 40))               # biSize
$bmp.AddRange([byte[]](LE32 $W))
$bmp.AddRange([byte[]](LE32 $H))
$bmp.AddRange([byte[]](LE16 1))                # planes
$bmp.AddRange([byte[]](LE16 8))                # bitcount
$bmp.AddRange([byte[]](LE32 0))                # compression BI_RGB
$bmp.AddRange([byte[]](LE32 ($rowbytes*$H)))   # sizeimage
$bmp.AddRange([byte[]](LE32 0))                # xpels
$bmp.AddRange([byte[]](LE32 0))                # ypels
$bmp.AddRange([byte[]](LE32 0))                # clrused -> 256
$bmp.AddRange([byte[]](LE32 0))                # clrimportant
for ($i=0; $i -lt 256; $i++) {                 # palette B,G,R,0
    $bmp.Add([byte]$palB[$i]); $bmp.Add([byte]$palG[$i]); $bmp.Add([byte]$palR[$i]); $bmp.Add([byte]0)
}
for ($r = $H-1; $r -ge 0; $r--) {              # bottom-up rows
    for ($c=0; $c -lt $W; $c++) { $bmp.Add([byte]$pix[$r*$W+$c]) }
    for ($p=0; $p -lt $pad; $p++) { $bmp.Add([byte]0) }   # row padding
}
[IO.File]::WriteAllBytes("$dir\TEST.BMP", $bmp.ToArray())

# ===== PCX (8-bit, RLE, palette tail) ======================================
$pcxBpl = if (($W % 2) -eq 0) { $W } else { $W + 1 }   # PCX bytes-per-line must be even
$pcx = New-Object System.Collections.Generic.List[byte]
$hdr = New-Object byte[] 128
$hdr[0]=0x0A; $hdr[1]=5; $hdr[2]=1; $hdr[3]=8
# xmin=0 ymin=0 xmax=W-1 ymax=H-1
$hdr[8]=[byte](($W-1) -band 0xFF); $hdr[9]=[byte]((($W-1) -shr 8) -band 0xFF)
$hdr[10]=[byte](($H-1) -band 0xFF); $hdr[11]=[byte]((($H-1) -shr 8) -band 0xFF)
$hdr[65]=1                                     # nplanes
$hdr[66]=[byte]($pcxBpl -band 0xFF); $hdr[67]=[byte](($pcxBpl -shr 8) -band 0xFF)
$pcx.AddRange($hdr)
# proper PCX RLE per scanline (pcxBpl bytes; trailing pad byte = 0 if W is odd)
for ($r=0; $r -lt $H; $r++) {
    $line = New-Object byte[] $pcxBpl
    for ($c=0; $c -lt $W; $c++) { $line[$c] = [byte]$pix[$r*$W+$c] }
    $i = 0
    while ($i -lt $pcxBpl) {
        $v = $line[$i]; $run = 1
        while (($i+$run) -lt $pcxBpl -and $line[$i+$run] -eq $v -and $run -lt 63) { $run++ }
        if ($run -gt 1 -or $v -ge 0xC0) {
            $pcx.Add([byte](0xC0 -bor $run)); $pcx.Add([byte]$v)
        } else {
            $pcx.Add([byte]$v)
        }
        $i += $run
    }
}
$pcx.Add([byte]0x0C)                           # palette marker
for ($i=0; $i -lt 256; $i++) { $pcx.Add([byte]$palR[$i]); $pcx.Add([byte]$palG[$i]); $pcx.Add([byte]$palB[$i]) }
[IO.File]::WriteAllBytes("$dir\TEST.PCX", $pcx.ToArray())

# ===== GIF87a (LZW, global colour table) ===================================
function Encode-GifLzw([int[]]$idx, [int]$minCodeSize) {
    $clear = 1 -shl $minCodeSize
    $eoi   = $clear + 1
    $codeSize = $minCodeSize + 1
    $next = $eoi + 1
    $dict = @{}
    # build (code, width) list, then pack LSB-first
    $codes = New-Object System.Collections.Generic.List[int]
    $widths = New-Object System.Collections.Generic.List[int]
    $codes.Add($clear); $widths.Add($codeSize)
    $prefix = $idx[0]
    for ($i=1; $i -lt $idx.Count; $i++) {
        $k = $idx[$i]
        $key = "$prefix,$k"
        if ($dict.ContainsKey($key)) {
            $prefix = $dict[$key]
        } else {
            $codes.Add($prefix); $widths.Add($codeSize)
            $dict[$key] = $next
            $next++
            if ($next -ge (1 -shl $codeSize) -and $codeSize -lt 12) { $codeSize++ }
            $prefix = $k
        }
    }
    $codes.Add($prefix); $widths.Add($codeSize)
    $codes.Add($eoi);    $widths.Add($codeSize)
    $bytes = New-Object System.Collections.Generic.List[byte]
    $acc = 0; $nb = 0
    for ($i=0; $i -lt $codes.Count; $i++) {
        $acc = $acc -bor ($codes[$i] -shl $nb)
        $nb += $widths[$i]
        while ($nb -ge 8) { $bytes.Add([byte]($acc -band 0xFF)); $acc = $acc -shr 8; $nb -= 8 }
    }
    if ($nb -gt 0) { $bytes.Add([byte]($acc -band 0xFF)) }
    return ,($bytes.ToArray())
}
$gif = New-Object System.Collections.Generic.List[byte]
$gif.AddRange([System.Text.Encoding]::ASCII.GetBytes("GIF87a"))
$gif.AddRange([byte[]](LE16 $W))               # logical screen w
$gif.AddRange([byte[]](LE16 $H))               # logical screen h
$gif.Add([byte]0x87)                           # GCT present, size n=7 -> 256
$gif.Add([byte]0)                              # bg index
$gif.Add([byte]0)                              # aspect
for ($i=0; $i -lt 256; $i++) { $gif.Add([byte]$palR[$i]); $gif.Add([byte]$palG[$i]); $gif.Add([byte]$palB[$i]) }
$gif.Add([byte]0x2C)                           # image descriptor
$gif.AddRange([byte[]](LE16 0))                # left
$gif.AddRange([byte[]](LE16 0))                # top
$gif.AddRange([byte[]](LE16 $W))
$gif.AddRange([byte[]](LE16 $H))
$gif.Add([byte]0)                              # packed: no LCT, no interlace
$gif.Add([byte]8)                              # LZW min code size
$lzw = Encode-GifLzw $pix 8
# emit as sub-blocks of <=255 bytes
$p = 0
while ($p -lt $lzw.Count) {
    $n = [Math]::Min(255, $lzw.Count - $p)
    $gif.Add([byte]$n)
    for ($j=0; $j -lt $n; $j++) { $gif.Add([byte]$lzw[$p+$j]) }
    $p += $n
}
$gif.Add([byte]0)                              # block terminator
$gif.Add([byte]0x3B)                           # trailer
[IO.File]::WriteAllBytes("$dir\TEST.GIF", $gif.ToArray())

Write-Host ("fixtures: BMP={0} PCX={1} GIF={2} bytes" -f (Get-Item "$dir\TEST.BMP").Length, (Get-Item "$dir\TEST.PCX").Length, (Get-Item "$dir\TEST.GIF").Length)

# ---- expected RAW ----------------------------------------------------------
$exp = New-Object System.Collections.Generic.List[byte]
$exp.AddRange([byte[]](LE16 $W))
$exp.AddRange([byte[]](LE16 $H))
foreach ($v in $pix) { $exp.Add([byte]$v) }
for ($i=0; $i -lt 256; $i++) { $exp.Add([byte]$palR[$i]); $exp.Add([byte]$palG[$i]); $exp.Add([byte]$palB[$i]) }
$expA = $exp.ToArray()

function Run-Decode([string]$img) {
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
ccimg.com /D $img
exit
"@
    $confPath = "$dir\_run_img.conf"
    Set-Content -Path $confPath -Value $conf -Encoding ASCII
    if (Test-Path "$dir\CCIMG.RAW") { Remove-Item "$dir\CCIMG.RAW" -Force }
    $proc = Start-Process -FilePath $dbox -ArgumentList @("-conf",$confPath,"-noprimaryconf") -PassThru -WindowStyle Minimized
    if (-not $proc.WaitForExit(15000)) { $proc.Kill() | Out-Null }
    Start-Sleep -Milliseconds 300
    if (-not (Test-Path "$dir\CCIMG.RAW")) { return $null }
    return [IO.File]::ReadAllBytes("$dir\CCIMG.RAW")
}

foreach ($f in @("TEST.BMP","TEST.PCX","TEST.GIF")) {
    $got = Run-Decode $f
    if ($null -eq $got) { Write-Host ("{0}: NO OUTPUT" -f $f); continue }
    if ($got.Length -ne $expA.Length) {
        Write-Host ("{0}: LENGTH MISMATCH got={1} exp={2}" -f $f, $got.Length, $expA.Length)
    }
    $bad = -1
    $n = [Math]::Min($got.Length, $expA.Length)
    for ($i=0; $i -lt $n; $i++) { if ($got[$i] -ne $expA[$i]) { $bad = $i; break } }
    if ($bad -lt 0 -and $got.Length -eq $expA.Length) {
        Write-Host ("{0}: PASS ({1} bytes)" -f $f, $got.Length)
    } else {
        Write-Host ("{0}: FAIL first diff at byte {1}" -f $f, $bad)
        if ($bad -ge 0) {
            $lo = [Math]::Max(0,$bad-2); $hi=[Math]::Min($n-1,$bad+6)
            $g = ($lo..$hi | ForEach-Object { "{0:X2}" -f $got[$_] }) -join " "
            $e = ($lo..$hi | ForEach-Object { "{0:X2}" -f $expA[$_] }) -join " "
            Write-Host ("  got: {0}" -f $g)
            Write-Host ("  exp: {0}" -f $e)
        }
    }
}
