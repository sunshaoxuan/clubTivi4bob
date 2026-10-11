$ErrorActionPreference = 'Stop'
$qa = 'C:\Users\sunsx\src\BobTV-window-qa-20261012'
$apps = @(Get-Process -Name clubtivi -ErrorAction SilentlyContinue | Where-Object { $_.Path.StartsWith($qa) } | Select-Object Id,Path,Responding,MainWindowTitle,MainWindowHandle)
[pscustomobject]@{apps=$apps;reportPresent=(Test-Path -LiteralPath (Join-Path $qa 'window-report.json'))} | ConvertTo-Json -Depth 4 -Compress
