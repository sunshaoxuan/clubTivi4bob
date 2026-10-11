$ErrorActionPreference = 'Stop'
$apps = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
  $_.ProcessName -in @('BobTV', 'clubtivi')
} | ForEach-Object {
  [pscustomobject]@{
    id = $_.Id
    session = $_.SessionId
    responding = $_.Responding
    executable = $_.Path
    version = if ($_.Path) { (Get-Item -LiteralPath $_.Path).VersionInfo.FileVersion } else { $null }
    windowHandle = $_.MainWindowHandle.ToInt64()
  }
})
$source = 'C:\Users\sunsx\src\B84'
[pscustomobject]@{
  hostName = $env:COMPUTERNAME
  apps = $apps
  sourcePresent = Test-Path -LiteralPath (Join-Path $source 'pubspec.yaml')
  sourceVersion = if (Test-Path -LiteralPath (Join-Path $source 'pubspec.yaml')) {
    (Select-String -LiteralPath (Join-Path $source 'pubspec.yaml') -Pattern '^version:').Line
  } else { $null }
  flutterAvailable = [bool](Get-Command flutter.bat -ErrorAction SilentlyContinue)
} | ConvertTo-Json -Depth 5 -Compress
