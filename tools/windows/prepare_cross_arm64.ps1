param(
 [Parameter(Mandatory=$true)][string]$SourceFlutterDirectory,
 [Parameter(Mandatory=$true)][string]$IsolatedFlutterDirectory,
 [switch]$Resume
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'pe_architecture.ps1')
$engine='83675ed27633283e7fc296c8bca22e841224c096'
$source=(Get-Item -LiteralPath $SourceFlutterDirectory).FullName
$target=[IO.Path]::GetFullPath($IsolatedFlutterDirectory)
if($target.StartsWith($source+'\',[StringComparison]::OrdinalIgnoreCase) -or $target -eq $source){throw 'Use a separate SDK directory'}
if((Test-Path -LiteralPath $target) -and !$Resume){throw 'Preserve existing isolated SDK'}
if((Get-Content -LiteralPath (Join-Path $source 'bin\internal\engine.version') -Raw).Trim() -ne $engine){throw 'Cross-build adapter only supports the validated Flutter 3.44.6 engine'}
if((Get-BobTvPEMachine (Join-Path $source 'bin\cache\dart-sdk\bin\dart.exe')) -ne 0x8664){throw 'Source SDK must run on Windows x64'}
# No files are changed in the normal Flutter SDK. Its x64 builds remain intact.
if(!$Resume) {
 & robocopy.exe $source $target /E /XJ /R:1 /W:1 /NFL /NDL /NJH /NJS /XF flutter_tools.snapshot flutter_tools.stamp
 if($LASTEXITCODE -gt 7){throw 'Isolated SDK copy failed'}
} elseif((Get-Content -LiteralPath (Join-Path $target 'bin/internal/engine.version') -Raw).Trim() -ne $engine){throw 'Resume SDK engine mismatch'}
$command=Join-Path $target 'packages\flutter_tools\lib\src\commands\build_windows.dart'
$original=[IO.File]::ReadAllText($command,[Text.Encoding]::UTF8)
$needle='final TargetPlatform targetPlatform = getTargetPlatformForName(defaultTargetPlatform);'
$replacement="final TargetPlatform targetPlatform = getTargetPlatformForName('windows-arm64');"
if(([regex]::Matches($original,[regex]::Escape($needle))).Count -eq 1) {
 $patched=$original.Replace($needle,$replacement)
} elseif($Resume -and ([regex]::Matches($original,[regex]::Escape($replacement))).Count -eq 1) {
 $patched=$original
} else {throw 'Unexpected Flutter command source'}
[IO.File]::WriteAllText($command,$patched,(New-Object Text.UTF8Encoding $false))
$cache=Join-Path $target 'bin\cache\artifacts\engine'
$downloads=Join-Path $target 'bobtv-cross-artifacts'
New-Item -ItemType Directory -Path $downloads -Force|Out-Null
function Get-VerifiedArchive([string]$Relative,[string]$Name,[string]$Sha) {
 $path=Join-Path $downloads $Name
 if(Test-Path -LiteralPath $path) {
  if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower() -ne $Sha){throw "Preserve invalid cached artifact: $Name"}
  return $path
 }
 Invoke-WebRequest -UseBasicParsing ('https://storage.googleapis.com/flutter_infra_release/flutter/'+$engine+'/'+$Relative) -OutFile $path -TimeoutSec 300
 if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower() -ne $Sha){throw "Flutter artifact checksum mismatch: $Name"}
 return $path
}
$release=Get-VerifiedArchive 'windows-arm64-release/windows-arm64-flutter.zip' 'arm64-release.zip' '1f34132a97fcc893d493e358531f165ce8461b6c44827e1356258570f3505eff'
$wrapper=Get-VerifiedArchive 'windows-arm64/flutter-cpp-client-wrapper.zip' 'arm64-wrapper.zip' '4bf4fad0e14428e77087a34049ff070f8776800b9c122b09c32fc918fa670b72'
$releaseDir=Join-Path $cache 'windows-arm64-release'
$baseDir=Join-Path $cache 'windows-arm64'
Expand-Archive -LiteralPath $release -DestinationPath $releaseDir -Force
Expand-Archive -LiteralPath $wrapper -DestinationPath $baseDir -Force
# x64 and ARM64 Windows use the same little-endian ICU data from this engine.
# Release archives omit it; the existing SDK's debug artifacts include it.
$icu=Join-Path $cache 'windows-x64/icudtl.dat'
Copy-Item -LiteralPath $icu -Destination $baseDir
if((Get-FileHash -LiteralPath (Join-Path $baseDir 'icudtl.dat')).Hash -ne (Get-FileHash -LiteralPath $icu).Hash){throw 'Shared ICU data copy failed'}
if((Get-BobTvPEMachine (Join-Path $releaseDir 'gen_snapshot.exe')) -ne 0x8664){throw 'Snapshot compiler cannot run on the x64 host'}
if((Get-BobTvPEMachine (Join-Path $releaseDir 'flutter_windows.dll')) -ne 0xAA64){throw 'Flutter engine is not ARM64'}
$stamp=@{Schema=1;Engine=$engine;CommandSha256=(Get-FileHash -LiteralPath $command).Hash.ToLower();Host='x64';Target='arm64'}
[IO.File]::WriteAllText((Join-Path $target 'bobtv-cross-arm64.json'),($stamp|ConvertTo-Json),(New-Object Text.UTF8Encoding $false))
Write-Output 'PASS: isolated x64 Flutter compiler with verified ARM64 engine and explicit ARM64 target'
