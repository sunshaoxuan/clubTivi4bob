param(
  [Parameter(Mandatory=$true)][string]$Archive,
  [Parameter(Mandatory=$true)][string]$Version,
  [Parameter(Mandatory=$true)][string]$UploadBaseUrl
)

$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$token=$env:BOBTV_MIRROR_TOKEN
if([string]::IsNullOrWhiteSpace($token)) { throw 'BOBTV_MIRROR_TOKEN is required' }
if($Version -notmatch '^\d+\.\d+\.\d+\+\d+$') { throw 'Invalid release version' }
if(!(Test-Path -LiteralPath $Archive -PathType Leaf)) { throw 'Archive not found' }
$uploadBase=[Uri]$UploadBaseUrl
if($uploadBase.Scheme -ne 'https' -or
   $uploadBase.Host -ne 'bobtv.briconbric.com' -or
   $uploadBase.Query -ne '' -or $uploadBase.Fragment -ne '') {
  throw 'Upload endpoint must use the configured HTTPS mirror'
}

$archiveName=[IO.Path]::GetFileName($Archive)
if($archiveName -notmatch '^BobTV-[A-Za-z0-9.+_-]+-windows-x64\.zip$') {
  throw 'Unexpected portable archive name'
}
$size=(Get-Item -LiteralPath $Archive).Length
$hash=(Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash.ToLowerInvariant()
$publicBase='https://bobtv.briconbric.com/updates/'
$temporary=Join-Path $env:TEMP ('BobTV-verify-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporary | Out-Null
try {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip=[IO.Compression.ZipFile]::OpenRead($Archive)
  try {
    $exe=$zip.Entries | Where-Object {
      $_.FullName.Replace('\','/') -eq 'BobTV/BobTV.exe'
    } | Select-Object -First 1
    if(!$exe) { throw 'BobTV.exe is missing from release archive' }
    $extracted=Join-Path $temporary 'BobTV.exe'
    [IO.Compression.ZipFileExtensions]::ExtractToFile($exe,$extracted,$false)
    if((Get-Item $extracted).VersionInfo.FileVersion -ne $Version) {
      throw 'Archive executable version does not match manifest'
    }
  } finally {
    $zip.Dispose()
  }

  $client=New-Object Net.WebClient
  $client.Headers.Add('Authorization','Bearer '+$token)
  try {
    $uploadArchive=$UploadBaseUrl.TrimEnd('/')+'/'+$archiveName
    $null=$client.UploadFile($uploadArchive,'PUT',$Archive)
    $publicArchive=$publicBase+$archiveName
    $verified=Join-Path $temporary $archiveName
    $reader=New-Object Net.WebClient
    try { $reader.DownloadFile($publicArchive,$verified) }
    finally { $reader.Dispose() }
    if((Get-Item $verified).Length -ne $size -or
       (Get-FileHash $verified -Algorithm SHA256).Hash.ToLowerInvariant() -ne $hash) {
      throw 'Published archive failed mirror read-back verification'
    }

    $manifest=@{
      schema=1
      version=$Version
      archive=$publicArchive
      sha256=$hash
      bytes=$size
      publishedAt=[DateTime]::UtcNow.ToString('o')
    } | ConvertTo-Json -Compress
    $manifestFile=Join-Path $temporary 'latest.json'
    [IO.File]::WriteAllText(
      $manifestFile,$manifest,(New-Object Text.UTF8Encoding($false)))
    $null=$client.UploadFile(
      ($UploadBaseUrl.TrimEnd('/')+'/latest.json'),'PUT',$manifestFile)
    $reader=New-Object Net.WebClient
    try {
      $published=$reader.DownloadString($publicBase+'latest.json') |
        ConvertFrom-Json
    } finally {
      $reader.Dispose()
    }
    if($published.version -ne $Version -or
       $published.sha256 -ne $hash -or
       $published.archive -ne $publicArchive) {
      throw 'Published manifest failed mirror read-back verification'
    }
    @{
      version=$Version
      archive=$publicArchive
      manifest=$publicBase+'latest.json'
      sha256=$hash
      bytes=$size
    } | ConvertTo-Json -Compress
  } finally {
    $client.Dispose()
  }
} finally {
  Remove-Item -LiteralPath $temporary -Recurse -Force
}
