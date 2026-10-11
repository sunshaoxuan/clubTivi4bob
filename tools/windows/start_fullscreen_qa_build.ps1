$ErrorActionPreference = 'Stop'
$qa = 'C:\Users\sunsx\src\BobTV-window-qa-20261012'
$script = Join-Path $qa 'tools\windows\build_fullscreen_qa.ps1'
$process = Start-Process powershell.exe -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ('"'+$script+'"')) -WindowStyle Hidden -RedirectStandardOutput (Join-Path $qa 'build.log') -RedirectStandardError (Join-Path $qa 'build-errors.log') -PassThru
[pscustomobject]@{qa=$qa;buildPid=$process.Id} | ConvertTo-Json -Compress
