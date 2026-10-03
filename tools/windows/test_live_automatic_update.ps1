param([string]$FixtureExecutable, [switch]$CloseWhileDownloading)
$ErrorActionPreference='Stop'
if($env:CI -ne 'true'){throw 'This clean-install GUI test is restricted to CI'}
$site='https://bobtv.briconbric.com'
$manifest=Invoke-RestMethod "$site/updates/windows-x64/latest.json"
$fixture=Join-Path $env:TEMP ('BobTVUpdaterTests\gui-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -Force|Out-Null
if($FixtureExecutable){
  $exe=(Resolve-Path -LiteralPath $FixtureExecutable).Path
}else{
  Invoke-WebRequest "$site/downloads/BobTV-0.9.1+68-windows-x64.zip" -OutFile "$fixture\previous.zip"
  Expand-Archive -LiteralPath "$fixture\previous.zip" -DestinationPath "$fixture\Previous"
  $exe=(Get-ChildItem "$fixture\Previous" -Recurse -File|Where-Object Name -eq 'BobTV.exe'|Select-Object -First 1).FullName
}
if(!$exe -or (Get-Item $exe).VersionInfo.FileVersion -ne '0.9.1+68'){throw 'Previous GUI missing'}
$savedLocalAppData=$env:LOCALAPPDATA
$env:LOCALAPPDATA=Join-Path $fixture 'LocalAppData'
$env:BOBTV_PROGRESS_CAPTURE_DIR=Join-Path $fixture 'progress-screenshots'
$root=Join-Path $env:LOCALAPPDATA 'HotelTV\Update'
$appProcess=$null
function Stop-TestApp {
  if(!$appProcess){return}
  $appProcess.Refresh()
  if($appProcess.HasExited){return}
  [void]$appProcess.CloseMainWindow()
  if(!$appProcess.WaitForExit(10000)){Stop-Process -Id $appProcess.Id -Force}
}
try{
  $appProcess=Start-Process $exe -WorkingDirectory (Split-Path $exe) -PassThru
  $ready=$false
  $closedEarly=$false
  for($n=0;$n -lt 300;$n++){
    $appProcess.Refresh()
    if($appProcess.HasExited -and !$closedEarly){throw 'Previous GUI exited before update discovery'}
    if($n % 60 -eq 0){
      Write-Output "GUI PID $($appProcess.Id), update root $root, wait $n seconds"
      Get-ChildItem $root -ErrorAction SilentlyContinue|Select-Object Name,Length
      Get-CimInstance Win32_Process -Filter "name='powershell.exe'"|
        Select-Object ProcessId,ParentProcessId,CommandLine|Format-List
    }
    if(Test-Path "$root\status.json"){
      $status=Get-Content "$root\status.json" -Raw|ConvertFrom-Json
      if($status.phase -eq 'ready' -and $status.version -eq $manifest.version){$ready=$true;break}
      if($status.phase -eq 'failed'){throw 'GUI update worker failed'}
      if($CloseWhileDownloading -and !$closedEarly -and $status.phase -eq 'downloading'){
        Stop-TestApp; $closedEarly=$true
        Write-Output 'Closed the player while the actual updater was downloading.'
      }
      if($closedEarly -and $status.phase -eq 'installed'){$ready=$true;break}
    }
    Start-Sleep -Seconds 1
  }
  if(!$ready){throw 'Previous GUI did not automatically discover and download the website update'}
  if(!$closedEarly -and (Get-Item $exe).VersionInfo.FileVersion -ne '0.9.1+68'){throw 'Installed before old app exited'}
  Stop-TestApp
  $installed=$false
  for($n=0;$n -lt 120;$n++){
    $completed=if(Test-Path "$root\status.json"){Get-Content "$root\status.json" -Raw|ConvertFrom-Json}
    if((Get-Item $exe).VersionInfo.FileVersion -eq $manifest.version -and
       (!$FixtureExecutable -or $completed.phase -eq 'installed')){$installed=$true;break}
    Start-Sleep -Seconds 1
  }
  if(!$installed){throw 'New GUI was not installed after exit'}
  $finished=Get-Content "$root\status.json" -Raw|ConvertFrom-Json
  if($FixtureExecutable -and $finished.phase -ne 'installed'){throw 'Missing explicit installation-complete status'}
  if($FixtureExecutable){
    for($n=0;$n -lt 20;$n++){
      $ui=Get-Content "$root\progress-ui.log" -Raw -ErrorAction SilentlyContinue
      if($ui -match 'window_shown'){break}
      Start-Sleep -Seconds 1
    }
    if($ui -notmatch 'window_shown'){throw 'Independent update window did not report being shown'}
  }
  $backup=Get-ChildItem "$root\Backups" -Directory|Select-Object -First 1
  if(!$backup -or (Get-Item (Join-Path $backup.FullName 'BobTV.exe')).VersionInfo.FileVersion -ne '0.9.1+68'){
    throw 'Previous GUI backup missing'
  }
  $appProcess=Start-Process $exe -WorkingDirectory (Split-Path $exe) -PassThru
  $healthy=$false
  for($n=0;$n -lt 120;$n++){
    $appProcess.Refresh()
    if($appProcess.HasExited){throw 'New GUI exited before startup acknowledgement'}
    if((Test-Path "$root\startup.healthy") -and
      ([IO.File]::ReadAllText("$root\startup.healthy").Trim() -eq [string]$appProcess.Id)){
      $healthy=$true;break
    }
    Start-Sleep -Seconds 1
  }
  if(!$healthy){throw 'New GUI did not acknowledge startup health'}
  Start-Sleep -Seconds 20
  $appProcess.Refresh()
  if($appProcess.HasExited){throw 'New GUI exited after startup acknowledgement'}
  Write-Output "PASS: Windows old GUI discovered and downloaded $($manifest.version), installed after exit, preserved +68 and acknowledged healthy startup."
}finally{
  Stop-TestApp
  $diagnostics=Join-Path $env:GITHUB_WORKSPACE 'windows-live-update-diagnostics'
  New-Item -ItemType Directory -Path $diagnostics -Force|Out-Null
  foreach($directory in @($root,(Join-Path $env:LOCALAPPDATA 'HotelTV\Logs'),
      (Join-Path $savedLocalAppData 'HotelTV\Update'))){
    if(Test-Path $directory){
      Get-ChildItem $directory -File | Where-Object Extension -in @('.log','.json','.ini','.txt','.ps1') |
        Copy-Item -Destination $diagnostics -Force
    }
  }
  if(Test-Path $env:BOBTV_PROGRESS_CAPTURE_DIR){Copy-Item $env:BOBTV_PROGRESS_CAPTURE_DIR $diagnostics -Recurse -Force}
  Remove-Item Env:BOBTV_PROGRESS_CAPTURE_DIR -ErrorAction SilentlyContinue
  $worker=Join-Path $root 'worker.ps1'
  if(Test-Path $worker){
    & powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass `
      -File $worker -Mode Monitor -CurrentPid 99999999 2>&1 | Out-File "$diagnostics\worker-launch-probe.log"
  }
  Get-ChildItem $diagnostics -File | ForEach-Object {
    Write-Output $_.Name
    Get-Content $_.FullName -Tail 30
  }
  $env:LOCALAPPDATA=$savedLocalAppData
}
