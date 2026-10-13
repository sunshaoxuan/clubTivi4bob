param([Parameter(Mandatory=$true)][string]$BundleDirectory,
      [Parameter(Mandatory=$true)][string]$SetupPath,
      [Parameter(Mandatory=$true)][string]$SignaturePath)
$ErrorActionPreference='Stop'
if($env:CI -ne 'true'){throw 'Managed updater fixtures are restricted to CI'}
$env:BOBTV_UPDATE_TESTING='1'
$source=Join-Path $PSScriptRoot '..\..\assets\updater'
$version=(Get-Item -LiteralPath (Join-Path $BundleDirectory 'BobTV.exe')).VersionInfo.FileVersion
$signature=[Convert]::ToBase64String([IO.File]::ReadAllBytes($SignaturePath))
$hash=(Get-FileHash -LiteralPath $SetupPath -Algorithm SHA256).Hash.ToLowerInvariant()
$size=(Get-Item -LiteralPath $SetupPath).Length
$url='https://bobtv.briconbric.com/updates/files/'+[IO.Path]::GetFileName($SetupPath)
$fixture=Join-Path $env:TEMP ('BobTVUpdaterTests\managed-flow-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -Force|Out-Null

function New-Scenario([string]$name){
  $root=Join-Path $fixture $name
  $app=Join-Path $root '安装 日本語\BobTV'
  foreach($folder in @($root,(Join-Path $root 'Installers'),(Join-Path $app 'data'))){New-Item -ItemType Directory -Path $folder -Force|Out-Null}
  Copy-Item -LiteralPath $SetupPath -Destination (Join-Path $root ('Installers\'+[IO.Path]::GetFileName($SetupPath)))
  Copy-Item -LiteralPath (Join-Path $BundleDirectory 'BobTV.exe') -Destination (Join-Path $app 'BobTV.exe')
  [IO.File]::WriteAllText((Join-Path $app 'data\app.so'),'unchanged fixture payload')
  [IO.File]::WriteAllText((Join-Path $app 'installation.ini'),'Managed=1')
  return @{root=$root;app=$app}
}
function Arguments($scenario,[string]$run){
  return @{Mode='Update';AppDir=$scenario.app;CurrentPid=99999999;Version=$version;OldVersion=$version;
    ArchiveUrl=$url;Sha256=$hash;Bytes=$size;Signature=$signature;PreviousUrl=$url;
    PreviousSha256=$hash;PreviousBytes=$size;PreviousSignature=$signature;RunId=$run;TestRoot=$scenario.root}
}

$verify=New-Scenario 'verify'
$parameters=Arguments $verify 'verify';$parameters.VerifyOnly=$true
& (Join-Path $source 'installer_worker.ps1') @parameters
$verifyStatus=[IO.File]::ReadAllText((Join-Path $verify.root 'status.json'))|ConvertFrom-Json
if($verifyStatus.phase -eq 'failed'){throw $verifyStatus.message}
if($verifyStatus.phase -ne 'verifying'){throw 'Verification-only worker did not verify the package'}
if(Test-Path -LiteralPath (Join-Path $verify.root 'candidate.ini')){throw 'Verification mode installed a candidate'}
Write-Output 'PASS: cached official Setup hash, size, CNG signature and version verified inside isolated Unicode path.'

# The actual UAC dialog cannot be automated over WinRM. Replace only process
# launch/watch boundaries in this scope, so no real installed app or privileged
# installer is started. Exercise the complete worker consent/state loop.
$global:BobTvFixtureLaunches=0
$global:BobTvFixtureScenario=$null
$global:BobTvFixtureWatched=$null
$global:BobTvFixtureCancel=$true
$global:BobTvFixtureFailNext=$false
function Start-Process {
  param([string]$FilePath,[string[]]$ArgumentList,[string]$Verb,[switch]$PassThru)
  if($Verb -ne 'RunAs' -or $FilePath -notlike ($fixture+'\*')){throw 'Mock launch escaped the isolated fixture'}
  $global:BobTvFixtureLaunches++
  if([IO.File]::ReadAllText((Join-Path $global:BobTvFixtureScenario.app 'data\app.so')) -ne 'unchanged fixture payload'){throw 'Application changed before authorization'}
  if($global:BobTvFixtureCancel){
    $global:BobTvFixtureCancel=$false
    if($global:BobTvFixtureWatched){
      # Explicit second consent request after the first cancellation.
      $request=@{runId='consent';requestId='second-request'}|ConvertTo-Json -Compress
      [IO.File]::WriteAllText((Join-Path $global:BobTvFixtureScenario.root 'install-request-consent.txt'),$request)
    }
    throw (New-Object InvalidOperationException('Start-Process cancelled',(New-Object ComponentModel.Win32Exception(1223))))
  }
  if($ArgumentList -notcontains '/NOCLOSEAPPLICATIONS'){throw 'Installer could force-close the player'}
  $exitCode=if($global:BobTvFixtureFailNext){1}else{0}
  $global:BobTvFixtureFailNext=$false
  $process=[pscustomobject]@{ExitCode=$exitCode}
  $process|Add-Member ScriptMethod WaitForExit {}
  return $process
}
function Get-Process {
  param([int]$Id,[string]$ErrorAction)
  if($Id -eq 99999999){return $global:BobTvFixtureWatched}
  throw 'Mock process lookup escaped the fixture'
}
try{
  $cancel=New-Scenario 'cancel'
  $global:BobTvFixtureScenario=$cancel
  $parameters=Arguments $cancel 'cancel'
  & (Join-Path $source 'installer_worker.ps1') @parameters
  $status=[IO.File]::ReadAllText((Join-Path $cancel.root 'status.json'))|ConvertFrom-Json
  if($status.phase -eq 'failed'){throw $status.message}
  if($status.phase -ne 'ready' -or !$status.authorizationCancelled -or (Test-Path -LiteralPath (Join-Path $cancel.root 'candidate.ini'))){throw 'Cancellation falsely completed an installation'}
  Write-Output 'PASS: cancelled authorization preserves current files, ready state and backup; no candidate installed.'

  $consent=New-Scenario 'consent'
  $global:BobTvFixtureScenario=$consent;$global:BobTvFixtureCancel=$true
  $global:BobTvFixtureWatched=[pscustomobject]@{HasExited=$false;CloseCalls=0}
  $global:BobTvFixtureWatched|Add-Member ScriptMethod Refresh {}
  $global:BobTvFixtureWatched|Add-Member ScriptMethod WaitForExit {$this.CloseCalls++;$this.HasExited=$true}
  [IO.File]::WriteAllText((Join-Path $consent.root 'install-request-consent.txt'),'{"runId":"consent","requestId":"first-request"}')
  $parameters=Arguments $consent 'consent'
  & (Join-Path $source 'installer_worker.ps1') @parameters
  $status=[IO.File]::ReadAllText((Join-Path $consent.root 'status.json'))|ConvertFrom-Json
  if($status.phase -eq 'failed'){throw $status.message}
  if($status.phase -ne 'installed' -or $status.authorizationRequestId -ne 'second-request' -or $global:BobTvFixtureWatched.CloseCalls -ne 1){throw 'Consent/close handshake failed'}
  $candidate=[IO.File]::ReadAllText((Join-Path $consent.root 'candidate.ini'))
  if($candidate -notmatch 'InstallMethod=Setup' -or $candidate -notmatch 'PreviousSignature='){throw 'Protected rollback package state missing'}
  Write-Output 'PASS: cancellation and explicit retry use separate request IDs; player exit is requested once after consent; signed rollback metadata retained.'
  & (Join-Path $source 'worker.ps1') -Mode Rollback -CurrentPid 99999999 -TestRoot $consent.root
  $status=[IO.File]::ReadAllText((Join-Path $consent.root 'status.json'))|ConvertFrom-Json
  if(!$status.restored -or (Test-Path -LiteralPath (Join-Path $consent.root 'candidate.ini'))){
    $details=[IO.File]::ReadAllText((Join-Path $consent.root 'installer-worker.log'))
    $legacyLog=Join-Path $consent.root 'worker.log'
    if(Test-Path -LiteralPath $legacyLog){$details+=[IO.File]::ReadAllText($legacyLog)}
    throw ('Protected rollback delegation failed: '+$status.message+' '+$details)
  }
  Write-Output 'PASS: protected rollback releases the updater mutex and delegates only to the verified official Setup path.'
  $failure=New-Scenario 'failed-install'
  $global:BobTvFixtureScenario=$failure;$global:BobTvFixtureCancel=$false
  $global:BobTvFixtureWatched=$null;$global:BobTvFixtureFailNext=$true
  $parameters=Arguments $failure 'failed-install'
  & (Join-Path $source 'installer_worker.ps1') @parameters
  $status=[IO.File]::ReadAllText((Join-Path $failure.root 'status.json'))|ConvertFrom-Json
  if($status.phase -ne 'failed' -or !$status.restored -or !(Test-Path -LiteralPath (Join-Path $failure.root 'skipped_versions.txt'))){throw 'Failed Setup did not perform verified restoration'}
  Write-Output 'PASS: failed installation restores through the signed previous Setup and marks the failed version skipped.'
}finally{
  Remove-Item Function:Start-Process,Function:Get-Process -ErrorAction SilentlyContinue
  Remove-Variable BobTvFixtureLaunches,BobTvFixtureScenario,BobTvFixtureWatched,BobTvFixtureCancel,BobTvFixtureFailNext -Scope Global -ErrorAction SilentlyContinue
}
Write-Output ('Fixture retained: '+$fixture)
