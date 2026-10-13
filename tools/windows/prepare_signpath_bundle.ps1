param(
  [ValidateSet('x64','arm64')][string]$Architecture='x64',
  [Parameter(Mandatory=$true)][string]$OutputDirectory,
  [Parameter(Mandatory=$true)][string]$FlutterDirectory
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$source=(Get-Item -LiteralPath (Join-Path $PSScriptRoot '../..')).FullName
$flutter=Join-Path $FlutterDirectory 'bin/flutter.bat'
if(Test-Path -LiteralPath $OutputDirectory){throw 'Preserve existing signing staging'}
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
$output=(Get-Item -LiteralPath $OutputDirectory).FullName
Push-Location $source
try {
  & $flutter pub get
  if($LASTEXITCODE -ne 0){throw 'Dependency resolution failed'}
  & $flutter build windows --release --no-pub
  if($LASTEXITCODE -ne 0){throw 'Windows x64 support build failed'}
  $release=Join-Path $source 'build/windows/x64/runner/Release'
  $support=Join-Path $output 'x64-support/BobTV'
  New-Item -ItemType Directory -Path $support -Force | Out-Null
  foreach($item in Get-ChildItem -LiteralPath $release -Force){
    Copy-Item -LiteralPath $item.FullName -Destination $support -Recurse
  }
  Rename-Item -LiteralPath (Join-Path $support 'clubtivi.exe') -NewName 'BobTV.exe'
  Copy-Item -LiteralPath (Join-Path $source 'windows/runner/resources/app_icon.ico') -Destination (Join-Path $support 'BobTV.ico')
  $tools=Join-Path $support 'Tools'
  New-Item -ItemType Directory -Path $tools | Out-Null
  # ProcDump is a separately licensed proprietary tool. Free OSS candidates use
  # the application's existing crash_handler.cpp and Windows DbgHelp instead.
  [IO.File]::WriteAllText((Join-Path $tools 'CRASH-DUMPS.txt'),
    'BobTV writes native crash dumps with Windows DbgHelp. ProcDump is not bundled.',[Text.UTF8Encoding]::new($false))
  & (Join-Path $PSScriptRoot 'bundle_vc_runtime.ps1') -BundleDirectory $support
  if($Architecture -eq 'arm64') {
    $isolated=Join-Path $output 'flutter-cross-arm64'
    & (Join-Path $PSScriptRoot 'prepare_cross_arm64.ps1') -SourceFlutterDirectory $FlutterDirectory -IsolatedFlutterDirectory $isolated
    $vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    $vs=(& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.ARM64 -property installationPath)
    if(!$vs){throw 'GitHub runner is missing the Microsoft ARM64 C++ toolchain'}
    $runtime=Get-ChildItem -LiteralPath (Join-Path $vs 'VC/Redist/MSVC') -Directory |
      Where-Object {$_.Name -match '^\d+\.\d+\.\d+(?:\.\d+)?$'} |
      Sort-Object { [Version]$_.Name } -Descending |
      ForEach-Object { Join-Path $_.FullName 'arm64/Microsoft.VC143.CRT' } |
      Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if(!$runtime){throw 'ARM64 release CRT is missing'}
    & (Join-Path $PSScriptRoot 'build_arm64.ps1') -FlutterPath (Join-Path $isolated 'bin/flutter.bat') `
      -OutputDirectory (Join-Path $output 'arm64') -Arm64RuntimeDirectory $runtime `
      -SupportDirectory $support -CrossCompile -BundleOnly
    $bundle=Join-Path $output 'arm64/BobTV'
  } else {
    $bundle=$support
  }
  . (Join-Path $PSScriptRoot 'pe_architecture.ps1')
  Assert-BobTvBundleArchitecture $bundle $Architecture
  Assert-BobTvAotArchitecture (Join-Path $bundle 'data/app.so') $Architecture
  if(Get-ChildItem -LiteralPath $bundle -File -Recurse | Where-Object {$_.Name -match '(?i)^procdump.*\.exe$'}) {
    throw 'Non-OSS crash helper must not enter an OSS signing candidate'
  }
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'installer/PrivacyNotice.txt') -Destination (Join-Path $bundle 'PRIVACY-NOTICE.txt')
  $notices=Join-Path $bundle 'ThirdPartyNotices/BobTV'
  New-Item -ItemType Directory -Path $notices -Force | Out-Null
  Copy-Item -LiteralPath (Join-Path $source 'LICENSE') -Destination (Join-Path $notices 'LICENSE.txt')
  Copy-Item -LiteralPath (Join-Path $source 'docs/code-signing-policy.md') -Destination (Join-Path $notices 'CODE-SIGNING-POLICY.md')
  $dependencies=Join-Path $bundle 'ThirdPartyNotices/Dependencies'
  New-Item -ItemType Directory -Path $dependencies -Force | Out-Null
  Copy-Item -LiteralPath (Join-Path $FlutterDirectory 'LICENSE') -Destination (Join-Path $dependencies 'Flutter-LICENSE.txt')
  Copy-Item -LiteralPath (Join-Path $source 'third_party/media_kit_libs_windows_video/LICENSE') -Destination (Join-Path $dependencies 'media-kit-LICENSE.txt')
  # Preserve notices from the actual native dependency archives and the Python
  # environment used for the AirPlay helper. Third-party files remain unsigned.
  $licenseRoots=[ordered]@{
    'libmpv'=(Join-Path $source "build/windows/$Architecture/libmpv")
    'ANGLE'=(Join-Path $source "build/windows/$Architecture/ANGLE")
    'AirPlay-Python'=(Join-Path $source 'build/airplay-venv/Lib/site-packages')
  }
  foreach($entry in $licenseRoots.GetEnumerator()) {
    if(!(Test-Path -LiteralPath $entry.Value)){throw "Dependency notice root missing: $($entry.Key)"}
    Get-ChildItem -LiteralPath $entry.Value -File -Recurse |
      Where-Object {$_.Name -match '(?i)^(license|copying|notice)'} |
      ForEach-Object {
        $relative=$_.FullName.Substring($entry.Value.Length+1)
        $destination=Join-Path $dependencies ($entry.Key+'/'+$relative)
        New-Item -ItemType Directory -Path (Split-Path $destination) -Force | Out-Null
        Copy-Item -LiteralPath $_.FullName -Destination $destination
      }
  }
  $version=(Get-Item -LiteralPath (Join-Path $bundle 'BobTV.exe')).VersionInfo.FileVersion
  if($version -notmatch '^\d+\.\d+\.\d+\+\d+$'){throw 'Invalid candidate version'}
  $record=[ordered]@{
    schema=1;version=$version;architecture=$Architecture
    sourceRepository='https://github.com/sunshaoxuan/clubTivi4bob'
    sourceCommit=(& git rev-parse HEAD).Trim()
    workflowRun=$env:GITHUB_RUN_ID;workflowRef=$env:GITHUB_WORKFLOW_REF
    flutterVersion='3.44.6';runnerImage=$env:ImageVersion
    stage='original-build-input';publisherApproval='required';authenticode='not-yet-signed'
    proprietaryCrashHelperBundled=$false
  }
  $recordPath=Join-Path $output 'build-provenance.json'
  [IO.File]::WriteAllText($recordPath,($record|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
  [IO.File]::AppendAllText($env:GITHUB_ENV,"BOBTV_BUNDLE=$bundle`nBOBTV_VERSION=$version`nBOBTV_PROVENANCE=$recordPath`n",[Text.UTF8Encoding]::new($false))
} finally {Pop-Location}
