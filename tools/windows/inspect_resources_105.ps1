$ErrorActionPreference='Continue'
$ProgressPreference='SilentlyContinue'
Get-Process clubtivi,powershell,dart,gen_snapshot,MSBuild,cmake -ErrorAction SilentlyContinue | Select-Object Id,ProcessName,WorkingSet64,HandleCount,@{n='Threads';e={$_.Threads.Count}},StartTime | ConvertTo-Json -Compress
Get-Content 'C:\Users\sunsx\AppData\Local\HotelTV\Update\worker.pid' -ErrorAction SilentlyContinue
Get-Content 'C:\Users\sunsx\AppData\Local\HotelTV\Update\worker.log' -Tail 5 -ErrorAction SilentlyContinue
