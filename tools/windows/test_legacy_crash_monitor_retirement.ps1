$ErrorActionPreference='Stop'
$source=Join-Path $PSScriptRoot '..\..'
foreach($relative in @('assets\updater\worker.ps1','assets\updater\installer_worker.ps1')){
  $text=[IO.File]::ReadAllText((Join-Path $source $relative),[Text.Encoding]::UTF8)
  $tokens=$null;$errors=$null
  $null=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
  if($errors.Count){throw ($errors|Out-String)}
  if($text -match 'Resume-AppCrashMonitor|resumeCrashMonitor|Resumed BobTV crash monitor'){
    throw ('Legacy monitor restart remains in '+$relative)
  }
  if($text -notmatch 'Suspend-AppCrashMonitor'){throw 'Scoped legacy monitor stop helper missing'}
}

$fixture=Join-Path $env:TEMP ('BobTVUpdaterTests\retired-monitor-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -Force|Out-Null
$tripwire=Join-Path $fixture 'must-not-run.ps1'
[IO.File]::WriteAllText($tripwire,"throw 'Retired ProcDump entry point ran'")
$dumps=Join-Path $fixture 'must-not-create'
function Start-Process {throw 'Retired monitor attempted to launch a process'}
function Start-ScheduledTask {throw 'Retired monitor attempted to start a task'}
try {
  $watch=[Diagnostics.Stopwatch]::StartNew()
  & (Join-Path $source 'tools\windows\hoteltv_crash_monitor.ps1') -ProcDumpPath $tripwire -DumpFolder $dumps
  if($watch.Elapsed.TotalSeconds -gt 2){throw 'Retired monitor did not return promptly'}
  if(Test-Path -LiteralPath $dumps){throw 'Retired monitor wrote a dump directory'}
}finally{
  Remove-Item Function:Start-Process,Function:Start-ScheduledTask -ErrorAction SilentlyContinue
}

$native=[IO.File]::ReadAllText((Join-Path $source 'windows\runner\crash_handler.cpp'))
$entry=[IO.File]::ReadAllText((Join-Path $source 'windows\runner\main.cpp'))
foreach($required in @('SetUnhandledExceptionFilter','MiniDumpWriteDump','native_process_started')){
  if(!$native.Contains($required)){throw ('Native crash recorder missing '+$required)}
}
if(!$entry.Contains('InstallCrashHandler();')){throw 'Native startup crash hook missing'}
$sourceRoot=$source
foreach($builder in @('build_release_bundle.ps1','build_arm64.ps1')){
  $tokens=$null;$errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $sourceRoot ('tools\windows\'+$builder)),[ref]$tokens,[ref]$errors)
  if($errors.Count){throw ($errors|Out-String)}
  $overlay=@($ast.FindAll({param($node)
    $node -is [Management.Automation.Language.CommandAst] -and
    $node.GetCommandName() -eq 'Copy-Item' -and
    $node.Extent.Text.Contains('tools/windows/hoteltv_crash_monitor.ps1') -and
    $node.Extent.Text.Contains('Tools/hoteltv_crash_monitor.ps1')
  },$true))
  if($overlay.Count -ne 1){throw ('Retired monitor packaging overlay missing: '+$builder)}
  $bundle=Join-Path $fixture $builder
  New-Item -ItemType Directory -Path (Join-Path $bundle 'Tools') -Force|Out-Null
  $destination=Join-Path $bundle 'Tools/hoteltv_crash_monitor.ps1'
  [IO.File]::WriteAllText($destination,"throw 'Old support bundle entry ran'")
  $StagingDirectory=$sourceRoot;$source=$sourceRoot
  . ([scriptblock]::Create($overlay[0].Extent.Text))
  if([IO.File]::ReadAllText($destination) -ne [IO.File]::ReadAllText((Join-Path $sourceRoot 'tools/windows/hoteltv_crash_monitor.ps1'))){
    throw ('Packaging retained old monitor: '+$builder)
  }
  & $destination -ProcDumpPath $tripwire -DumpFolder $dumps
}
Write-Output 'PASS: both updater paths have no monitor restart, retired entry and both package overlays are inert, native crash hooks retained.'
