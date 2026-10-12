param(
 [Parameter(Mandatory=$true)][string]$SourceArchiveUrl,
 [Parameter(Mandatory=$true)][string]$SourceSha256,
 [Parameter(Mandatory=$true)][string]$StagingDirectory,
 [Parameter(Mandatory=$true)][string]$OutputDirectory,
 [Parameter(Mandatory=$true)][string]$SupportDirectory,
 [Parameter(Mandatory=$true)][string]$FlutterPath,
 [Parameter(Mandatory=$true)][string]$CompilerPath,
 [switch]$ReuseSource
)
$ErrorActionPreference='Stop'
if((Test-Path -LiteralPath $StagingDirectory) -and !$ReuseSource){throw 'Preserve existing source staging'}
if(Test-Path -LiteralPath $OutputDirectory){throw 'Preserve existing package staging'}
if($SourceSha256 -notmatch '^[a-f0-9]{64}$'){throw 'Source hash required'}
New-Item -ItemType Directory -Path $OutputDirectory|Out-Null
if(!$ReuseSource){
New-Item -ItemType Directory -Path $StagingDirectory|Out-Null
$archive=Join-Path $OutputDirectory 'source.tar.gz'
Invoke-WebRequest -UseBasicParsing $SourceArchiveUrl -OutFile $archive
if((Get-FileHash -LiteralPath $archive).Hash.ToLower() -ne $SourceSha256){throw 'Source archive mismatch'}
& tar.exe -xzf $archive -C $StagingDirectory
if($LASTEXITCODE -ne 0){throw 'Extraction failed'}
} elseif(!(Test-Path -LiteralPath (Join-Path $StagingDirectory 'pubspec.yaml'))){throw 'Reusable source missing'}
Push-Location $StagingDirectory
try {
 & $FlutterPath pub get --offline
 if($LASTEXITCODE -ne 0){throw 'Dependency resolution failed'}
 & $FlutterPath build windows --release --no-pub
 if($LASTEXITCODE -ne 0){throw 'Build failed'}
 $release=Join-Path $StagingDirectory 'build/windows/x64/runner/Release'
 $bundle=Join-Path $OutputDirectory 'BobTV'
 New-Item -ItemType Directory -Path $bundle|Out-Null
 foreach($item in Get-ChildItem -LiteralPath $release -Force) {
  if($item.Name -ne 'AirPlay'){Copy-Item -LiteralPath $item.FullName -Destination $bundle -Recurse}
 }
 Rename-Item -LiteralPath (Join-Path $bundle 'clubtivi.exe') -NewName BobTV.exe
 foreach($name in @('AirPlay','Tools','BobTV.ico','vc-runtime-manifest.json','VC-RUNTIME-NOTICE.txt')) {
  Copy-Item -LiteralPath (Join-Path $SupportDirectory $name) -Destination $bundle -Recurse
 }
 Get-ChildItem -LiteralPath $SupportDirectory -File|Where-Object {$_.Name -match '^(concrt|msvcp|vccorlib|vcruntime)140.*\.dll$'}|ForEach-Object {
  if((Get-AuthenticodeSignature $_.FullName).Status -ne 'Valid'){throw 'Runtime signature invalid'}
  Copy-Item -LiteralPath $_.FullName -Destination $bundle
 }
 . (Join-Path $StagingDirectory 'tools/windows/pe_architecture.ps1')
 Assert-BobTvBundleArchitecture $bundle 'x64'
 # Windows PowerShell 5.1 reads non-BOM scripts using the system code page.
 # Preserve real Unicode fixture paths and installer copy before executing.
 foreach($name in @('tools/windows/test_installer.ps1','tools/windows/installer/BobTV.iss')) {
  $path=Join-Path $StagingDirectory $name
  $value=[IO.File]::ReadAllText($path,[Text.Encoding]::UTF8)
  [IO.File]::WriteAllText($path,$value,(New-Object Text.UTF8Encoding $true))
 }
 & (Join-Path $StagingDirectory 'tools/windows/test_pe_architecture.ps1')
 & (Join-Path $StagingDirectory 'tools/windows/build_installer.ps1') -BundleDirectory $bundle -OutputDirectory $OutputDirectory -CompilerPath $CompilerPath
 & (Join-Path $StagingDirectory 'tools/windows/test_installer.ps1') -BundleDirectory $bundle -CompilerPath $CompilerPath
 $version=(Get-Item (Join-Path $bundle 'BobTV.exe')).VersionInfo.FileVersion
 Compress-Archive -LiteralPath $bundle -DestinationPath (Join-Path $OutputDirectory "BobTV-$version-windows-x64.zip") -CompressionLevel Optimal
 foreach($file in Get-ChildItem -LiteralPath $OutputDirectory -File|Where-Object {$_.Extension -in '.exe','.zip'}) {
  Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256
  & 'C:\Program Files\Tailscale\tailscale.exe' file cp $file.FullName '100.65.248.58:'
  if($LASTEXITCODE -ne 0){throw 'Package transfer failed'}
 }
 [IO.File]::WriteAllText((Join-Path $OutputDirectory 'build-success.txt'),"PASS: $version, x64, installer fixtures, architecture checks, package transfer")
} finally {Pop-Location}
