$ErrorActionPreference='Continue'
$ProgressPreference='SilentlyContinue'
quser
Get-CimInstance Win32_Process | Where-Object {$_.Name -eq 'clubtivi.exe' -or ($_.Name -eq 'powershell.exe' -and $_.CommandLine -like '*BobTV-Release105-visual.ps1*')} | Select-Object ProcessId,SessionId,CommandLine | ConvertTo-Json -Compress
Get-ChildItem 'C:\Users\sunsx\AppData\Local\HotelTV\Logs' -File | Sort-Object LastWriteTime -Descending | Select-Object -First 5 Name,Length,LastWriteTime | ConvertTo-Json -Compress
Get-ChildItem 'C:\Users\sunsx\AppData\Local\HotelTV\Update' -File | Where-Object {$_.Name -in @('startup.marker','startup.healthy','candidate.ini')} | Select-Object Name,LastWriteTime | ConvertTo-Json -Compress
Get-Date -Format o
