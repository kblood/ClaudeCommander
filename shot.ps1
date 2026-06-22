param(
    [int]$waitMs = 4500,
    [string]$out = "C:\LLM\cc\shot.png",
    [string]$exe = "C:\LLM\cc\dbstaging\dosbox-staging-v0.82.2\dosbox.exe",
    [string]$conf = "C:\LLM\cc\shot.conf",
    [string]$ccArgs = ""
)
$ErrorActionPreference = "Stop"
$dir = "C:\LLM\cc"

# assemble fresh
& "C:\Users\Caldor\AppData\Local\bin\NASM\nasm.exe" -f bin "$dir\cc.asm" -o "$dir\cc.com" 2>&1 | Out-Null

# write a conf that runs cc interactively (no exit) so the screen persists
$c = @"
[sdl]
fullscreen = false
window_position = 0,0
[cpu]
core    = normal
cputype = 486
cycles  = max
[autoexec]
@echo off
mount c $dir
c:
cc.com $ccArgs
"@
Set-Content -Path $conf -Value $c -Encoding ASCII

Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Drawing;
public class WinCap {
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x,int y,int cx,int cy,uint f);
  [DllImport("user32.dll")] public static extern void SwitchToThisWindow(IntPtr h, bool alt);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
  static readonly IntPtr TOP = new IntPtr(-1);
  public static void Front(IntPtr h){
    ShowWindow(h, 9);
    SetWindowPos(h, TOP, 0, 0, 0, 0, 0x0001|0x0040);
    BringWindowToTop(h);
    SwitchToThisWindow(h, true);
  }
  public static void Shot(IntPtr h, string path) {
    RECT r; GetWindowRect(h, out r);
    int w = r.R-r.L, ht = r.B-r.T;
    if (w<=0||ht<=0){ w=720; ht=540; }
    Bitmap bmp = new Bitmap(w, ht);
    Graphics g = Graphics.FromImage(bmp);
    IntPtr hdc = g.GetHdc();
    PrintWindow(h, hdc, 2);          // PW_RENDERFULLCONTENT - captures GPU/DWM windows
    g.ReleaseHdc(hdc);
    g.Dispose();
    bmp.Save(path, System.Drawing.Imaging.ImageFormat.Png);
    bmp.Dispose();
  }
}
"@ -ReferencedAssemblies System.Drawing

$p = Start-Process -FilePath $exe -ArgumentList @("-conf",$conf,"-noprimaryconf") -PassThru
Start-Sleep -Milliseconds $waitMs
$p.Refresh()
$h = $p.MainWindowHandle
if ($h -eq [IntPtr]::Zero) {
  $q = Get-Process | Where-Object { $_.MainWindowTitle -match "DOSBox" } | Select-Object -First 1
  if ($q) { $h = $q.MainWindowHandle }
}
Write-Host "hwnd=$h title=$($p.MainWindowTitle)"
[WinCap]::Front($h)
Start-Sleep -Milliseconds 700
[WinCap]::Shot($h, $out)
Start-Sleep -Milliseconds 200
if (-not $p.HasExited) { $p.Kill() }
Write-Host "saved $out ($((Get-Item $out).Length) bytes)"
