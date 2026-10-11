$ErrorActionPreference = 'Stop'
$qa = 'C:\Users\sunsx\src\BobTV-window-qa-20261012'
$flutter = 'C:\Users\sunsx\src\flutter\bin\flutter.bat'
if (!(Test-Path -LiteralPath $flutter)) { throw 'Known Windows Flutter SDK is missing' }
if (!(Test-Path -LiteralPath (Join-Path $qa 'tools\windows\fullscreen_validation.dart'))) { throw 'QA fixture is missing' }
Set-Location $qa
& $flutter pub get --offline
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $flutter build windows --release --no-pub -t tools/windows/fullscreen_validation.dart
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
[IO.File]::WriteAllText((Join-Path $qa 'build-success.txt'), 'PASS: independent Windows fullscreen fixture')
