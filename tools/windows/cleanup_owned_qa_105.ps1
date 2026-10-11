$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
foreach($id in @(18960,25792,28688)) {
 $p=Get-CimInstance Win32_Process -Filter "ProcessId=$id"
 if(!$p){continue}
 $line=[string]$p.CommandLine
 if($line -match '-encodedcommand\s+(\S+)'){$line=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($matches[1]))}
 if($p.Name -ne 'powershell.exe' -or !$line.Contains('BobTV-window-qa-20261012')){throw "QA ownership changed: $id"}
 Stop-Process -Id $id -Force
 @{stoppedOwnedQa=$id}|ConvertTo-Json -Compress
}
Start-Sleep -Seconds 2
$os=Get-CimInstance Win32_OperatingSystem
@{freeMemoryMiB=[math]::Round($os.FreePhysicalMemory/1024);totalMemoryMiB=[math]::Round($os.TotalVisibleMemorySize/1024)}|ConvertTo-Json -Compress
$app=Get-Process clubtivi -ErrorAction SilentlyContinue | Where-Object {$_.Path -eq 'C:\Users\sunsx\Apps\HotelTV\clubtivi.exe'}
$app | Select-Object Id,WorkingSet64,Responding,MainWindowHandle | ConvertTo-Json -Compress
