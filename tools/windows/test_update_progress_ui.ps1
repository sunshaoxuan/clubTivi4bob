$ErrorActionPreference='Stop'
if($env:CI -ne 'true'){throw 'UI fixture is restricted to CI'}
$root=Join-Path $env:TEMP ('BobTVUpdaterTests\progress-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force|Out-Null
$script=Join-Path $root 'progress_ui.ps1'
$text=[IO.File]::ReadAllText((Join-Path $env:GITHUB_WORKSPACE 'assets\updater\progress_ui.ps1'))
[IO.File]::WriteAllText($script,$text,(New-Object Text.UTF8Encoding($true)))
$env:BOBTV_PROGRESS_CAPTURE_DIR=Join-Path $root 'screenshots'
$file=Join-Path $root 'status-preview.json'
Copy-Item "$PSHOME\powershell.exe" "$root\BobTV.exe"
$fixtureVersion=(Get-Item "$root\BobTV.exe").VersionInfo.FileVersion
New-Item -ItemType Directory -Path "$root\data" | Out-Null
[IO.File]::WriteAllText("$root\data\app.so",'fixture')
function Set-State([string]$phase,[int]$percent){
  $payload=@{phase=$phase;version=$fixtureVersion;runId='preview';workerPid=$PID;
    percent=$percent;message='BobTV updater fixture';receivedBytes=25000000;totalBytes=68000000}|ConvertTo-Json -Compress
  $temporary=$file+'.tmp'
  [IO.File]::WriteAllText($temporary,$payload,(New-Object Text.UTF8Encoding($false)))
  if(Test-Path $file){[IO.File]::Replace($temporary,$file,[NullString]::Value,$true)}else{[IO.File]::Move($temporary,$file)}
}
Set-State downloading 37
$child=Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList @(
  '-NoProfile','-NonInteractive','-STA','-ExecutionPolicy','Bypass','-File',('"'+$script+'"'),
  '-CurrentPid','99999999','-WorkerPid',"$PID",'-Version',('"'+$fixtureVersion+'"'),'-RunId','preview',
  '-AppDir',('"'+$root+'"')) -RedirectStandardError "$root\stderr.log" -RedirectStandardOutput "$root\stdout.log"
try{
  for($n=0;$n -lt 30;$n++){
    $child.Refresh()
    if($child.HasExited){throw ('Progress UI exited: '+[IO.File]::ReadAllText("$root\stderr.log"))}
    if(Test-Path "$root\screenshots\downloading.png"){break}
    Start-Sleep -Seconds 1
  }
  if(!(Test-Path "$root\screenshots\downloading.png")){throw 'Progress UI did not draw downloading state'}
  foreach($phase in @('verifying','backingUp','installing','installed','failed')){
    Set-State $phase 100
    for($n=0;$n -lt 30;$n++){
      if(Test-Path "$root\screenshots\$phase.json"){break}
      Start-Sleep -Milliseconds 500
    }
    if(!(Test-Path "$root\screenshots\$phase.png")){throw "Progress UI did not draw $phase"}
    $snapshot=Get-Content "$root\screenshots\$phase.json" -Raw|ConvertFrom-Json
    if($snapshot.launchEnabled -ne ($phase -eq 'installed')){throw "Launch button unsafe in phase $phase"}
  }
  $snapshot=Get-Content "$root\screenshots\downloading.json" -Raw|ConvertFrom-Json
  if($snapshot.launchEnabled){throw 'Launch enabled while downloading'}
  Move-Item "$root\BobTV.exe" "$root\hidden-BobTV.exe"
  Remove-Item "$root\screenshots\installed.json","$root\screenshots\installed.png"
  Set-State installed 100
  Start-Sleep -Seconds 2
  $snapshot=Get-Content "$root\screenshots\installed.json" -Raw|ConvertFrom-Json
  if($snapshot.launchEnabled){throw 'Launch enabled with missing application'}
  Write-Output 'PASS: six update stages, launch disabled until verified install, disabled on failure and missing executable.'
}finally{
  $child.Refresh()
  if(!$child.HasExited){Stop-Process -Id $child.Id -Force}
  $destination=Join-Path $env:GITHUB_WORKSPACE 'windows-live-update-diagnostics\standalone-progress'
  New-Item -ItemType Directory -Path $destination -Force|Out-Null
  Copy-Item "$root\*" $destination -Recurse -Force
  Remove-Item Env:BOBTV_PROGRESS_CAPTURE_DIR -ErrorAction SilentlyContinue
}
