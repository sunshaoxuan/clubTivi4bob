param(
  [string]$ProcDumpPath = 'C:\Users\sunsx\Apps\HotelTV\Tools\procdump64.exe',
  [string]$DumpFolder = 'C:\Users\sunsx\AppData\Local\HotelTV\CrashDumps'
)

$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Path $DumpFolder -Force | Out-Null

while ($true) {
  if (-not (Test-Path -LiteralPath $ProcDumpPath)) {
    Start-Sleep -Seconds 30
    continue
  }

  & $ProcDumpPath -accepteula -ma -e -w clubtivi.exe $DumpFolder
  Start-Sleep -Seconds 2
}
