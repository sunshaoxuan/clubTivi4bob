$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'bundle_vc_runtime.ps1') -BundleDirectory 'unit-tests-only'

$script:checks = 0
function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
  $script:checks++
}
function Assert-Throws([scriptblock]$Action, [string]$Message) {
  $threw = $false
  try { & $Action | Out-Null } catch { $threw = $true }
  Assert-True $threw $Message
}

$testTemporaryRoot = if ($IsMacOS) { '/private/tmp' } else { [IO.Path]::GetTempPath() }
$temporary = Join-Path $testTemporaryRoot ('BobTV-crt-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporary | Out-Null
try {
  $sourceRoot = Join-Path $temporary 'VisualStudio'
  foreach ($relative in @(
    'VC/Redist/MSVC/14.9.9/x64/Microsoft.VC143.CRT',
    'VC/Redist/MSVC/14.10.1/x64/Microsoft.VC143.CRT',
    'VC/Redist/MSVC/14.99.1/x86/Microsoft.VC143.CRT',
    'VC/Redist/MSVC/v143/x64/Microsoft.VC143.CRT',
    'VC/Tools/MSVC/14.9.9', 'VC/Tools/MSVC/14.10.1')) {
    New-Item -ItemType Directory -Path (Join-Path $sourceRoot $relative) -Force | Out-Null
  }
  $installations = @([pscustomobject]@{ installationPath = $sourceRoot })
  $source = Find-VcRuntimeSource $installations
  Assert-True ($source.Version -eq [Version]'14.10.1') 'Runtime source must sort versions numerically and ignore x86/aliases'
  Assert-True ((Get-LatestInstalledToolsetVersion $installations) -eq [Version]'14.10.1') 'Toolset versions must sort numerically'
  Assert-Throws { Find-VcRuntimeSource @() } 'Missing redistributable source must fail'
  Assert-Throws { Get-LatestInstalledToolsetVersion @() } 'Missing toolset must fail'

  foreach ($forbidden in @('debug_nonredist', 'System32', 'SysWOW64')) {
    $path = Join-Path $temporary $forbidden
    New-Item -ItemType Directory -Path $path | Out-Null
    Assert-Throws { Assert-RegularRuntimePath $path } "Must reject $forbidden sources"
  }
  $link = Join-Path $temporary 'linked-runtime'
  $linkType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
  New-Item -ItemType $linkType -Path $link -Target $sourceRoot | Out-Null
  Assert-Throws { Assert-RegularRuntimePath (Join-Path $link 'VC/Tools/MSVC/14.10.1') } 'Must reject reparse-point ancestors'

  $pePath = Join-Path $temporary 'sample.dll'
  $bytes = [byte[]]::new(128)
  $bytes[0] = 0x4d; $bytes[1] = 0x5a; $bytes[0x3c] = 0x40
  $bytes[0x40] = 0x50; $bytes[0x41] = 0x45
  $bytes[0x44] = 0x64; $bytes[0x45] = 0x86
  $bytes[0x58] = 0x0b; $bytes[0x59] = 0x02
  [IO.File]::WriteAllBytes($pePath, $bytes)
  Assert-True ((Get-Amd64PeMachine $pePath) -eq 0x8664) 'Must recognize AMD64 PE32+'
  Assert-Throws { Get-Amd64PeMachine $pePath -RequireDll } 'Runtime source must not be a renamed executable'
  $bytes[0x57] = 0x20
  [IO.File]::WriteAllBytes($pePath, $bytes)
  Assert-True ((Get-Amd64PeMachine $pePath -RequireDll) -eq 0x8664) 'Must recognize the PE DLL flag'
  $bytes[0x44] = 0x4c; $bytes[0x45] = 0x01
  [IO.File]::WriteAllBytes($pePath, $bytes)
  Assert-Throws { Get-Amd64PeMachine $pePath } 'Must reject x86 DLLs'
  [IO.File]::WriteAllBytes($pePath, [byte[]]::new(20))
  Assert-Throws { Get-Amd64PeMachine $pePath } 'Must reject malformed PE files'

  $info = [pscustomobject]@{
    IsDebug = $false; CompanyName = 'Microsoft Corporation'
    FileMajorPart = 14; FileMinorPart = 10; FileBuildPart = 1; FilePrivatePart = 0
    ProductMajorPart = 14; OriginalFilename = 'msvcp140.dll'
  }
  $signature = [pscustomobject]@{
    Status = 'Valid'
    SignerCertificate = [pscustomobject]@{ Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation, C=US' }
  }
  Assert-True ((Assert-MicrosoftRuntimeMetadata $info $signature 'MSVCP140.dll') -eq [Version]'14.10.1.0') 'Must accept signed Microsoft release metadata'
  $info.IsDebug = $true
  Assert-Throws { Assert-MicrosoftRuntimeMetadata $info $signature 'MSVCP140.dll' } 'Must reject debug flag'
  $info.IsDebug = $false
  Assert-Throws { Assert-MicrosoftRuntimeMetadata $info $signature 'msvcp140d.dll' } 'Must reject debug filenames'
  Assert-Throws { Assert-MicrosoftRuntimeMetadata $info $signature 'vcruntime140_1d.dll' } 'Must reject suffixed debug filenames'
  Assert-Throws { Assert-MicrosoftRuntimeMetadata $info $signature 'kernel32.dll' } 'Must reject non-CRT DLLs'
  Assert-Throws { Assert-MicrosoftRuntimeMetadata $info $signature 'vcruntime140.dll' } 'OriginalFilename must match the release DLL name'
  $info.CompanyName = 'Other vendor'
  Assert-Throws { Assert-MicrosoftRuntimeMetadata $info $signature 'MSVCP140.dll' } 'Must reject non-Microsoft metadata'
  $info.CompanyName = 'Microsoft Corporation'; $info.FileMajorPart = 13
  Assert-Throws { Assert-MicrosoftRuntimeMetadata $info $signature 'MSVCP140.dll' } 'Must reject wrong runtime version'
  $info.FileMajorPart = 14; $signature.Status = 'NotSigned'
  Assert-Throws { Assert-MicrosoftRuntimeMetadata $info $signature 'MSVCP140.dll' } 'Must reject unsigned DLLs'
  $signature.Status = 'Valid'; $signature.SignerCertificate.Subject = 'CN=Other vendor, O=Other vendor, C=US'
  Assert-Throws { Assert-MicrosoftRuntimeMetadata $info $signature 'MSVCP140.dll' } 'Must reject non-Microsoft signatures'
  Assert-NoRuntimeDowngrade ([Version]'14.10.1.0') $info 'MSVCP140.dll'
  $script:checks++
  Assert-Throws { Assert-NoRuntimeDowngrade ([Version]'14.9.9.0') $info 'MSVCP140.dll' } 'Must reject downgrading existing Python/runtime DLLs'

  $destinations = @()
  foreach ($relative in @('BobTV', 'BobTV/AirPlay', 'BobTV/AirPlay/_internal')) {
    $destination = Join-Path $temporary $relative
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    $destinations += $destination
  }
  $manifest = @()
  foreach ($name in @('MSVCP140.dll', 'VCRUNTIME140.dll', 'VCRUNTIME140_1.dll')) {
    $path = Join-Path $source.Path $name
    [IO.File]::WriteAllBytes($path, [byte[]]@(1, 2, 3, 4))
    $manifest += [pscustomobject]@{ filename = $name; version = '14.10.1.0'; sha256 = (Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant() }
    [IO.File]::WriteAllBytes((Join-Path $destinations[2] $name), [byte[]]@(9, 9))
  }
  Copy-VerifiedVcRuntime $source.Path $manifest $destinations
  foreach ($destination in $destinations) {
    foreach ($entry in $manifest) {
      Assert-True ((Get-FileHash (Join-Path $destination $entry.filename) -Algorithm SHA256).Hash.ToLowerInvariant() -eq $entry.sha256) 'Every application-local copy must match the selected source set'
    }
  }
  $unexpected = Join-Path $destinations[2] 'MSVCP140d.dll'
  [IO.File]::WriteAllBytes($unexpected, [byte[]]@(1))
  Assert-Throws { Copy-VerifiedVcRuntime $source.Path $manifest $destinations } 'Must reject stale/debug CRT outside the selected set'

  $workflowPath = Join-Path $PSScriptRoot '../../.github/workflows/desktop-release-build.yml'
  $workflow = [IO.File]::ReadAllText($workflowPath)
  $bundleCall = $workflow.IndexOf('& tools/windows/bundle_vc_runtime.ps1 -BundleDirectory $bundle')
  Assert-True ($bundleCall -gt 0 -and $bundleCall -lt $workflow.IndexOf('Compress-Archive -Path $bundle')) 'Runtime bundling must precede compression'
  $notice = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'VC-RUNTIME-NOTICE.txt'))
  Assert-True ($notice.Contains('https://learn.microsoft.com/en-us/cpp/windows/redistributing-visual-cpp-files')) 'Redistribution notice must identify Microsoft documentation'
  Write-Host "VC runtime safeguards: $script:checks checks passed"
} finally {
  Remove-Item -LiteralPath $temporary -Recurse -Force
}
