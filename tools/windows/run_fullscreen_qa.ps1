$ErrorActionPreference = 'Stop'
$qa = 'C:\Users\sunsx\src\BobTV-window-qa-20261012'
if (!(Test-Path -LiteralPath (Join-Path $qa 'build-success.txt'))) { throw 'Independent QA build has not succeeded' }
$release = Join-Path $qa 'build\windows\x64\runner\Release'
$candidates = @('BobTV.exe', 'clubtivi.exe') | ForEach-Object { Join-Path $release $_ } | Where-Object { Test-Path -LiteralPath $_ }
if (@($candidates).Count -ne 1) { throw 'Expected exactly one QA executable' }
$exe = @($candidates)[0]
$report = Join-Path $qa 'window-report.json'
if (Test-Path -LiteralPath $report) { throw 'Preserve the earlier QA report' }
$task = 'BobTV Fullscreen QA 20261012'
if (Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue) { throw 'Preserve the earlier QA task' }
$action = New-ScheduledTaskAction -Execute $exe -Argument ('"--report='+$report+'"') -WorkingDirectory (Split-Path $exe)
$principal = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\sunsx" -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 3)
Register-ScheduledTask -TaskName $task -Action $action -Principal $principal -Settings $settings | Out-Null
Start-ScheduledTask -TaskName $task
[pscustomobject]@{task=$task;report=$report;installedApplicationUnchanged=$true} | ConvertTo-Json -Compress
