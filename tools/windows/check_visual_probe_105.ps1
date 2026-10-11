$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
Get-ScheduledTask | Where-Object {$_.TaskName -like 'BobTV-Release105-Visual-*'} | ForEach-Object {
 $info=Get-ScheduledTaskInfo -TaskName $_.TaskName
 @{task=$_.TaskName;state=[string]$_.State;result=$info.LastTaskResult;lastRun=$info.LastRunTime}|ConvertTo-Json -Compress
}
Get-ChildItem 'C:\Users\sunsx\src\BobTV-Release105-visual' -ErrorAction SilentlyContinue | Select-Object Name,Length | ConvertTo-Json -Compress
