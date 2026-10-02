param([Parameter(Mandatory=$true)][string]$BundleDirectory)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-RegularRuntimePath([string]$Path) {
  $item = Get-Item -LiteralPath $Path -Force
  if ($item.FullName -match '(?i)[\\/](debug_nonredist|system32|syswow64)([\\/]|$)') {
    throw "Forbidden runtime path: $Path"
  }
  while ($null -ne $item) {
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "Runtime paths must not contain reparse points: $Path"
    }
    $item = if ($item -is [IO.DirectoryInfo]) { $item.Parent } else { $item.Directory }
  }
}

function Get-Amd64PeMachine([string]$Path, [switch]$RequireDll) {
  $stream = [IO.File]::OpenRead($Path)
  $reader = [IO.BinaryReader]::new($stream)
  try {
    if ($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5a4d) {
      throw "Invalid DOS header: $Path"
    }
    $stream.Position = 0x3c
    $offset = $reader.ReadUInt32()
    if ($offset + 26 -gt $stream.Length) { throw "Invalid PE offset: $Path" }
    $stream.Position = $offset
    if ($reader.ReadUInt32() -ne 0x00004550) { throw "Invalid PE signature: $Path" }
    $machine = $reader.ReadUInt16()
    $stream.Position = $offset + 22
    if ($RequireDll -and ($reader.ReadUInt16() -band 0x2000) -eq 0) {
      throw "Runtime source must be a PE DLL: $Path"
    }
    $stream.Position = $offset + 24
    if ($machine -ne 0x8664 -or $reader.ReadUInt16() -ne 0x20b) {
      throw "Runtime DLL must be AMD64 PE32+: $Path"
    }
    return $machine
  } finally { $reader.Dispose() }
}

function Assert-MicrosoftRuntimeMetadata($Info, $Signature, [string]$Name) {
  if ($Name -notmatch '^(?i:concrt|msvcp|vccorlib|vcruntime)140(?:_[a-z0-9_]+)?\.dll$' -or
      $Name -match '(?i)d\.dll$' -or $Info.IsDebug) {
    throw "Not a release VC runtime DLL: $Name"
  }
  if ($Info.CompanyName -ne 'Microsoft Corporation' -or
      $Info.FileMajorPart -ne 14 -or $Info.ProductMajorPart -ne 14 -or
      $Info.OriginalFilename -ine $Name) {
    throw "Unexpected Microsoft VC runtime version/vendor: $Name"
  }
  if ($Signature.Status -ne 'Valid' -or $null -eq $Signature.SignerCertificate -or
      $Signature.SignerCertificate.Subject -notmatch '(^|,\s*)O=Microsoft Corporation(,|$)') {
    throw "Runtime DLL must have a valid Microsoft Authenticode signature: $Name"
  }
  return [Version]::new($Info.FileMajorPart, $Info.FileMinorPart,
    $Info.FileBuildPart, $Info.FilePrivatePart)
}

function Assert-NoRuntimeDowngrade([Version]$Selected, $ExistingInfo, [string]$Name) {
  if ($ExistingInfo.FileMajorPart -eq 14) {
    $existing = [Version]::new($ExistingInfo.FileMajorPart, $ExistingInfo.FileMinorPart,
      $ExistingInfo.FileBuildPart, $ExistingInfo.FilePrivatePart)
    if ($Selected -lt $existing) { throw "Selected VC runtime would downgrade $Name from $existing to $Selected" }
  }
}

function Find-VcRuntimeSource([object[]]$Installations) {
  $candidates = @()
  foreach ($installation in $Installations) {
    $root = Join-Path $installation.installationPath 'VC/Redist/MSVC'
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
    Assert-RegularRuntimePath $root
    foreach ($versionDirectory in Get-ChildItem -LiteralPath $root -Directory -Force) {
      if ($versionDirectory.Name -notmatch '^\d+\.\d+\.\d+(?:\.\d+)?$') { continue }
      Assert-RegularRuntimePath $versionDirectory.FullName
      $archDirectory = Join-Path $versionDirectory.FullName 'x64'
      if (-not (Test-Path -LiteralPath $archDirectory -PathType Container)) { continue }
      Assert-RegularRuntimePath $archDirectory
      foreach ($crt in Get-ChildItem -LiteralPath $archDirectory -Directory -Force) {
        if ($crt.Name -notmatch '^Microsoft\.VC(\d+)\.CRT$') { continue }
        $family = [int]$Matches[1]
        Assert-RegularRuntimePath $crt.FullName
        $candidates += [pscustomobject]@{
          Path = $crt.FullName
          Version = [Version]$versionDirectory.Name
          Family = $family
          InstallationPath = $installation.installationPath
        }
      }
    }
  }
  if ($candidates.Count -eq 0) { throw 'No installed x64 Visual C++ redistributable CRT directory' }
  return $candidates | Sort-Object -Property @{Expression='Version'; Descending=$true},
    @{Expression='Family'; Descending=$true}, Path | Select-Object -First 1
}

function Get-LatestInstalledToolsetVersion([object[]]$Installations) {
  $versions = @()
  foreach ($installation in $Installations) {
    $root = Join-Path $installation.installationPath 'VC/Tools/MSVC'
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
    Assert-RegularRuntimePath $root
    foreach ($directory in Get-ChildItem -LiteralPath $root -Directory -Force) {
      if ($directory.Name -match '^\d+\.\d+\.\d+(?:\.\d+)?$') {
        Assert-RegularRuntimePath $directory.FullName
        $versions += [Version]$directory.Name
      }
    }
  }
  if ($versions.Count -eq 0) { throw 'No installed MSVC toolset version available for runtime compatibility check' }
  return $versions | Sort-Object -Descending | Select-Object -First 1
}

