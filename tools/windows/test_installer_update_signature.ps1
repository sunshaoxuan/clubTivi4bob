param([Parameter(Mandatory=$true)][string]$SetupPath,
      [Parameter(Mandatory=$true)][string]$SignaturePath)
$ErrorActionPreference='Stop'
if($env:CI -ne 'true'){throw 'Signature fixtures are restricted to CI'}
$source=Join-Path $PSScriptRoot '..\..\assets\updater'
. (Join-Path $source 'publisher_signature.ps1')
$key=Join-Path $source 'update-signing-public.pem'
$signature=[Convert]::ToBase64String([IO.File]::ReadAllBytes($SignaturePath))
if(!(Test-BobTvPublisherSignature $SetupPath $signature $key)){throw 'Valid publisher signature rejected'}
$root=Join-Path $env:TEMP ('BobTVUpdaterTests\signature-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force|Out-Null
$changed=Join-Path $root 'tampered-Setup.exe'
# A bounded sample has different content and must not validate under the
# signature of the real release. The published Setup is never modified.
$input=[IO.File]::OpenRead($SetupPath)
try{$buffer=New-Object byte[] 4096;$count=$input.Read($buffer,0,$buffer.Length)}finally{$input.Dispose()}
$buffer[0]=$buffer[0] -bxor 1
[IO.File]::WriteAllBytes($changed,$buffer[0..($count-1)])
if(Test-BobTvPublisherSignature $changed $signature $key){throw 'Tampered Setup accepted'}
foreach($malformed in @('bad',('A'*96),($signature+'AAAA'))){
  $rejected=$false
  try{$rejected=!(Test-BobTvPublisherSignature $SetupPath $malformed $key)}catch{$rejected=$true}
  if(!$rejected){throw 'Malformed publisher signature accepted'}
}
$parserErrors=@()
foreach($script in @('installer_worker.ps1','publisher_signature.ps1','worker.ps1','progress_ui.ps1')){
  $tokens=$null;$errors=$null
  $null=[Management.Automation.Language.Parser]::ParseFile((Join-Path $source $script),[ref]$tokens,[ref]$errors)
  $parserErrors+=@($errors)
}
if($parserErrors.Count){throw ($parserErrors|Out-String)}
Write-Output 'PASS: Windows CNG accepts the publisher signature, rejects tampering/malformed signatures, and all updater scripts parse.'
