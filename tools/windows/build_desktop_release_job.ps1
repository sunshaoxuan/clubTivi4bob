param(
 [Parameter(Mandatory=$true)][string]$JobDirectory,
 [Parameter(Mandatory=$true)][string]$SourceSha256,
 [Parameter(Mandatory=$true)][string]$SupportDirectory,
 [Parameter(Mandatory=$true)][string]$FlutterPath,
 [Parameter(Mandatory=$true)][string]$Arm64FlutterPath,
 [Parameter(Mandatory=$true)][string]$Arm64RuntimeDirectory,
 [Parameter(Mandatory=$true)][string]$CompilerPath,
 [switch]$SkipTransfer,
 [switch]$SkipInstallTests
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
Start-Transcript -LiteralPath (Join-Path $JobDirectory 'build.log')
try {
 $source=(Get-Item -LiteralPath (Join-Path $JobDirectory 'source')).FullName
 $support=Join-Path $JobDirectory 'support'
 if(Test-Path -LiteralPath $support){throw 'Preserve existing support staging'}
 Copy-Item -LiteralPath $SupportDirectory -Destination $support -Recurse
 $fpsap=Join-Path $source 'build/fpsap-dist'
 New-Item -ItemType Directory -Path $fpsap -Force|Out-Null
 foreach($name in @('fpsap-auth.exe','fpsap-upstream-source.zip','fpsap_auth.go','build-fpsap.ps1','FPSAP-LICENSE','FPSAP-COPYING.GPL-3.0','FPSAP-LICENSE.BlueOak-1.0.0','FPSAP-NOTICE.md')) {
  Copy-Item -LiteralPath (Join-Path $support ('AirPlay/'+$name)) -Destination $fpsap
 }
 & (Join-Path $source 'tools/airplay/build.ps1')
 if($LASTEXITCODE -ne 0){throw 'Current AirPlay source compilation failed'}
 Move-Item -LiteralPath (Join-Path $support 'AirPlay') -Destination (Join-Path $support 'AirPlay.baseline')
 Copy-Item -LiteralPath (Join-Path $source 'build/airplay-dist/bobtv-airplay') -Destination (Join-Path $support 'AirPlay') -Recurse
 & (Join-Path $source 'tools/windows/build_release_bundle.ps1') -SourceArchiveUrl 'https://bobtv.briconbric.com' -SourceSha256 $SourceSha256 -StagingDirectory $source -OutputDirectory (Join-Path $JobDirectory 'x64') -SupportDirectory $support -FlutterPath $FlutterPath -CompilerPath $CompilerPath -ReuseSource -SkipTransfer:$SkipTransfer -SkipInstallTests:$SkipInstallTests
 if($LASTEXITCODE -ne 0){throw 'x64 build job failed'}
 & (Join-Path $source 'tools/windows/build_arm64.ps1') -FlutterPath $Arm64FlutterPath -OutputDirectory (Join-Path $JobDirectory 'arm64') -Arm64RuntimeDirectory $Arm64RuntimeDirectory -SupportDirectory $support -InstallerCompiler $CompilerPath -CrossCompile
 if($LASTEXITCODE -ne 0){throw 'ARM64 build job failed'}
 if(!$SkipTransfer){foreach($file in Get-ChildItem -LiteralPath (Join-Path $JobDirectory 'arm64') -File|Where-Object {$_.Extension -in '.exe','.zip'}) {
  & 'C:\Program Files\Tailscale\tailscale.exe' file cp $file.FullName '100.65.248.58:'
  if($LASTEXITCODE -ne 0){throw 'ARM64 artifact transfer failed'}
 }}
 [IO.File]::WriteAllText((Join-Path $JobDirectory 'job-success.txt'),'PASS: x64 and ARM64 packages, refreshed sender, installer and architecture checks')
} catch {
 [IO.File]::WriteAllText((Join-Path $JobDirectory 'job-failed.txt'),($_|Out-String))
 throw
} finally {Stop-Transcript}
