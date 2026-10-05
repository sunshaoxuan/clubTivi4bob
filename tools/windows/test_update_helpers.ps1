$ErrorActionPreference='Stop'
$tokens=$null;$errors=$null
$source=Join-Path $PSScriptRoot '..\..\assets\updater\worker.ps1'
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
$names=@('Get-Sha256','Copy-AppFile','Copy-Contents','Suspend-AppCrashMonitor')
$definitions=$ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$true)
foreach($definition in $definitions){if($definition.Name -in $names){. ([scriptblock]::Create($definition.Extent.Text))}}
$fixture=Join-Path $env:TEMP ('BobTVUpdaterTests\helper-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$fixture\source\Tools","$fixture\app\Tools" -Force|Out-Null
$file="$fixture\app\Tools\procdump64.exe"
$incoming="$fixture\source\Tools\procdump64.exe"
[IO.File]::WriteAllText($file,'same binary')
[IO.File]::WriteAllText($incoming,'same binary')
$held=[IO.File]::Open($file,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
try {Copy-AppFile $incoming $file;Copy-Contents "$fixture\source" "$fixture\app"}
finally {$held.Dispose()}
[IO.File]::WriteAllText($incoming,'new binary')
Copy-AppFile $incoming $file
if([IO.File]::ReadAllText($file) -ne 'new binary'){throw 'Changed file not installed'}
$script:stopped=@()
$script:mockProcesses=@(
 [pscustomobject]@{ProcessId=101;Name='powershell.exe';CommandLine=('powershell -File "'+$fixture+'\app\Tools\hoteltv_crash_monitor.ps1"');ExecutablePath='C:\Windows\powershell.exe'},
 [pscustomobject]@{ProcessId=102;Name='procdump64.exe';ExecutablePath=$file;CommandLine=''},
 [pscustomobject]@{ProcessId=201;Name='procdump64.exe';ExecutablePath='C:\Unrelated\Tools\procdump64.exe';CommandLine=''},
 [pscustomobject]@{ProcessId=202;Name='powershell.exe';CommandLine='powershell -File "C:\Unrelated\Tools\hoteltv_crash_monitor.ps1"';ExecutablePath='C:\Windows\powershell.exe'}
)
function Get-CimInstance {param($ClassName) return $script:mockProcesses}
function Stop-Process {param($Id,[switch]$Force,$ErrorAction) $script:stopped+= $Id}
function Get-Process {param($Id,$ErrorAction) $p=[pscustomobject]@{Id=$Id};$p|Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {param($milliseconds) return $true};return $p}
function Write-Log {param($message)}
Suspend-AppCrashMonitor "$fixture\app"
if(($script:stopped -join ',') -ne '101,102'){throw 'Monitor stop escaped the application scope'}
if(!$script:resumeCrashMonitor){throw 'Monitor restart intent missing'}
Write-Output 'PASS: identical locked helper skipped, changed files verified, only app-scoped monitor stopped, restart retained.'
