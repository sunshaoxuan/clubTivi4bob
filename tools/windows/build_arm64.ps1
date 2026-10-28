param(
  [Parameter(Mandatory=$true)][string]$FlutterPath,
  [Parameter(Mandatory=$true)][string]$OutputDirectory,
  [Parameter(Mandatory=$true)][string]$Arm64RuntimeDirectory,
  [Parameter(Mandatory=$true)][string]$SupportDirectory,
  [string]$InstallerCompiler,
  [switch]$CrossCompile,
  [switch]$BundleOnly
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'pe_architecture.ps1')
if(!$CrossCompile -and $env:PROCESSOR_ARCHITECTURE -ne 'ARM64' -and $env:PROCESSOR_ARCHITEW6432 -ne 'ARM64') {
  throw 'Native Windows ARM64 build host required. An x64 package must not be relabeled.'
}
$flutter=(Get-Item -LiteralPath $FlutterPath).FullName
$dart=Join-Path (Split-Path $flutter) 'cache\dart-sdk\bin\dart.exe'
if($CrossCompile) {
  if((Get-BobTvPEMachine $dart) -ne 0x8664){throw 'Cross compilation requires the x64 Dart host'}
  $sdk=Split-Path (Split-Path $flutter)
  $stamp=Get-Content -LiteralPath (Join-Path $sdk 'bobtv-cross-arm64.json') -Raw|ConvertFrom-Json
  $command=Join-Path $sdk 'packages/flutter_tools/lib/src/commands/build_windows.dart'
  if($stamp.Schema -ne 1 -or $stamp.Target -ne 'arm64' -or $stamp.Engine -ne '83675ed27633283e7fc296c8bca22e841224c096' -or
    (Get-FileHash -LiteralPath $command).Hash.ToLower() -ne $stamp.CommandSha256){throw 'Use the validated isolated ARM64 cross-build SDK'}
} elseif((Get-BobTvPEMachine $dart) -ne 0xAA64){throw 'Use the native ARM64 Flutter SDK'}
if(Test-Path -LiteralPath $OutputDirectory){throw 'Preserve existing build output'}
$source=(Get-Item -LiteralPath (Join-Path $PSScriptRoot '../..')).FullName
$runtime=(Get-Item -LiteralPath $Arm64RuntimeDirectory).FullName
$support=(Get-Item -LiteralPath $SupportDirectory).FullName
if($runtime -notmatch '(?i)[\\/]VC[\\/]Redist[\\/]MSVC[\\/].+[\\/]arm64[\\/]Microsoft\.VC\d+\.CRT$') {
  throw 'Select the ARM64 release CRT from the installed Visual Studio redistributable tree'
}
# Microsoft's ARM64 CRT folder also contains an x64 compatibility payload.
# Native ARM64 does not use its vcruntime140_1; never put that x64 DLL at root.
$crt=@(Get-ChildItem -LiteralPath $runtime -File -Filter '*.dll'|Where-Object {
  $_.Name -ne 'vcruntime140_1.dll' -or (Get-BobTvPEMachine $_.FullName) -ne 0x8664
})
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
  # Use cmd explicitly for stable .bat startup in non-interactive PowerShell.
  & $env:ComSpec /d /c ('"'+$flutter+'" pub get --offline')
  if($LASTEXITCODE -ne 0){throw 'Flutter dependency resolution failed'}
  & $env:ComSpec /d /c ('"'+$flutter+'" build windows --release --no-pub')
  if($LASTEXITCODE -ne 0){throw 'Native ARM64 Flutter build failed'}
  $release=Join-Path $source 'build/windows/arm64/runner/Release'
  $built=Join-Path $release 'clubtivi.exe'
  if((Get-BobTvPEMachine $built) -ne 0xAA64){throw 'Flutter output is not ARM64'}
  Assert-BobTvAotArchitecture (Join-Path $release 'data/app.so') 'arm64'
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
  # Keep old support bundles from bringing back the retired external monitor.
  Copy-Item -LiteralPath (Join-Path $source 'tools/windows/hoteltv_crash_monitor.ps1') -Destination (Join-Path $bundle 'Tools/hoteltv_crash_monitor.ps1') -Force
  foreach($file in $crt){Copy-Item -LiteralPath $file.FullName -Destination $bundle}
  $notices=Join-Path $bundle 'ThirdPartyNotices/WindowsARM64'
  New-Item -ItemType Directory -Path $notices -Force|Out-Null
  Copy-Item -LiteralPath (Join-Path $source 'third_party/media_kit_libs_windows_video/LICENSE') -Destination (Join-Path $notices 'media-kit-LICENSE.txt')
  Copy-Item -LiteralPath (Join-Path $source 'third_party/windows_arm64_notices') -Destination (Join-Path $notices 'upstream') -Recurse
  Copy-Item -LiteralPath (Join-Path $source 'LICENSE') -Destination (Join-Path $notices 'BobTV-LICENSE.txt')
  $nativeDependencies=Join-Path $source 'build/windows/arm64'
  foreach($directory in @('libmpv','ANGLE/angle-arm64')) {
    $dependency=Join-Path $nativeDependencies $directory
    Get-ChildItem -LiteralPath $dependency -File -Recurse|Where-Object {$_.Name -match '(?i)^(license|copying|notice|readme)'}|ForEach-Object {
      $relative=$_.FullName.Substring($dependency.Length+1)
      $destination=Join-Path $notices ($directory.Replace('/','-')+'/'+$relative)
      New-Item -ItemType Directory -Path (Split-Path $destination) -Force|Out-Null
      Copy-Item -LiteralPath $_.FullName -Destination $destination
    }
  }
  $runtimeManifest=@($crt|ForEach-Object {@{Name=$_.Name;SHA256=(Get-FileHash -LiteralPath $_.FullName).Hash.ToLower();Version=$_.VersionInfo.FileVersion;Architecture='arm64'}})
  [IO.File]::WriteAllText((Join-Path $bundle 'vc-runtime-manifest.json'),($runtimeManifest|ConvertTo-Json -Depth 4))
  [IO.File]::WriteAllText((Join-Path $bundle 'VC-RUNTIME-NOTICE.txt'),'Microsoft Visual C++ release runtime, ARM64. Redistributed with the application under the Visual Studio redistribution terms.')
  Assert-BobTvBundleArchitecture $bundle 'arm64'
  $vswhere='C:/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe'
  $vs=(& $vswhere -latest -products '*' -property installationPath)
  $compilerVersion=Get-ChildItem -LiteralPath (Join-Path $vs 'VC/Tools/MSVC') -Directory|Sort-Object Name -Descending|Select-Object -First 1
  $candidates=if($CrossCompile){@('bin/Hostx64/arm64/dumpbin.exe','bin/Hostx64/x64/dumpbin.exe')}else{@('bin/Hostarm64/arm64/dumpbin.exe','bin/Hostx64/arm64/dumpbin.exe','bin/Hostx64/x64/dumpbin.exe')}
  $dumpbin=$candidates|ForEach-Object {Join-Path $compilerVersion.FullName $_}|Where-Object {Test-Path -LiteralPath $_}|Select-Object -First 1
  if(!$dumpbin){throw 'Matching Microsoft binary inspection tool is missing'}
  foreach($file in Get-ChildItem -LiteralPath $bundle -File|Where-Object {$_.Extension -eq '.dll' -or $_.Name -eq 'BobTV.exe'}) {
    $imports=(& $dumpbin /nologo /imports $file.FullName|Out-String)
    if($LASTEXITCODE -ne 0){throw "Import inspection failed: $($file.Name)"}
    if($imports -match '(?i)\bvcruntime140_1\.dll\b'){throw "ARM64 binary unexpectedly requires the omitted x64 compatibility CRT: $($file.Name)"}
  }
  # Windows PowerShell 5.1 must retain the installer template's Unicode text.
  $template=Join-Path $source 'tools/windows/installer/BobTV.iss'
  $text=[IO.File]::ReadAllText($template,[Text.Encoding]::UTF8)
  [IO.File]::WriteAllText($template,$text,(New-Object Text.UTF8Encoding $true))
  if(!$BundleOnly) {
    & (Join-Path $PSScriptRoot 'build_installer.ps1') -BundleDirectory $bundle -OutputDirectory $output -Architecture arm64 -Version $version -CompilerPath $InstallerCompiler
    if($LASTEXITCODE -ne 0){throw 'ARM64 installer compilation failed'}
    $archive=Join-Path $output "BobTV-$version-windows-arm64.zip"
    Compress-Archive -LiteralPath $bundle -DestinationPath $archive -CompressionLevel Optimal
  }
  foreach($file in Get-ChildItem -LiteralPath $output -File){Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256}
} finally {Pop-Location}
