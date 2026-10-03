$ErrorActionPreference = 'Stop'
if ($env:CI -ne 'true') { throw 'Rollback fixtures are restricted to CI' }
$env:BOBTV_UPDATE_TESTING = '1'
$fixture = Join-Path $env:TEMP ('BobTVUpdaterTests\rollback-' + [guid]::NewGuid().ToString('N'))
$root = Join-Path $fixture 'Update'
$app = Join-Path $fixture 'App'
$backup = Join-Path $root 'Backups\previous'
foreach ($directory in @("$app\data", "$backup\data")) {
  New-Item -ItemType Directory -Path $directory -Force | Out-Null
}
[IO.File]::WriteAllText("$app\data\app.so", 'candidate')
[IO.File]::WriteAllText("$backup\data\app.so", 'previous')
[IO.File]::WriteAllText("$app\new-only.txt", 'new-only')
[IO.File]::WriteAllText("$root\new-files.txt", "new-only.txt`n")
$version = '0.9.1+999'
[IO.File]::WriteAllText("$root\candidate.ini", "[Update]`nVersion=$version`nAppDir=$app`nBackupDir=$backup`nAttempts=0`n")
$worker = Join-Path $PSScriptRoot '..\..\assets\updater\worker.ps1'
for ($attempt = 1; $attempt -le 3; $attempt++) {
  [IO.File]::WriteAllText("$root\startup.marker", '99999999')
  & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $worker -Mode Monitor -CurrentPid 99999999 -TestRoot $root
  if ($LASTEXITCODE -ne 0) { throw "Monitor failed at attempt $attempt" }
  if ($attempt -lt 3) {
    if ([IO.File]::ReadAllText("$root\candidate.ini") -notmatch "Attempts=$attempt") { throw 'Failure count incorrect' }
    if ([IO.File]::ReadAllText("$app\data\app.so") -ne 'candidate') { throw 'Rollback occurred too early' }
  }
}
if ([IO.File]::ReadAllText("$app\data\app.so") -ne 'previous') { throw 'Previous package not restored' }
if ((Test-Path "$app\new-only.txt") -or (Test-Path "$root\candidate.ini")) { throw 'Candidate files were not cleared' }
if ([IO.File]::ReadAllText("$root\skipped_versions.txt").Trim() -ne $version) { throw 'Failed version not skipped' }
$report = Get-Content "$root\failure-0.9.1_999.json" -Raw | ConvertFrom-Json
if ($report.failedVersion -ne $version) { throw 'Failure upload queue missing' }
$status = Get-Content "$root\status.json" -Raw | ConvertFrom-Json
if ($status.phase -ne 'failed') { throw 'Rollback status missing' }
Write-Output 'PASS: Windows three failed startups restore backup, skip candidate, retain failure report and remove newly introduced files.'

[IO.File]::WriteAllText("$root\candidate.ini", "[Update]`nVersion=$version`nAppDir=$app`nBackupDir=$backup`nAttempts=2`n")
[IO.File]::WriteAllText("$root\startup.marker", '99999999')
[IO.File]::WriteAllText("$root\startup.healthy", '99999999')
& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $worker -Mode Monitor -CurrentPid 99999999 -TestRoot $root
if ($LASTEXITCODE -ne 0 -or [IO.File]::ReadAllText("$root\candidate.ini") -notmatch 'Attempts=0') { throw 'Healthy acknowledgement did not reset failures' }
if ((Test-Path "$root\startup.marker") -or (Test-Path "$root\startup.healthy")) { throw 'Healthy markers not cleared' }
Write-Output 'PASS: Windows healthy startup resets the consecutive failure counter.'
