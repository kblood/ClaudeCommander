param(
  [string]$in  = "C:\LLM\cc\CCSNAP.BIN",
  [string]$out = "C:\LLM\cc\claude_commander.png"
)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

$bytes = [System.IO.File]::ReadAllBytes($in)
$cp437 = [System.Text.Encoding]::GetEncoding(437)

# 16-colour VGA text palette
$pal = @(
  [System.Drawing.Color]::FromArgb(0,0,0),      [System.Drawing.Color]::FromArgb(0,0,170),
  [System.Drawing.Color]::FromArgb(0,170,0),    [System.Drawing.Color]::FromArgb(0,170,170),
  [System.Drawing.Color]::FromArgb(170,0,0),    [System.Drawing.Color]::FromArgb(170,0,170),
  [System.Drawing.Color]::FromArgb(170,85,0),   [System.Drawing.Color]::FromArgb(170,170,170),
  [System.Drawing.Color]::FromArgb(85,85,85),   [System.Drawing.Color]::FromArgb(85,85,255),
  [System.Drawing.Color]::FromArgb(85,255,85),  [System.Drawing.Color]::FromArgb(85,255,255),
  [System.Drawing.Color]::FromArgb(255,85,85),  [System.Drawing.Color]::FromArgb(255,85,255),
  [System.Drawing.Color]::FromArgb(255,255,85), [System.Drawing.Color]::FromArgb(255,255,255)
)

$cols = 80; $rows = 25
$cw = 10; $ch = 18
$bmp = New-Object System.Drawing.Bitmap ($cols*$cw), ($rows*$ch)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::SingleBitPerPixelGridFit
$g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::None
$font = New-Object System.Drawing.Font ("Consolas", 13, [System.Drawing.GraphicsUnit]::Pixel)
$fmt = [System.Drawing.StringFormat]::GenericTypographic

for ($r=0; $r -lt $rows; $r++) {
  for ($c=0; $c -lt $cols; $c++) {
    $i = ($r*$cols + $c)*2
    $chByte = $bytes[$i]
    $attr   = $bytes[$i+1]
    $fg = $pal[$attr -band 0x0F]
    $bg = $pal[($attr -shr 4) -band 0x07]
    $x = $c*$cw; $y = $r*$ch
    $g.FillRectangle((New-Object System.Drawing.SolidBrush $bg), $x, $y, $cw, $ch)
    if ($chByte -ne 32 -and $chByte -ne 0) {
      $s = $cp437.GetString([byte[]]@($chByte))
      $g.DrawString($s, $font, (New-Object System.Drawing.SolidBrush $fg), ($x-1), ($y-1), $fmt)
    }
  }
}
$g.Dispose()
$bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Host ("saved {0} ({1} bytes, {2}x{3})" -f $out, (Get-Item $out).Length, ($cols*$cw), ($rows*$ch))
