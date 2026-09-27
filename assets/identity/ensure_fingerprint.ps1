param(
  [string]$TestRoot,
  [string]$TestUuid,
  [string]$TestMachineGuid
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if ($TestRoot) {
  if ($env:BOBTV_IDENTITY_TESTING -ne '1') { throw 'Test mode is disabled' }
  $allowed = [IO.Path]::GetFullPath(
    (Join-Path $env:TEMP 'BobTVIdentityTests')).TrimEnd('\', '/') +
    [IO.Path]::DirectorySeparatorChar
  $requested = [IO.Path]::GetFullPath($TestRoot).TrimEnd('\', '/') +
    [IO.Path]::DirectorySeparatorChar
  if (!$requested.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Test root is outside temporary fixtures'
  }
  $root = $requested.TrimEnd('\', '/')
} else {
  if (!$env:LOCALAPPDATA) { throw 'LocalAppData is unavailable' }
  $root = Join-Path $env:LOCALAPPDATA 'HotelTV\Identity'
}

$fingerprintPath = Join-Path $root 'client_fingerprint.txt'
$mutex = New-Object Threading.Mutex($false, 'Local\BobTVClientFingerprint')
$locked = $false
try {
  $locked = $mutex.WaitOne(30000)
  if (!$locked) { throw 'Fingerprint lock timed out' }
  New-Item -ItemType Directory -Path $root -Force | Out-Null

  if (Test-Path -LiteralPath $fingerprintPath -PathType Leaf) {
    $saved = [IO.File]::ReadAllText($fingerprintPath).Trim()
    if ($saved -match '^btv1_[0-9a-f]{64}$') {
      [Console]::Out.WriteLine($saved.ToLowerInvariant())
      return
    }
  }

  function Normalize-Guid([string]$value) {
    [guid]$parsed = [guid]::Empty
    if (![guid]::TryParse($value, [ref]$parsed) -or
        $parsed -eq [guid]::Empty -or
        $parsed.ToString('D') -eq 'ffffffff-ffff-ffff-ffff-ffffffffffff') {
      return ''
    }
    return $parsed.ToString('D').ToLowerInvariant()
  }

  $uuid = ''
  $machineGuid = ''
  if ($TestRoot) {
    $uuid = Normalize-Guid $TestUuid
    $machineGuid = Normalize-Guid $TestMachineGuid
  } else {
    try {
      $product = Get-CimInstance -ClassName Win32_ComputerSystemProduct `
        -ErrorAction Stop
      $uuid = Normalize-Guid ([string]$product.UUID)
    } catch {}
    try {
      $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
        'SOFTWARE\Microsoft\Cryptography')
      if ($key) {
        try {
          $machineGuid = Normalize-Guid ([string]$key.GetValue('MachineGuid'))
        } finally {
          $key.Dispose()
        }
      }
    } catch {}
  }

  $parts = New-Object 'System.Collections.Generic.List[string]'
  if ($uuid) { $parts.Add('smbios:' + $uuid) }
  if ($machineGuid) { $parts.Add('windows:' + $machineGuid) }
  if ($parts.Count -eq 0) {
    $parts.Add('fallback:' + [guid]::NewGuid().ToString('D'))
  }

  $salt = New-Object byte[] 32
  $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
  try {
    $rng.GetBytes($salt)
  } finally {
    $rng.Dispose()
  }
  $payload = 'BobTV-client-v1|' + ($parts -join '|') + '|' +
    [BitConverter]::ToString($salt)
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($payload))
  } finally {
    $sha.Dispose()
  }
  $fingerprint = 'btv1_' + [BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant()
  $temporary = $fingerprintPath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
  try {
    [IO.File]::WriteAllText(
      $temporary, $fingerprint, (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temporary -Destination $fingerprintPath -Force
  } finally {
    Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
  }
  [Console]::Out.WriteLine($fingerprint)
} finally {
  if ($locked) { $mutex.ReleaseMutex() }
  $mutex.Dispose()
}
