$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$expected='C:\Users\sunsx\Apps\HotelTV\clubtivi.exe'
Stop-ScheduledTask 'BobTV-CrashMonitor-Test86' -ErrorAction SilentlyContinue
Stop-ScheduledTask 'BobTV-Local86-Test' -ErrorAction SilentlyContinue
$players=@(Get-Process clubtivi -ErrorAction SilentlyContinue | Where-Object {$_.Path -eq $expected})
foreach($p in $players){[void]$p.CloseMainWindow()}
Start-Sleep -Seconds 2
foreach($p in $players){$live=Get-Process -Id $p.Id -ErrorAction SilentlyContinue;if($live -and $live.Path -eq $expected){Stop-Process -Id $live.Id -Force}}
Start-ScheduledTask 'BobTV-Local86-Test'
Start-Sleep -Seconds 10
Get-Process clubtivi -ErrorAction SilentlyContinue | Where-Object {$_.Path -eq $expected} | Select-Object Id,Responding,MainWindowHandle,WorkingSet64 | ConvertTo-Json -Compress
@{version=(Get-Item $expected).VersionInfo.FileVersion}|ConvertTo-Json -Compress
