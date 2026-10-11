param([ValidateSet('capture','click','double','maximize','restore')][string]$Mode='capture',
      [int]$X=0,[int]$Y=0,[string]$Label='initial')
$ErrorActionPreference='Stop'
if($Label -notmatch '^[a-z0-9-]+$'){throw 'Invalid report label'}
$expected='C:\Users\sunsx\Apps\HotelTV\clubtivi.exe'
$app=@(Get-Process clubtivi -ErrorAction Stop | Where-Object {$_.Path -eq $expected})
if($app.Count -ne 1 -or $app[0].SessionId -eq 0){throw 'Expected one interactive BobTV'}
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class BobTVVisual {
 [StructLayout(LayoutKind.Sequential)] public struct Rect { public int L,T,R,B; }
 [StructLayout(LayoutKind.Sequential)] public struct Point { public int X,Y; }
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h,out Rect r);
 [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h,out Rect r);
 [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h,ref Point p);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int n);
 [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
 [DllImport("user32.dll")] public static extern void mouse_event(uint f,uint x,uint y,uint d,UIntPtr e);
 [DllImport("user32.dll",EntryPoint="GetWindowLongPtrW")] public static extern IntPtr GetStyle(IntPtr h,int n);
}
'@
[void][BobTVVisual]::SetProcessDPIAware()
$handle=$app[0].MainWindowHandle
if($handle -eq [IntPtr]::Zero){throw 'BobTV has no visible window'}
[void][BobTVVisual]::SetForegroundWindow($handle)
Start-Sleep -Milliseconds 400
$client=New-Object BobTVVisual+Rect
[void][BobTVVisual]::GetClientRect($handle,[ref]$client)
$origin=New-Object BobTVVisual+Point
[void][BobTVVisual]::ClientToScreen($handle,[ref]$origin)
if($Mode -in 'click','double') {
 if($X -lt 0 -or $Y -lt 0 -or $X -ge $client.R -or $Y -ge $client.B){throw 'Click escaped BobTV client'}
 [void][BobTVVisual]::SetCursorPos($origin.X+$X,$origin.Y+$Y)
 $count=if($Mode -eq 'double'){2}else{1}
 for($n=0;$n -lt $count;$n++) {
  [BobTVVisual]::mouse_event(2,0,0,0,[UIntPtr]::Zero)
  Start-Sleep -Milliseconds 45
  [BobTVVisual]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
  Start-Sleep -Milliseconds 70
 }
}elseif($Mode -eq 'maximize'){[void][BobTVVisual]::ShowWindow($handle,3)}
elseif($Mode -eq 'restore'){[void][BobTVVisual]::ShowWindow($handle,9)}
Start-Sleep -Milliseconds 600
$rect=New-Object BobTVVisual+Rect
[void][BobTVVisual]::GetWindowRect($handle,[ref]$rect)
[void][BobTVVisual]::GetClientRect($handle,[ref]$client)
$origin=New-Object BobTVVisual+Point
[void][BobTVVisual]::ClientToScreen($handle,[ref]$origin)
$reportRoot='C:\Users\sunsx\src\BobTV-Release105-visual'
New-Item -ItemType Directory -Path $reportRoot -Force | Out-Null
$image=Join-Path $reportRoot ('BobTV105-'+$Label+'.png')
$meta=Join-Path $reportRoot ('BobTV105-'+$Label+'.json')
$size=[System.Drawing.Size]::new($rect.R-$rect.L,$rect.B-$rect.T)
$bitmap=[System.Drawing.Bitmap]::new($size.Width,$size.Height)
$graphics=[System.Drawing.Graphics]::FromImage($bitmap)
try{$graphics.CopyFromScreen($rect.L,$rect.T,0,0,$size);$bitmap.Save($image,[System.Drawing.Imaging.ImageFormat]::Png)}
finally{$graphics.Dispose();$bitmap.Dispose()}
$result=@{version=(Get-Item $expected).VersionInfo.FileVersion;pid=$app[0].Id;responding=$app[0].Responding;
 outer=@($rect.L,$rect.T,$rect.R,$rect.B);client=@($client.R,$client.B);captionInset=$origin.Y-$rect.T;
 canMaximize=(([BobTVVisual]::GetStyle($handle,-16).ToInt64() -band 0x10000) -ne 0);mode=$Mode}
[IO.File]::WriteAllText($meta,($result|ConvertTo-Json -Compress))
foreach($file in @($image,$meta)) {
 & 'C:\Program Files\Tailscale\tailscale.exe' file cp $file '100.65.248.58:'
 if($LASTEXITCODE -ne 0){throw 'Visual report transfer failed'}
}