function Copy-VerifiedVcRuntime([string]$Source, [object[]]$Manifest, [string[]]$Destinations) {
  foreach ($destination in $Destinations) {
    Assert-RegularRuntimePath $destination
    foreach ($existing in Get-ChildItem -LiteralPath $destination -File -Force) {
      if ($existing.Name -match '^(?i:concrt|msvcp|vccorlib|vcruntime)140.*\.dll$' -and
          $Manifest.filename -notcontains $existing.Name) {
        throw "Unexpected old/debug VC runtime outside selected set: $($existing.FullName)"
      }
    }
    foreach ($entry in $Manifest) {
      $targetFile = Join-Path $destination $entry.filename
      if (Test-Path -LiteralPath $targetFile) {
        Assert-RegularRuntimePath $targetFile
        Assert-NoRuntimeDowngrade ([Version]$entry.version) (Get-Item -LiteralPath $targetFile).VersionInfo $entry.filename
      }
      Copy-Item -LiteralPath (Join-Path $Source $entry.filename) -Destination $targetFile -Force
      if ((Get-FileHash -LiteralPath $targetFile -Algorithm SHA256).Hash.ToLowerInvariant() -ne $entry.sha256) {
        throw "Copied VC runtime checksum mismatch: $targetFile"
      }
    }
    foreach ($name in @('MSVCP140.dll', 'VCRUNTIME140.dll', 'VCRUNTIME140_1.dll')) {
      if (-not (Test-Path -LiteralPath (Join-Path $destination $name) -PathType Leaf)) {
        throw "Application-local VC runtime missing: $destination/$name"
      }
    }
  }
}

function Install-VcRuntime([string]$Target) {
  if (-not $IsWindows) { throw 'VC runtime packaging requires Windows' }
  $bundle = (Get-Item -LiteralPath $Target).FullName
  Assert-RegularRuntimePath $bundle
  foreach ($exe in @('BobTV.exe', 'AirPlay/bobtv-airplay.exe', 'AirPlay/fpsap-auth.exe')) {
    $path = Join-Path $bundle $exe
    Assert-RegularRuntimePath $path
    $null = Get-Amd64PeMachine $path
  }
  $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
  Assert-RegularRuntimePath $vswhere
  $installations = @(& $vswhere -all -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -format json -utf8 |
    ConvertFrom-Json | Where-Object { $_.isComplete -and $_.isLaunchable })
  if ($LASTEXITCODE -ne 0 -or $installations.Count -eq 0) { throw 'vswhere could not find an installed C++ toolset' }
  $source = Find-VcRuntimeSource $installations
  $minimumVersion = Get-LatestInstalledToolsetVersion $installations
  $dlls = @(Get-ChildItem -LiteralPath $source.Path -File -Filter '*.dll' -Force)
  if ($dlls.Count -eq 0) { throw 'Selected redistributable CRT source has no DLLs' }
  $required = @('MSVCP140.dll', 'VCRUNTIME140.dll', 'VCRUNTIME140_1.dll')
  foreach ($name in $required) {
    if ($dlls.Name -notcontains $name) { throw "Required VC runtime DLL missing from redistributable source: $name" }
  }
  $manifest = @()
  foreach ($dll in $dlls) {
    Assert-RegularRuntimePath $dll.FullName
    $null = Get-Amd64PeMachine $dll.FullName -RequireDll
    $signature = Get-AuthenticodeSignature -LiteralPath $dll.FullName
    $version = Assert-MicrosoftRuntimeMetadata $dll.VersionInfo $signature $dll.Name
    if ($version -lt $minimumVersion) {
      throw "VC runtime $($dll.Name) $version is older than installed MSVC toolset $minimumVersion"
    }
    $manifest += [pscustomobject]@{
      filename = $dll.Name
      version = $version.ToString()
      sha256 = (Get-FileHash -LiteralPath $dll.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
      bytes = $dll.Length
    }
  }
  $destinations = @($bundle, (Join-Path $bundle 'AirPlay'))
  $pythonInternal = Join-Path $bundle 'AirPlay/_internal'
  if (Test-Path -LiteralPath $pythonInternal -PathType Container) { $destinations += $pythonInternal }
  Copy-VerifiedVcRuntime $source.Path $manifest $destinations
  $notice = Join-Path $PSScriptRoot 'VC-RUNTIME-NOTICE.txt'
  Assert-RegularRuntimePath $notice
  $noticeTarget = Join-Path $bundle 'VC-RUNTIME-NOTICE.txt'
  if (Test-Path -LiteralPath $noticeTarget) { Assert-RegularRuntimePath $noticeTarget }
  Copy-Item -LiteralPath $notice -Destination $noticeTarget -Force
  $record = [ordered]@{
    schema = 1
    source = "VC/Redist/MSVC/$($source.Version)/x64/Microsoft.VC$($source.Family).CRT"
    minimumToolsetVersion = $minimumVersion.ToString()
    documentation = 'https://learn.microsoft.com/en-us/cpp/windows/redistributing-visual-cpp-files'
    directories = @('.', 'AirPlay') + $(if ($destinations.Count -eq 3) { @('AirPlay/_internal') } else { @() })
    files = $manifest
  }
  $recordPath = Join-Path $bundle 'vc-runtime-manifest.json'
  if (Test-Path -LiteralPath $recordPath) { Assert-RegularRuntimePath $recordPath }
  [IO.File]::WriteAllText($recordPath, ($record | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
  Write-Host "Bundled $($dlls.Count) signed Microsoft AMD64 VC runtime DLLs from $($source.Path) into $($destinations.Count) application-local directories"
}

if ($MyInvocation.InvocationName -ne '.') { Install-VcRuntime $BundleDirectory }
