param(
 [Parameter(Mandatory=$true)][string]$JobDirectory,
 [Parameter(Mandatory=$true)][string]$FlutterPath,
 [Parameter(Mandatory=$true)][string]$MediaPath,
 [string]$SourceDirectory,
 [switch]$PlayerServiceOnly,
 [switch]$UseExistingBuild,
 [switch]$LongSoak
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
Start-Transcript -LiteralPath (Join-Path $JobDirectory 'regression-build.log')
try {
 $source=if($SourceDirectory){$SourceDirectory}else{Join-Path $JobDirectory 'source'}
 Set-Location -LiteralPath $source
 $before=@(Get-CimInstance Win32_Process | Where-Object {$_.Name -eq 'BobTV.exe'} | Select-Object ProcessId,ExecutablePath)
 if(!$UseExistingBuild) {
  & $FlutterPath pub get
  if($LASTEXITCODE -ne 0){throw 'Fixture dependency resolution failed'}
  & $FlutterPath build windows --release --no-pub --target tools/diagnostics/player_lifecycle_probe.dart
  if($LASTEXITCODE -ne 0){throw 'Native Windows fixture build failed'}
 }
 $exe=Join-Path $source 'build/windows/x64/runner/Release/clubtivi.exe'
 if(!(Test-Path -LiteralPath $exe)){$exe=Join-Path $source 'build/windows/x64/runner/Release/BobTV.exe'}
 if(!(Test-Path -LiteralPath $exe)){throw 'Fixture executable missing'}
 Write-Output ('Verified fixture '+$exe+' SHA256 '+(Get-FileHash -LiteralPath $exe).Hash)
 $results=@()
 $cases=if($PlayerServiceOnly){@(@{name='native-close-idle';mode='native_close';seconds=10;cycles=3},@{name='explicit-close';mode='explicit_exit';seconds=10;cycles=3})}else{@(@{name='native-close-idle';mode='native_close';seconds=600;cycles=20},@{name='explicit-close';mode='explicit_exit';seconds=5;cycles=3})}
 if($LongSoak){$cases[0].seconds=600;$cases[0].cycles=20}
 if($PlayerServiceOnly -and $LongSoak){$cases=@(@{name='native-preflight';mode='native_close';seconds=10;cycles=3},@{name='explicit-preflight';mode='explicit_exit';seconds=10;cycles=3})+$cases}
 foreach($case in $cases) {
  $output=Join-Path $JobDirectory $case.name
  if(Test-Path -LiteralPath $output){throw 'Preserve previous fixture result'}
  New-Item -ItemType Directory -Path $output|Out-Null
  $env:BOBTV_LIFECYCLE_REPORT=$output
  $env:BOBTV_LIFECYCLE_MEDIA=$MediaPath
  $env:BOBTV_LIFECYCLE_SECONDS=[string]$case.seconds
  $env:BOBTV_LIFECYCLE_CYCLES=[string]$case.cycles
  $env:BOBTV_LIFECYCLE_EXIT=$case.mode
  $env:BOBTV_LIFECYCLE_SERVICE=if($PlayerServiceOnly){'1'}else{'0'}
  $p=Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe) -RedirectStandardOutput (Join-Path $output 'stdout.log') -RedirectStandardError (Join-Path $output 'stderr.log') -PassThru
  $deadline=[DateTime]::UtcNow.AddSeconds($case.seconds+240)
  while(!$p.HasExited -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Seconds 5;$p.Refresh()}
  if(!$p.HasExited){
   $current=Get-CimInstance Win32_Process -Filter ('ProcessId='+$p.Id)
   if($current.ExecutablePath -eq $exe){Stop-Process -Id $p.Id}
   throw 'Fixture timed out; only its exact PID was stopped'
  }
  $p.WaitForExit()
  if($p.ExitCode -ne 0){throw ('Native fixture exited with '+$p.ExitCode)}
  $events=@(Get-Content -LiteralPath (Join-Path $output 'probe.jsonl') | ForEach-Object {$_|ConvertFrom-Json})
  if(@($events|Where-Object {$_.event -eq 'failed' -or $_.event -eq 'flutter_error'}).Count){throw 'Fixture recorded a failure'}
  if(@($events|Where-Object {$_.event -eq 'preview_cycle_passed'}).Count -ne $case.cycles){throw 'Decoder cycles incomplete'}
  if(@($events|Where-Object {$_.event -eq 'idle_passed'}).Count -ne 1){throw 'Idle playback acceptance missing'}
  $diag=@(Get-ChildItem -LiteralPath (Join-Path $output 'diagnostics') -Filter '*.log' | ForEach-Object {Get-Content -LiteralPath $_.FullName} | ForEach-Object {$_|ConvertFrom-Json})
  $drain=@($diag|Where-Object {$_.event -eq 'desktop_resources_drained'})
  if($drain.Count -ne 1 -or $drain[0].players -ne 0){throw 'Native player barrier did not complete'}
  if(@($diag|Where-Object {$_.event -eq 'desktop_exit_cleanup_completed'}).Count -ne 1){throw 'Exit cleanup acknowledgement missing'}
  if(@($diag|Where-Object {$_.event -eq 'application_stopped'}).Count -ne 1){throw 'Clean shutdown marker missing'}
  if($PlayerServiceOnly -and (@($diag|Where-Object {$_.event -eq 'player_disposing'}).Count -ne 1 -or @($events|Where-Object {$_.event -eq 'production_player_service_ready'}).Count -ne 1)){throw 'Production PlayerService cleanup was not exercised'}
  if(Test-Path -LiteralPath (Join-Path $output 'diagnostics/active_session.json')){throw 'Unclean-session marker retained'}
  $results+=@{name=$case.name;pid=$p.Id;exitCode=$p.ExitCode;seconds=$case.seconds;cycles=$case.cycles;resourcesAfterCleanup=0;idle=($events|Where-Object {$_.event -eq 'idle_passed'});decoders=@($events|Where-Object {$_.event -eq 'decoder_ready'});passed=$true}
 }
 $after=@(Get-CimInstance Win32_Process | Where-Object {$_.Name -eq 'BobTV.exe'} | Select-Object ProcessId,ExecutablePath)
 @{platform='windows-x64';results=$results;installedProcessesBefore=$before;installedProcessesAfter=$after;installedAppsReplacedOrStopped=$false;passed=$true}|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $JobDirectory 'qa-success.json') -Encoding utf8
} catch {
 $_|Out-String|Set-Content -LiteralPath (Join-Path $JobDirectory 'qa-failed.txt')
 throw
} finally {Stop-Transcript}
