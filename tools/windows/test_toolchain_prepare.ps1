param([Parameter(Mandatory=$true)][string]$FixtureDirectory)
$ErrorActionPreference='Stop';$env:CI='true'
$meta=Get-Content -LiteralPath (Join-Path $FixtureDirectory 'fixture.json') -Raw|ConvertFrom-Json
$root=Join-Path $FixtureDirectory 'State'
New-Item -ItemType Directory -Path $root -Force|Out-Null
$prepare=Join-Path $FixtureDirectory 'prepare_toolchain.ps1'
$argsFor=@{Version=$meta.version;Sha256=$meta.sha256;Bytes=[long]$meta.bytes;
  Signature=$meta.signature;TestArchive=(Join-Path $FixtureDirectory 'component.zip');TestRoot=$root}
$target=Join-Path $root ('Toolchains\toolchain-'+$meta.sha256+'-1')
& $prepare @argsFor -Destination $target
foreach($name in @('worker.ps1','installer_worker.ps1','progress_ui.ps1','publisher_signature.ps1')){
  if(!(Test-Path -LiteralPath (Join-Path $target $name))){throw 'Prepared toolchain missing required worker'}
}
foreach($scenario in @('signature','version','destination')){
  $changed=$argsFor.Clone();$destination=Join-Path $root ('Toolchains\toolchain-'+$meta.sha256+'-'+(2+@('signature','version','destination').IndexOf($scenario)))
  if($scenario -eq 'signature'){
    $raw=[Convert]::FromBase64String($changed.Signature);$raw[$raw.Length-1]=$raw[$raw.Length-1] -bxor 1
    $changed.Signature=[Convert]::ToBase64String($raw)
  }
  if($scenario -eq 'version'){$changed.Version='1.4.6+8'}
  if($scenario -eq 'destination'){$destination=Join-Path $FixtureDirectory 'outside-toolchains'}
  $rejected=$false
  try{& $prepare @changed -Destination $destination}catch{$rejected=$true}
  if(!$rejected -or (Test-Path -LiteralPath $destination)){throw ('Unsafe updater accepted: '+$scenario)}
  Write-Output ('PASS: rejected '+$scenario)
}
if(Test-Path -LiteralPath (Join-Path $root 'candidate.ini')){throw 'Preparation started installation'}
Write-Output 'PASS: real Windows CNG verification, both installer modes prepared, version/signature/path failures closed; no application installed.'
