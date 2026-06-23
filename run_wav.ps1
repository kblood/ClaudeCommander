$ErrorActionPreference = "Stop"
$dir  = "C:\LLM\cc"
$dbox = "$dir\dbstaging\dosbox-staging-v0.82.2\dosbox.exe"
$nasm = "C:\Users\Caldor\AppData\Local\bin\NASM\nasm.exe"
if (-not (Test-Path $nasm)) { $nasm = "nasm" }

& $nasm -f bin "$dir\cwav.asm" -o "$dir\ccwav.com" 2>&1
if ($LASTEXITCODE -ne 0) { Write-Host "ASSEMBLE FAILED"; exit 1 }
Write-Host ("BUILD OK: {0} bytes" -f (Get-Item "$dir\ccwav.com").Length)

function LE16([int]$v){ [byte]($v -band 0xFF), [byte](($v -shr 8) -band 0xFF) }
function LE32([long]$v){ [byte]($v -band 0xFF), [byte](($v -shr 8) -band 0xFF), [byte](($v -shr 16) -band 0xFF), [byte](($v -shr 24) -band 0xFF) }
function A4([string]$s){ [System.Text.Encoding]::ASCII.GetBytes($s) }

# Build a WAV with a fmt chunk, an even "fact" chunk and an ODD "junk" chunk
# (both must be skipped, the odd one with a pad byte), then the data chunk.
function Build-Wav($path, $rate, $channels, $bits, [byte[]]$pcm) {
    $w = New-Object System.Collections.Generic.List[byte]
    $fmt = New-Object System.Collections.Generic.List[byte]
    $fmt.AddRange([byte[]](LE16 1))                      # PCM
    $fmt.AddRange([byte[]](LE16 $channels))
    $fmt.AddRange([byte[]](LE32 $rate))
    $blockAlign = $channels * ($bits/8)
    $fmt.AddRange([byte[]](LE32 ($rate*$blockAlign)))    # byte rate
    $fmt.AddRange([byte[]](LE16 $blockAlign))
    $fmt.AddRange([byte[]](LE16 $bits))
    $body = New-Object System.Collections.Generic.List[byte]
    $body.AddRange([byte[]](A4 "WAVE"))
    # fmt chunk
    $body.AddRange([byte[]](A4 "fmt "))
    $body.AddRange([byte[]](LE32 $fmt.Count))
    $body.AddRange($fmt.ToArray())
    # fact chunk (even, 4 bytes) -> skipped
    $body.AddRange([byte[]](A4 "fact"))
    $body.AddRange([byte[]](LE32 4))
    $body.AddRange([byte[]](0x11,0x22,0x33,0x44))
    # junk chunk (odd, 3 bytes) -> skipped with a pad byte
    $body.AddRange([byte[]](A4 "junk"))
    $body.AddRange([byte[]](LE32 3))
    $body.AddRange([byte[]](0xAA,0xBB,0xCC))
    $body.Add([byte]0)                                   # pad byte (odd size)
    # data chunk
    $body.AddRange([byte[]](A4 "data"))
    $body.AddRange([byte[]](LE32 $pcm.Length))
    $body.AddRange($pcm)
    $w.AddRange([byte[]](A4 "RIFF"))
    $w.AddRange([byte[]](LE32 $body.Count))
    $w.AddRange($body.ToArray())
    [IO.File]::WriteAllBytes($path, $w.ToArray())
}

function Expected($rate, $channels, $bits, [byte[]]$pcm) {
    $e = New-Object System.Collections.Generic.List[byte]
    $e.AddRange([byte[]](LE32 $rate))
    $e.AddRange([byte[]](LE16 $channels))
    $e.AddRange([byte[]](LE16 $bits))
    $e.AddRange([byte[]](LE32 $pcm.Length))
    $e.AddRange($pcm)
    return ,$e.ToArray()
}

function Run-Decode([string]$wav) {
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
ccwav.com /D $wav
exit
"@
    Set-Content -Path "$dir\_run_wav.conf" -Value $conf -Encoding ASCII
    if (Test-Path "$dir\CCWAV.RAW") { Remove-Item "$dir\CCWAV.RAW" -Force }
    $p = Start-Process -FilePath $dbox -ArgumentList @("-conf","$dir\_run_wav.conf","-noprimaryconf") -PassThru -WindowStyle Minimized
    if (-not $p.WaitForExit(15000)) { $p.Kill() | Out-Null }
    Start-Sleep -Milliseconds 300
    if (-not (Test-Path "$dir\CCWAV.RAW")) { return $null }
    return [IO.File]::ReadAllBytes("$dir\CCWAV.RAW")
}

function Compare-Case($name, $got, $exp) {
    if ($null -eq $got) { Write-Host ("{0}: NO OUTPUT" -f $name); return }
    $bad = -1
    $n = [Math]::Min($got.Length, $exp.Length)
    for ($i=0; $i -lt $n; $i++) { if ($got[$i] -ne $exp[$i]) { $bad = $i; break } }
    if ($bad -lt 0 -and $got.Length -eq $exp.Length) {
        Write-Host ("{0}: PASS ({1} bytes)" -f $name, $got.Length)
    } else {
        Write-Host ("{0}: FAIL len got={1} exp={2} firstdiff={3}" -f $name, $got.Length, $exp.Length, $bad)
        if ($bad -ge 0) {
            $lo=[Math]::Max(0,$bad-2); $hi=[Math]::Min($n-1,$bad+6)
            Write-Host ("  got: " + (($lo..$hi | ForEach-Object {"{0:X2}" -f $got[$_]}) -join " "))
            Write-Host ("  exp: " + (($lo..$hi | ForEach-Object {"{0:X2}" -f $exp[$_]}) -join " "))
        }
    }
}

# Case A: 8-bit mono, 50 samples 0..49, rate 11025
$pcmA = [byte[]](0..49)
Build-Wav "$dir\TEST.WAV" 11025 1 8 $pcmA
$expA = Expected 11025 1 8 $pcmA
$gotA = Run-Decode "TEST.WAV"
Compare-Case "WAV-8bit-mono" $gotA $expA

# Case B: 16-bit stereo, 20 frames (80 bytes), rate 22050
$pcmB = New-Object System.Collections.Generic.List[byte]
for ($i=0; $i -lt 20; $i++) {
    $l = ($i*1000) - 10000
    $r = 5000 - ($i*500)
    $pcmB.AddRange([byte[]](LE16 ($l -band 0xFFFF)))
    $pcmB.AddRange([byte[]](LE16 ($r -band 0xFFFF)))
}
$pcmB = $pcmB.ToArray()
Build-Wav "$dir\TEST2.WAV" 22050 2 16 $pcmB
$expB = Expected 22050 2 16 $pcmB
$gotB = Run-Decode "TEST2.WAV"
Compare-Case "WAV-16bit-stereo" $gotB $expB
