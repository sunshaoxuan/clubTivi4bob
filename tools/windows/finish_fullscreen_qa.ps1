$ErrorActionPreference = 'Stop'
$qa = 'C:\Users\sunsx\src\BobTV-window-qa-20261012'
$report = Get-Content -LiteralPath (Join-Path $qa 'window-report.json') -Raw | ConvertFrom-Json
if (!$report.passed) { throw 'Preserve the failed QA task for investigation' }
$apps = @(Get-Process -Name clubtivi -ErrorAction SilentlyContinue | Where-Object { $_.Path.StartsWith($qa) })
if ($apps.Count -gt 0) { throw 'QA has not finished; do not interrupt applications' }
$task = 'BobTV Fullscreen QA 20261012'
if (Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue) {
  Unregister-ScheduledTask -TaskName $task -Confirm:$false
}
$update = 'C:\Users\sunsx\AppData\Local\HotelTV\Update'
$healthy = Join-Path $update 'startup.healthy'
$quarantined = Join-Path $qa 'isolated-native-health-marker.backup'
$markerMoved = $false
if ((Test-Path -LiteralPath $healthy) -and !(Test-Path -LiteralPath $quarantined)) {
  $file = Get-Item -LiteralPath $healthy
  $reportFile = Get-Item -LiteralPath (Join-Path $qa 'window-report.json')
  $seconds = ($file.LastWriteTimeUtc - $reportFile.LastWriteTimeUtc).TotalSeconds
  $production = @(Get-Process -Name BobTV,clubtivi -ErrorAction SilentlyContinue)
  # Older runners call RecordNormalUpdateShutdown after the fixture closes.
  # Preserve a marker written by this QA shutdown separately, so that an
  # isolated geometry test cannot validate a production update candidate.
  if ($file.Length -eq 0 -and $seconds -ge 0 -and $seconds -le 5 -and $production.Count -eq 0) {
    Move-Item -LiteralPath $healthy -Destination $quarantined
    $markerMoved = $true
  }
}
$markers = @('candidate.ini', 'startup.marker', 'startup.healthy') | ForEach-Object {
  $path = Join-Path $update $_
  if (Test-Path -LiteralPath $path) { Get-Item -LiteralPath $path | Select-Object Name,LastWriteTimeUtc,Length }
}
[pscustomobject]@{taskRemoved=$task;qaPassed=$true;qaProcessExited=$true;isolatedHealthMarkerMoved=$markerMoved;isolatedHealthMarkerBackup=$quarantined;updateMarkerTimes=$markers} | ConvertTo-Json -Depth 4 -Compress
