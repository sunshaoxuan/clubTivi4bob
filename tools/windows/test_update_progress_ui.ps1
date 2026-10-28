param([string]$ExecutablePath=$env:BOBTV_PROGRESS_FIXTURE_EXE)
$ErrorActionPreference='Stop'
if($env:CI -ne 'true'){throw 'UI fixture is restricted to CI'}
$root=Join-Path $env:TEMP ('BobTVUpdaterTests\progress-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force|Out-Null
$script=Join-Path $root 'progress_ui.ps1'
$text=[IO.File]::ReadAllText((Join-Path $env:GITHUB_WORKSPACE 'assets\updater\progress_ui.ps1'))
[IO.File]::WriteAllText($script,$text,(New-Object Text.UTF8Encoding($true)))
$env:BOBTV_PROGRESS_CAPTURE_DIR=Join-Path $root 'screenshots'
$file=Join-Path $root 'status-preview.json'
if(!$ExecutablePath -or !(Test-Path -LiteralPath $ExecutablePath -PathType Leaf)){throw 'A versioned BobTV fixture executable is required (it is never launched)'}
Copy-Item -LiteralPath $ExecutablePath -Destination "$root\BobTV.exe"
$fixtureVersion=(Get-Item "$root\BobTV.exe").VersionInfo.FileVersion
New-Item -ItemType Directory -Path "$root\data" | Out-Null
[IO.File]::WriteAllText("$root\data\app.so",'fixture')
function Set-State([string]$phase,[Nullable[int]]$percent,[bool]$cancelled=$false){
  $payload=@{phase=$phase;version=$fixtureVersion;runId='preview';workerPid=$PID;
    percent=$percent;message='BobTV updater fixture';receivedBytes=25000000;totalBytes=68000000;
    requiresAuthorization=$true;authorizationCancelled=$cancelled;oldVersion=$fixtureVersion}|ConvertTo-Json -Compress
  $temporary=$file+'.tmp'
  [IO.File]::WriteAllText($temporary,$payload,(New-Object Text.UTF8Encoding($false)))
  for($attempt=0;;$attempt++){
    try{
      if(Test-Path $file){[IO.File]::Replace($temporary,$file,[NullString]::Value,$true)}else{[IO.File]::Move($temporary,$file)}
      break
    }catch [IO.IOException]{if($attempt -ge 99){throw};Start-Sleep -Milliseconds 20}
  }
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
  foreach($phase in @('verifying','backingUp','authorizing','awaitingExit','installing','installed','failed')){
    Set-State $phase $(if($phase -in @('authorizing','awaitingExit','installing')){$null}else{100})
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
  Set-State ready 100 $true
  for($n=0;$n -lt 30 -and !(Test-Path "$root\screenshots\ready.json");$n++){Start-Sleep -Milliseconds 500}
  $snapshot=Get-Content "$root\screenshots\ready.json" -Raw|ConvertFrom-Json
  if(!$snapshot.launchEnabled -or $snapshot.launchText -ne '继续使用当前版本'){throw 'Cancellation does not offer the unchanged old version'}
  Move-Item "$root\BobTV.exe" "$root\hidden-BobTV.exe"
  Remove-Item "$root\screenshots\installed.json","$root\screenshots\installed.png"
  Set-State installed 100
  Start-Sleep -Seconds 2
  $snapshot=Get-Content "$root\screenshots\installed.json" -Raw|ConvertFrom-Json
  if($snapshot.launchEnabled){throw 'Launch enabled with missing application'}
  Write-Output 'PASS: download/consent/exit/install stages drawn, launch disabled until verified install, safe cancellation offers old version, missing executable cannot launch.'
}finally{
  $child.Refresh()
  if(!$child.HasExited){Stop-Process -Id $child.Id -Force}
  $destination=Join-Path $env:GITHUB_WORKSPACE 'windows-live-update-diagnostics\standalone-progress'
  New-Item -ItemType Directory -Path $destination -Force|Out-Null
  Copy-Item "$root\*" $destination -Recurse -Force
  Remove-Item Env:BOBTV_PROGRESS_CAPTURE_DIR -ErrorAction SilentlyContinue
}
