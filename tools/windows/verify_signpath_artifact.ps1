param(
  [Parameter(Mandatory=$true)][string]$Path,
  [Parameter(Mandatory=$true)][string]$Version,
  [ValidateSet('x64','arm64')][string]$Architecture='x64',
  [switch]$Installer,
  [switch]$TestCertificate
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$file=Get-Item -LiteralPath $Path
if($file.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Signed file cannot be a reparse point'}
$info=$file.VersionInfo
if($info.ProductName -ne 'BobTV' -or $info.ProductVersion -ne $Version -or $info.FileVersion -ne $Version){
  throw 'Signed artifact metadata does not match this BobTV build'
}
if(!$Installer){
  . (Join-Path $PSScriptRoot 'pe_architecture.ps1')
  $expected=if($Architecture -eq 'arm64'){0xAA64}else{0x8664}
  if((Get-BobTvPEMachine $file.FullName) -ne $expected){throw 'Signing changed the application CPU identity'}
}
$signature=Get-AuthenticodeSignature -LiteralPath $file.FullName
if(!$signature.SignerCertificate){throw 'SignPath did not return an Authenticode signature'}
if($TestCertificate){
  if($signature.Status -notin @('Valid','UnknownError','NotTrusted')){throw 'Invalid test signature'}
  Write-Warning 'Test certificate is not a publicly trusted release signature. Do not publish this artifact.'
} elseif($signature.Status -ne 'Valid' -or !$signature.TimeStamperCertificate){
  throw 'Release requires a valid Windows trust chain and a timestamp'
}
$expectedPublisher=$env:SIGNPATH_EXPECTED_PUBLISHER
if(!$TestCertificate -and !$expectedPublisher){throw 'Configure the approved public certificate publisher before release signing'}
if($expectedPublisher -and $signature.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName,$false) -ne $expectedPublisher){
  throw 'Certificate publisher differs from the approved SignPath configuration'
}
[ordered]@{filename=$file.Name;bytes=$file.Length;sha256=(Get-FileHash -LiteralPath $file.FullName).Hash.ToLower()
  version=$Version;architecture=$Architecture;trust=$signature.Status.ToString()
  publisher=$signature.SignerCertificate.Subject;certificateThumbprint=$signature.SignerCertificate.Thumbprint
  testCertificate=[bool]$TestCertificate}|ConvertTo-Json
