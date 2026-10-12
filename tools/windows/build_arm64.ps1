param(
  [Parameter(Mandatory=$true)][string]$FlutterPath,
  [Parameter(Mandatory=$true)][string]$OutputDirectory,
  [Parameter(Mandatory=$true)][string]$Arm64RuntimeDirectory,
  [Parameter(Mandatory=$true)][string]$SupportDirectory,
  [string]$InstallerCompiler
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'pe_architecture.ps1')
if($env:PROCESSOR_ARCHITECTURE -ne 'ARM64' -and $env:PROCESSOR_ARCHITEW6432 -ne 'ARM64') {
  throw 'Native Windows ARM64 build host required. An x64 package must not be relabeled.'
}
$flutter=(Get-Item -LiteralPath $FlutterPath).FullName
$dart=Join-Path (Split-Path $flutter) 'cache\dart-sdk\bin\dart.exe'
if((Get-BobTvPEMachine $dart) -ne 0xAA64){throw 'Use the native ARM64 Flutter SDK'}
if(Test-Path -LiteralPath $OutputDirectory){throw 'Preserve existing build output'}
$source=(Get-Item -LiteralPath (Join-Path $PSScriptRoot '../..')).FullName
$runtime=(Get-Item -LiteralPath $Arm64RuntimeDirectory).FullName
$support=(Get-Item -LiteralPath $SupportDirectory).FullName
if($runtime -notmatch '(?i)[\\/]VC[\\/]Redist[\\/]MSVC[\\/].+[\\/]arm64[\\/]Microsoft\.VC\d+\.CRT$') {
  throw 'Select the ARM64 release CRT from the installed Visual Studio redistributable tree'
}
$crt=@(Get-ChildItem -LiteralPath $runtime -File -Filter '*.dll')
foreach($name in @('msvcp140.dll','vcruntime140.dll')) {
  if($crt.Name -notcontains $name){throw "ARM64 CRT missing: $name"}
}
foreach($file in $crt) {
  $signature=Get-AuthenticodeSignature -LiteralPath $file.FullName
  if((Get-BobTvPEMachine $file.FullName) -ne 0xAA64 -or $signature.Status -ne 'Valid' -or
    $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation' -or $file.VersionInfo.IsDebug) {
    throw "Invalid ARM64 Microsoft release runtime: $($file.Name)"
  }
}
foreach($name in @('AirPlay/bobtv-airplay.exe','AirPlay/fpsap-auth.exe','Tools','BobTV.ico')) {
  if(!(Test-Path -LiteralPath (Join-Path $support $name))){throw "Support component missing: $name"}
}
# AirPlay helpers are isolated child processes. Windows 11 can run the existing
# x64 helper through Prism; its x64 DLLs remain inside AirPlay, never at app root.
New-Item -ItemType Directory -Path $OutputDirectory|Out-Null
$output=(Get-Item -LiteralPath $OutputDirectory).FullName
Push-Location $source
try {
  & $flutter pub get
  if($LASTEXITCODE -ne 0){throw 'Flutter dependency resolution failed'}
  & $flutter build windows --release --no-pub
  if($LASTEXITCODE -ne 0){throw 'Native ARM64 Flutter build failed'}
  $release=Join-Path $source 'build/windows/arm64/runner/Release'
  $built=Join-Path $release 'clubtivi.exe'
  if((Get-BobTvPEMachine $built) -ne 0xAA64){throw 'Flutter output is not ARM64'}
  $version=(Get-Item -LiteralPath $built).VersionInfo.FileVersion
  $bundle=Join-Path $output 'BobTV'
  New-Item -ItemType Directory -Path $bundle|Out-Null
  foreach($item in Get-ChildItem -LiteralPath $release -Force) {
    if($item.Name -ne 'AirPlay'){Copy-Item -LiteralPath $item.FullName -Destination $bundle -Recurse}
  }
  Rename-Item -LiteralPath (Join-Path $bundle 'clubtivi.exe') -NewName 'BobTV.exe'
  foreach($name in @('AirPlay','Tools','BobTV.ico')) {
    Copy-Item -LiteralPath (Join-Path $support $name) -Destination $bundle -Recurse
  }
  foreach($file in $crt){Copy-Item -LiteralPath $file.FullName -Destination $bundle}
  Assert-BobTvBundleArchitecture $bundle 'arm64'
  & (Join-Path $PSScriptRoot 'build_installer.ps1') -BundleDirectory $bundle -OutputDirectory $output -Architecture arm64 -Version $version -CompilerPath $InstallerCompiler
  if($LASTEXITCODE -ne 0){throw 'ARM64 installer compilation failed'}
  $archive=Join-Path $output "BobTV-$version-windows-arm64.zip"
  Compress-Archive -LiteralPath $bundle -DestinationPath $archive -CompressionLevel Optimal
  foreach($file in Get-ChildItem -LiteralPath $output -File){Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256}
} finally {Pop-Location}
