$ErrorActionPreference = 'Stop'
$qa = 'C:\Users\sunsx\src\BobTV-window-qa-20261012'
$report = Join-Path $qa 'window-report.json'
[pscustomobject]@{
  buildSucceeded = Test-Path -LiteralPath (Join-Path $qa 'build-success.txt')
  buildTail = if ([IO.File]::Exists((Join-Path $qa 'build.log')) -and [IO.FileInfo]::new((Join-Path $qa 'build.log')).Length -gt 0) { @(Get-Content -LiteralPath (Join-Path $qa 'build.log') -Tail 6) } else { @() }
  buildErrors = if ([IO.File]::Exists((Join-Path $qa 'build-errors.log')) -and [IO.FileInfo]::new((Join-Path $qa 'build-errors.log')).Length -gt 0) { @(Get-Content -LiteralPath (Join-Path $qa 'build-errors.log') -Tail 8) } else { @() }
  report = if (Test-Path -LiteralPath $report) { Get-Content -Raw -LiteralPath $report | ConvertFrom-Json } else { $null }
} | ConvertTo-Json -Depth 8 -Compress
