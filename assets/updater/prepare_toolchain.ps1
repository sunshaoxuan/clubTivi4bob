param([string]$ArchiveUrl,[string]$Sha256,[long]$Bytes,[string]$Signature,[string]$Version,
      [string]$Destination,[string]$TestRoot,[string]$TestArchive)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$root=Join-Path $env:LOCALAPPDATA 'HotelTV\Update'
if($TestRoot){
  $allowed=[IO.Path]::GetFullPath((Join-Path $env:TEMP 'BobTVUpdaterTests')).TrimEnd('\')+'\'
  if($env:CI -ne 'true' -or ![IO.Path]::GetFullPath($TestRoot).StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe test root'}
  $root=$TestRoot
}
if($Version -notmatch '^\d+\.\d+\.\d+\+\d+$' -or $Sha256 -notmatch '^[a-f0-9]{64}$' -or $Bytes -lt 1024 -or $Bytes -gt 2097152){throw 'Invalid updater metadata'}
$parent=[IO.Path]::GetFullPath((Join-Path $root 'Toolchains')).TrimEnd('\')
$Destination=[IO.Path]::GetFullPath($Destination).TrimEnd('\')
if(![IO.Path]::GetDirectoryName($Destination).Equals($parent,[StringComparison]::OrdinalIgnoreCase) -or
   [IO.Path]::GetFileName($Destination) -notmatch '^toolchain-[a-f0-9]{64}-[0-9]+$' -or (Test-Path -LiteralPath $Destination)){throw 'Invalid toolchain destination'}
New-Item -ItemType Directory -Path $parent -Force|Out-Null
foreach($path in @($root,$parent)){
  if((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Toolchain directory link forbidden'}
}
. (Join-Path $PSScriptRoot 'publisher_signature.ps1')
$key=Join-Path $PSScriptRoot 'update-signing-public.pem'
function Hash([string]$path){
  $stream=[IO.File]::OpenRead($path);$hash=[Security.Cryptography.SHA256]::Create()
  try{return [BitConverter]::ToString($hash.ComputeHash($stream)).Replace('-','').ToLowerInvariant()}
  finally{$stream.Dispose();$hash.Dispose()}
}
$archive=Join-Path $root ('updater-'+$Sha256+'.zip')
$partial=$archive+'.'+[Guid]::NewGuid().ToString('N')+'.part'
$stage=Join-Path $parent ('pending-'+[Guid]::NewGuid().ToString('N'))
try{
  if(!(Test-Path -LiteralPath $archive) -or (Get-Item -LiteralPath $archive).Length -ne $Bytes -or (Hash $archive) -ne $Sha256){
    if($TestArchive){
      if(!$TestRoot -or $env:CI -ne 'true'){throw 'Test archive not enabled'}
      Copy-Item -LiteralPath $TestArchive -Destination $partial
    }else{
      $uri=[Uri]$ArchiveUrl;$publicVersion=$Version.Split('+')[0]
      $valid=($uri.Host -eq 'bobtv.briconbric.com' -and $uri.AbsolutePath.StartsWith('/updates/files/')) -or
             ($uri.Host -eq 'cndrp.com' -and $uri.AbsolutePath.StartsWith('/bobtv/updates/files/'))
      if($uri.Scheme -ne 'https' -or !$valid -or $uri.Port -ne 443 -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or
         [IO.Path]::GetFileName($uri.AbsolutePath) -notmatch ('^BobTV-'+[Regex]::Escape($publicVersion)+'-windows-(x64|arm64)-Updater\.zip$')){throw 'Invalid updater URL'}
      [Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
      Add-Type -AssemblyName System.Net.Http
      $handler=New-Object Net.Http.HttpClientHandler;$handler.AllowAutoRedirect=$false
      $http=New-Object Net.Http.HttpClient($handler);$http.Timeout=[TimeSpan]::FromSeconds(45)
      try{
        $response=$http.GetAsync($uri,[Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        if([int]$response.StatusCode -ne 200){throw 'Updater download failed'}
        $input=$response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $output=[IO.File]::Open($partial,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try{
          $buffer=New-Object byte[] 65536;$received=0L;$deadline=[DateTime]::UtcNow.AddSeconds(60)
          while($true){
            if([DateTime]::UtcNow -gt $deadline){throw 'Updater download deadline'}
            $task=$input.ReadAsync($buffer,0,$buffer.Length)
            if(!$task.Wait(30000)){throw 'Updater download timeout'}
            $count=$task.GetAwaiter().GetResult();if(!$count){break}
            $received+=$count;if($received -gt $Bytes){throw 'Updater size limit'}
            $output.Write($buffer,0,$count)
          }
        }finally{$output.Dispose();$input.Dispose()}
      }finally{$http.Dispose();$handler.Dispose()}
    }
    if((Get-Item -LiteralPath $partial).Length -ne $Bytes -or (Hash $partial) -ne $Sha256){throw 'Updater checksum mismatch'}
    Move-Item -LiteralPath $partial -Destination $archive -Force
  }
  # The pinned bundled verifier authenticates the whole component before any
  # new code is parsed or executed. Cached bytes are checked again on every use.
  if(!(Test-BobTvPublisherSignature $archive $Signature $key)){throw 'Updater publisher signature mismatch'}
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip=[IO.Compression.ZipFile]::OpenRead($archive)
  $expected=@('worker.ps1','installer_worker.ps1','publisher_signature.ps1','progress_ui.ps1','update-signing-public.pem','updater.json')
  try{
    if($zip.Entries.Count -ne $expected.Count){throw 'Invalid updater entry count'}
    $seen=@{};$expanded=0L
    foreach($entry in $zip.Entries){
      if($entry.FullName -cnotin $expected -or $seen.ContainsKey($entry.FullName) -or
         (($entry.ExternalAttributes -shr 16) -band 61440) -eq 40960){throw 'Unsafe updater entry'}
      $seen[$entry.FullName]=$true;$expanded+=$entry.Length
      if($expanded -gt 2097152 -or $entry.Length -le 0){throw 'Updater expanded limit'}
    }
    New-Item -ItemType Directory -Path $stage|Out-Null
    foreach($entry in $zip.Entries){[IO.Compression.ZipFileExtensions]::ExtractToFile($entry,(Join-Path $stage $entry.FullName))}
  }finally{$zip.Dispose()}
  $metadata=[IO.File]::ReadAllText((Join-Path $stage 'updater.json'))|ConvertFrom-Json
  if($metadata.protocol -ne 1 -or $metadata.version -ne $Version -or
     (@($metadata.modes) -join ',') -ne 'windows-managed,windows-portable'){throw 'Updater compatibility mismatch'}
  if([IO.File]::ReadAllText((Join-Path $stage 'update-signing-public.pem')).Trim() -ne [IO.File]::ReadAllText($key).Trim()){throw 'Updater signing key mismatch'}
  foreach($name in $expected|Where-Object {$_ -like '*.ps1'}){
    $tokens=$null;$errors=$null
    $null=[Management.Automation.Language.Parser]::ParseFile((Join-Path $stage $name),[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'Invalid updater script'}
  }
  [IO.Directory]::Move($stage,$Destination)
  Write-Output 'Verified updater prepared'
}finally{
  if(Test-Path -LiteralPath $partial){Remove-Item -LiteralPath $partial -Force}
  if(Test-Path -LiteralPath $stage){Remove-Item -LiteralPath $stage -Recurse -Force}
}
