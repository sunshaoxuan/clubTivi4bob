param(
  [Parameter(Mandatory=$true)][string]$BundleDirectory,
  [Parameter(Mandatory=$true)][string]$OutputDirectory,
  [string]$CompilerPath,
  [string]$Version
)
$ErrorActionPreference='Stop'
$bundle=(Get-Item -LiteralPath $BundleDirectory).FullName
$exe=Join-Path $bundle 'BobTV.exe'
foreach($name in @('BobTV.exe','BobTV.ico','data\app.so','flutter_windows.dll',
  'libmpv-2.dll','msvcp140.dll','vcruntime140.dll','vcruntime140_1.dll',
  'AirPlay\bobtv-airplay.exe','AirPlay\fpsap-auth.exe',
  'data\flutter_assets\assets\updater\ensure_shortcut.ps1')) {
  if(!(Test-Path -LiteralPath (Join-Path $bundle $name) -PathType Leaf)) {
    throw "Installer component missing: $name"
  }
}
$actualVersion=(Get-Item -LiteralPath $exe).VersionInfo.FileVersion
if(!$Version){$Version=$actualVersion}
if($Version -notmatch '^\d+\.\d+\.\d+\+\d+$' -or $Version -ne $actualVersion) {
  throw 'Installer version must match application version'
}
if(!$CompilerPath){
  $candidates=@(
    (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'))
  $CompilerPath=$candidates|Where-Object {Test-Path -LiteralPath $_}|Select-Object -First 1
}
if(!$CompilerPath -or !(Test-Path -LiteralPath $CompilerPath -PathType Leaf)) {
  throw 'Inno Setup 6 compiler missing. Install the official signed compiler first.'
}
New-Item -ItemType Directory -Path $OutputDirectory -Force|Out-Null
$output=(Get-Item -LiteralPath $OutputDirectory).FullName
& $CompilerPath "/DBundleDirectory=$bundle" "/DOutputDirectory=$output" "/DAppVersion=$Version" (Join-Path $PSScriptRoot 'installer\BobTV.iss')
if($LASTEXITCODE -ne 0){throw "Installer compiler failed: $LASTEXITCODE"}
$setup=Join-Path $output "BobTV-$Version-windows-x64-Setup.exe"
if(!(Test-Path -LiteralPath $setup)){throw 'Compiler did not produce installer'}
Get-FileHash -LiteralPath $setup -Algorithm SHA256|Select-Object Path,Hash
