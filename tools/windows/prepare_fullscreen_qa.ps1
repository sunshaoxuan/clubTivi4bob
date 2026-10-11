$ErrorActionPreference = 'Stop'
$source = 'C:\Users\sunsx\src\B84'
$qa = 'C:\Users\sunsx\src\BobTV-window-qa-20261012'
if (!(Test-Path -LiteralPath (Join-Path $source 'pubspec.yaml'))) { throw 'Known build source is missing' }
if (Test-Path -LiteralPath $qa) { throw 'QA directory already exists; preserve its evidence' }
New-Item -ItemType Directory -Path $qa | Out-Null
& robocopy.exe $source $qa /E /XD .git build .dart_tool (Join-Path $source 'windows\flutter\ephemeral') /XF *.gz /R:0 /W:0 /NFL /NDL /NJH /NJS | Out-Null
if ($LASTEXITCODE -gt 7) { throw 'Isolated source copy failed' }
# This fixture must never participate in the installed application's updater
# startup counters or crash-monitor state.
$main = Join-Path $qa 'windows\runner\main.cpp'
$text = [IO.File]::ReadAllText($main)
if (!$text.Contains('if (!PrepareUpdateLaunch()) {')) { throw 'Unexpected Windows runner' }
$text = $text.Replace('InstallCrashHandler();', '/* Isolated window QA: no production crash monitor. */')
$text = $text.Replace('if (!PrepareUpdateLaunch()) {', 'if (false) { /* Isolated QA skips update startup state. */')
$text = $text.Replace('RecordNativeShutdown();', '/* Isolated QA: no production shutdown state. */')
$text = $text.Replace('RecordNormalUpdateShutdown();', '/* Isolated QA: no production updater health marker. */')
[IO.File]::WriteAllText($main, $text, [Text.UTF8Encoding]::new($false))
[pscustomobject]@{qa=$qa; installedApplicationUnchanged=$true} | ConvertTo-Json -Compress
