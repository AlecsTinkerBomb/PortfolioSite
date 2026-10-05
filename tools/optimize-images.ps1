<#
  Makes web-sized copies of the full-resolution images kept in /originals.

    originals/name.jpg  ->  assets/name.jpg      (up to 3200px wide, used on desktop)
                            assets/sm/name.jpg   (up to 1600px wide, used on phones)

  Run it from the project folder after adding or replacing an original:

    powershell -ExecutionPolicy Bypass -File tools\optimize-images.ps1

  - Only images that are new or changed since the last run are processed (-Force redoes all).
  - Colors are converted to sRGB (handles CMYK print exports and iPhone Display P3 photos).
  - PNGs are flattened onto white and saved as .jpg.
  - /originals and /tools are not published (see .wranglerignore).
#>
param(
  [int]$Large = 3200,
  [int]$Small = 1600,
  [int]$Quality = 82,
  [string]$Source,
  [string]$Dest,
  [switch]$Force
)
$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
if (-not $Source) { $Source = Join-Path $root 'originals' }
if (-not $Dest)   { $Dest   = Join-Path $root 'assets' }

# Images that are only ever shown small on the page get a lower size cap.
$MaxWidth = @{ 'aboutme2.jpg' = 1200 }

Add-Type -AssemblyName PresentationCore, WindowsBase, System.Xaml, System.Drawing
if (-not ('WebImage' -as [type])) {
  $refs = @(
    [System.Windows.Media.Imaging.BitmapSource].Assembly.Location,
    [System.Windows.Int32Rect].Assembly.Location,
    [System.Drawing.Bitmap].Assembly.Location,
    [System.Xaml.XamlReader].Assembly.Location
  )
  Add-Type -ReferencedAssemblies $refs -TypeDefinition @'
using System;
using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using SD = System.Drawing;
using SDI = System.Drawing.Imaging;
using SD2 = System.Drawing.Drawing2D;

public static class WebImage {
  // Decodes src, converts to sRGB, flattens alpha onto white, resizes to maxWidth and saves a JPEG.
  public static string Write(string src, string dst, int maxWidth, long quality) {
    var uri = new Uri(Path.GetFullPath(src));
    var frame = BitmapDecoder.Create(uri, BitmapCreateOptions.IgnoreColorProfile | BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.None).Frames[0];
    int w = frame.PixelWidth, h = frame.PixelHeight;

    ColorContext profile = null;
    try { var cc = frame.ColorContexts; if (cc != null && cc.Count > 0) profile = cc[0]; } catch { }

    int orient = 1;
    try {
      var md = frame.Metadata as BitmapMetadata;
      if (md != null && md.ContainsQuery("/app1/ifd/{ushort=274}")) orient = Convert.ToInt32(md.GetQuery("/app1/ifd/{ushort=274}"));
    } catch { }
    bool sideways = orient >= 5;
    int dispW = sideways ? h : w, dispH = sideways ? w : h;
    int outW = Math.Min(maxWidth, dispW);
    int outH = (int)Math.Round((double)dispH * outW / dispW);

    // Stream the full-resolution pixels through the embedded color profile in strips, box-averaging
    // k x k blocks as we go so memory stays small; high-quality bicubic does the final (<= 2x) step.
    BitmapSource s = frame;
    if (profile != null) s = new ColorConvertedBitmap(frame, profile, new ColorContext(PixelFormats.Bgra32), PixelFormats.Bgra32);
    if (s.Format != PixelFormats.Bgra32) s = new FormatConvertedBitmap(s, PixelFormats.Bgra32, null, 0);

    int k = Math.Max(1, (int)Math.Ceiling((double)dispW / outW / 2.0));
    int rw = w / k, rh = h / k;
    int band = k * Math.Max(1, 64 / k);
    int srcStride = w * 4;
    var buf = new byte[srcStride * band];
    var acc = new int[rw * 3];
    var row = new byte[rw * 3];
    int div = k * k * 255;

    var reduced = new SD.Bitmap(rw, rh, SDI.PixelFormat.Format24bppRgb);
    try {
      var data = reduced.LockBits(new SD.Rectangle(0, 0, rw, rh), SDI.ImageLockMode.WriteOnly, SDI.PixelFormat.Format24bppRgb);
      for (int y0 = 0; y0 < rh * k; y0 += band) {
        int rows = Math.Min(band, rh * k - y0);
        s.CopyPixels(new Int32Rect(0, y0, w, rows), buf, srcStride, 0);
        for (int ry = 0; ry < rows / k; ry++) {
          Array.Clear(acc, 0, acc.Length);
          for (int dy = 0; dy < k; dy++) {
            int rowOff = (ry * k + dy) * srcStride;
            for (int ox = 0, sb = rowOff; ox < rw; ox++) {
              int o = ox * 3;
              for (int dx = 0; dx < k; dx++, sb += 4) {
                int a = buf[sb + 3], white = 255 * (255 - a);
                acc[o]     += buf[sb]     * a + white;
                acc[o + 1] += buf[sb + 1] * a + white;
                acc[o + 2] += buf[sb + 2] * a + white;
              }
            }
          }
          for (int i = 0; i < row.Length; i++) row[i] = (byte)((acc[i] + div / 2) / div);
          System.Runtime.InteropServices.Marshal.Copy(row, 0, IntPtr.Add(data.Scan0, (y0 / k + ry) * data.Stride), row.Length);
        }
      }
      reduced.UnlockBits(data);

      if (orient == 3) reduced.RotateFlip(SD.RotateFlipType.Rotate180FlipNone);
      if (orient == 6) reduced.RotateFlip(SD.RotateFlipType.Rotate90FlipNone);
      if (orient == 8) reduced.RotateFlip(SD.RotateFlipType.Rotate270FlipNone);

      var jpeg = Array.Find(SDI.ImageCodecInfo.GetImageEncoders(), c => c.FormatID == SDI.ImageFormat.Jpeg.Guid);
      var ps = new SDI.EncoderParameters(1);
      ps.Param[0] = new SDI.EncoderParameter(SDI.Encoder.Quality, quality);
      Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(dst)));

      if (reduced.Width == outW && reduced.Height == outH) {
        reduced.Save(dst, jpeg, ps);
      } else {
        using (var outBmp = new SD.Bitmap(outW, outH, SDI.PixelFormat.Format24bppRgb))
        using (var g = SD.Graphics.FromImage(outBmp))
        using (var attr = new SDI.ImageAttributes()) {
          g.InterpolationMode = SD2.InterpolationMode.HighQualityBicubic;
          g.PixelOffsetMode = SD2.PixelOffsetMode.HighQuality;
          g.CompositingQuality = SD2.CompositingQuality.HighQuality;
          attr.SetWrapMode(SD2.WrapMode.TileFlipXY);
          g.DrawImage(reduced, new SD.Rectangle(0, 0, outW, outH), 0, 0, reduced.Width, reduced.Height, SD.GraphicsUnit.Pixel, attr);
          outBmp.Save(dst, jpeg, ps);
        }
      }
    } finally { reduced.Dispose(); }
    return outW + "x" + outH;
  }
}
'@
}

$files = Get-ChildItem $Source -File | Where-Object { $_.Extension -match '^\.(jpe?g|png)$' }
foreach ($f in $files) {
  $name = if ($f.Extension -ieq '.png') { [IO.Path]::ChangeExtension($f.Name, '.jpg') } else { $f.Name }
  $cap = if ($MaxWidth.ContainsKey($f.Name)) { $MaxWidth[$f.Name] } else { $Large }
  $targets = @(@{ Path = Join-Path $Dest $name; Width = $cap })
  if ($cap -gt $Small) { $targets += @{ Path = Join-Path (Join-Path $Dest 'sm') $name; Width = $Small } }

  foreach ($t in $targets) {
    if (-not $Force -and (Test-Path $t.Path) -and (Get-Item $t.Path).LastWriteTime -gt $f.LastWriteTime) { continue }
    $dims = [WebImage]::Write($f.FullName, $t.Path, $t.Width, $Quality)
    '{0,-28} -> {1,-34} {2,11}  {3,6:N2} MB' -f $f.Name, ($t.Path.Substring($Dest.Length).TrimStart('\')), $dims, ((Get-Item $t.Path).Length / 1MB)
  }
}
