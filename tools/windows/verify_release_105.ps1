$ErrorActionPreference='Stop'
$app='C:\Users\sunsx\Apps\HotelTV'
$bundle='C:\Users\sunsx\src\BobTV-Release105\BobTV'
$root='C:\Users\sunsx\AppData\Local\HotelTV'
$live=@(Get-Process clubtivi -ErrorAction SilentlyContinue | Where-Object {$_.Path -eq "$app\clubtivi.exe"})
if($live.Count -ne 1 -or !$live[0].Responding){throw 'Expected one responding player'}
$since=$live[0].StartTime.ToUniversalTime()
$log=Get-ChildItem "$root\Logs" -Filter 'clubtivi-*.log' | Where-Object {$_.Name -notmatch 'native'} | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$current=@(Get-Content $log.FullName -Tail 2000 | ForEach-Object {try{ConvertFrom-Json $_}catch{}} | Where-Object {([DateTime]$_.time).ToUniversalTime() -ge $since})
$native=@(Get-WinEvent -FilterHashtable @{LogName='Application';Id=1000,1001;StartTime=$since.ToLocalTime()} -ErrorAction SilentlyContinue | Where-Object {$_.Message -match 'clubtivi.exe|BobTV.exe'})
@{version=(Get-Item "$app\clubtivi.exe").VersionInfo.FileVersion;pid=$live[0].Id;responding=$live[0].Responding;
 hashMatches=((Get-FileHash "$app\data\app.so").Hash -eq (Get-FileHash "$bundle\data\app.so").Hash);
 events=@($current.event | Select-Object -Unique);errors=@($current | Where-Object {$_.event -match 'error|fatal|exception'} | Select-Object time,event);
 video=@($current | Where-Object {$_.event -eq 'video_decoder_metrics'} | Select-Object time,channel,width,height,buffering,properties);
 nativeErrorCount=$native.Count;healthy=(Test-Path "$root\Update\startup.healthy");candidate=(Test-Path "$root\Update\candidate.ini")
}|ConvertTo-Json -Depth 5
