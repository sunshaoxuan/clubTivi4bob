param(
  [ValidateSet('Update','Rollback')][string]$Mode='Update',
  [string]$AppDir,[int]$CurrentPid,[string]$Version,[string]$OldVersion,
  [string]$ArchiveUrl,[string]$Sha256,[long]$Bytes,[string]$Signature,
  [string]$PreviousUrl,[string]$PreviousSha256,[long]$PreviousBytes,[string]$PreviousSignature,
  [string]$RunId,[string]$TestRoot,[switch]$VerifyOnly
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$root=Join-Path $env:LOCALAPPDATA 'HotelTV\Update'
if($TestRoot){
  $allowed=[IO.Path]::GetFullPath((Join-Path $env:TEMP 'BobTVUpdaterTests')).TrimEnd('\')+'\'
  if($env:CI -ne 'true' -or ![IO.Path]::GetFullPath($TestRoot).StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe test root'}
  $root=$TestRoot
}
New-Item -ItemType Directory -Path $root -Force|Out-Null
. (Join-Path $PSScriptRoot 'publisher_signature.ps1')
$publicKey=Join-Path $PSScriptRoot 'update-signing-public.pem'
$log=Join-Path $root 'installer-worker.log'
$candidatePath=Join-Path $root 'candidate.ini'
$script:cancelled=$false
$script:authorizationRequestId=$null
$script:restored=$false
$script:installationStarted=$false
$script:received=0L
$script:total=$Bytes
function Log([string]$text){Add-Content -LiteralPath $log -Value ([DateTime]::UtcNow.ToString('o')+' '+$text) -Encoding UTF8}
function Write-Log([string]$text){Log $text}
# Reuse the existing narrowly scoped monitor-lock helpers without executing
# the portable worker's entry point. No administrator script is launched.
$tokens=$null;$parseErrors=$null
$legacy=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'worker.ps1'),[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw 'Invalid application-lock helper source'}
foreach($name in @('Suspend-AppCrashMonitor','Resume-AppCrashMonitor')){
  $definition=$legacy.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
  if(!$definition){throw 'Application-lock helper missing'}
  . ([ScriptBlock]::Create($definition.Extent.Text))
}
function Hash([string]$path){
  $s=[IO.File]::OpenRead($path);$h=[Security.Cryptography.SHA256]::Create()
  try{return [BitConverter]::ToString($h.ComputeHash($s)).Replace('-','').ToLowerInvariant()}finally{$s.Dispose();$h.Dispose()}
}
function Status([string]$phase,[Nullable[int]]$percent,[string]$message){
  $payload=@{version=$Version;runId=$RunId;workerPid=$PID;phase=$phase;percent=$percent;message=$message;
    time=[DateTime]::UtcNow.ToString('o');receivedBytes=$script:received;totalBytes=$script:total;
    requiresAuthorization=$true;authorizationCancelled=$script:cancelled;oldVersion=$OldVersion;
    authorizationRequestId=$script:authorizationRequestId;restored=$script:restored}|ConvertTo-Json -Compress
  foreach($name in @('status.json',('status-'+$RunId+'.json'))){
    $path=Join-Path $root $name;$temp=$path+'.tmp'
    [IO.File]::WriteAllText($temp,$payload,(New-Object Text.UTF8Encoding($false)))
    for($attempt=0;;$attempt++){
      try{
        if([IO.File]::Exists($path)){[IO.File]::Replace($temp,$path,[NullString]::Value,$true)}else{[IO.File]::Move($temp,$path)}
        break
      }catch [IO.IOException]{if($attempt -ge 99){throw};Start-Sleep -Milliseconds 20}
    }
  }
  Log ('phase='+$phase)
}
function Validate-App([string]$path){
  if(!$path -or $path -match '["\r\n]' -or !(Test-Path -LiteralPath $path -PathType Container)){throw 'Invalid app directory'}
  $full=[IO.Path]::GetFullPath($path).TrimEnd('\')
  if($TestRoot -and !$full.StartsWith([IO.Path]::GetFullPath($TestRoot).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Test app must stay inside the isolated root'}
  if($full -match '^[A-Za-z]:$' -or $full.StartsWith('\\') -or !(Test-Path -LiteralPath (Join-Path $full 'installation.ini')) -or !(Test-Path -LiteralPath (Join-Path $full 'data\app.so'))){throw 'Managed app directory missing'}
  if(!(Test-Path -LiteralPath (Join-Path $full 'BobTV.exe'))){throw 'Managed executable missing'}
  return $full
}
function Download-Installer([string]$url,[string]$hash,[long]$size,[string]$signature,[string]$version,[string]$message){
  if($version -notmatch '^\d+\.\d+\.\d+\+\d+$' -or $hash -notmatch '^[a-f0-9]{64}$' -or $size -lt 1000000 -or $size -gt 2000000000){throw 'Invalid Setup metadata'}
  $uri=[Uri]$url
  $valid=($uri.Host -eq 'bobtv.briconbric.com' -and $uri.AbsolutePath.StartsWith('/updates/files/')) -or
         ($uri.Host -eq 'cndrp.com' -and $uri.AbsolutePath.StartsWith('/bobtv/updates/files/'))
  $filename=[IO.Path]::GetFileName($uri.AbsolutePath)
  $pattern='^BobTV-'+[Regex]::Escape($version)+'-windows-(x64|arm64)-Setup\.exe$'
  if($uri.Scheme -ne 'https' -or !$valid -or $uri.Port -ne 443 -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $filename -notmatch $pattern){throw 'Invalid Setup URL'}
  $folder=Join-Path $root 'Installers';New-Item -ItemType Directory -Path $folder -Force|Out-Null
  $target=Join-Path $folder $filename
  $script:total=$size;$script:received=0L
  if(!(Test-Path -LiteralPath $target) -or (Get-Item -LiteralPath $target).Length -ne $size -or (Hash $target) -ne $hash){
    Status 'downloading' 0 $message
    $partial=$target+'.part'
    Add-Type -AssemblyName System.Net.Http
    $handler=New-Object Net.Http.HttpClientHandler;$handler.AllowAutoRedirect=$false
    $http=New-Object Net.Http.HttpClient($handler);$http.Timeout=[TimeSpan]::FromSeconds(45)
    $http.DefaultRequestHeaders.UserAgent.ParseAdd('BobTV/1.1 updater')
    try{
      $response=$http.GetAsync($uri,[Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
      if([int]$response.StatusCode -ne 200){throw 'Setup download failed'}
      $input=$response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
      $output=[IO.File]::Open($partial,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None)
      try{
        $buffer=New-Object byte[] (1MB);$last=-1
        while($true){
          $read=$input.ReadAsync($buffer,0,$buffer.Length)
          if(!$read.Wait(30000)){throw '下载连续30秒没有收到数据，请重试'}
          $count=$read.GetAwaiter().GetResult();if($count -le 0){break}
          $output.Write($buffer,0,$count);$script:received+=$count
          if($script:received -gt $size){throw 'Setup grew unexpectedly'}
          $percent=[int][Math]::Floor(100.0*$script:received/$size)
          if($percent -ne $last){Status 'downloading' $percent $message;$last=$percent}
        }
      }finally{$output.Dispose();$input.Dispose()}
    }finally{$http.Dispose();$handler.Dispose()}
    if((Get-Item -LiteralPath $partial).Length -ne $size -or (Hash $partial) -ne $hash){throw 'Setup checksum mismatch'}
    Move-Item -LiteralPath $partial -Destination $target -Force
  }
  $script:received=$size
  Status 'verifying' 100 '正在校验 BobTV 发布者签章与安装包版本'
  if(!(Test-BobTvPublisherSignature $target $signature $publicKey)){throw 'Setup publisher signature mismatch'}
  # Inno version resources can expose trailing padding through FileVersionInfo.
  $actualVersion=(Get-Item -LiteralPath $target).VersionInfo.FileVersion.Trim([char[]]@([char]0,[char]32))
  if($actualVersion -ne $version.Replace('+','.')){throw ('Setup version mismatch: expected '+$version.Replace('+','.')+', found '+$actualVersion)}
  return $target
}
function Start-AuthorizedSetup([string]$setup,[string]$target,[int]$waitPid,[string]$message='请在 Windows 系统窗口中授权。取消后会保留当前版本。'){
  Status 'authorizing' $null $message
  return Start-Process -FilePath $setup -Verb RunAs -PassThru -ArgumentList @(
    '/SILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-','/NOCLOSEAPPLICATIONS',
    ('/DIR="'+$target+'"'),('/BOBTVWAITPID='+$waitPid),
    ('/LOG="'+(Join-Path $root ('setup-'+$RunId+'.log'))+'"'))
}
function Test-AuthorizationCancelled([Exception]$exception){
  # Start-Process can wrap the Win32 cancellation in an InvalidOperationException.
  for($depth=0;$exception -and $depth -lt 8;$depth++){
    if(($exception -is [ComponentModel.Win32Exception] -and $exception.NativeErrorCode -eq 1223) -or
       $exception.HResult -eq -2147023673){return $true}
    $exception=$exception.InnerException
  }
  return $false
}
function Assert-Installed([string]$version){
  if((Get-Item -LiteralPath (Join-Path $AppDir 'BobTV.exe')).VersionInfo.FileVersion -ne $version -or
     !(Test-Path -LiteralPath (Join-Path $AppDir 'data\app.so'))){throw 'Installed application verification failed'}
}
$mutex=New-Object Threading.Mutex($false,'Local\BobTVUpdater')
$locked=$false
try{
  $locked=$mutex.WaitOne(0);if(!$locked){throw 'Another update is running'}
  if($Mode -eq 'Rollback'){
    $saved=@{}
    foreach($line in [IO.File]::ReadAllLines($candidatePath)){if($line -match '^([A-Za-z][A-Za-z0-9]*)=(.*)$'){$saved[$matches[1]]=$matches[2]}}
    if($saved.InstallMethod -ne 'Setup'){throw 'Invalid Setup rollback state'}
    $AppDir=$saved.AppDir;$Version=$saved.Version;$OldVersion=$saved.OldVersion
    $RunId='rollback-'+[Guid]::NewGuid().ToString('N')
    $previous=Download-Installer $saved.PreviousUrl $saved.PreviousSha256 ([long]$saved.PreviousBytes) $saved.PreviousSignature $OldVersion '正在准备安全回退安装包'
  }
  if($Version -notmatch '^\d+\.\d+\.\d+\+\d+$' -or $OldVersion -notmatch '^\d+\.\d+\.\d+\+\d+$' -or $RunId -notmatch '^[A-Za-z0-9-]{1,100}$'){throw 'Invalid update identity'}
  $AppDir=Validate-App $AppDir
  if($Mode -eq 'Update'){
    if($CurrentPid -le 0){throw 'Invalid player process ID'}
    if((Get-Item -LiteralPath (Join-Path $AppDir 'BobTV.exe')).VersionInfo.FileVersion -ne $OldVersion){throw 'Installed version changed'}
    $previous=Download-Installer $PreviousUrl $PreviousSha256 $PreviousBytes $PreviousSignature $OldVersion '正在下载旧版回退包，确保升级失败时可以恢复'
    $setup=Download-Installer $ArchiveUrl $Sha256 $Bytes $Signature $Version '正在下载 BobTV 更新，无需打开浏览器'
    if($VerifyOnly){if(!$TestRoot){throw 'VerifyOnly requires an isolated test root'};return}
    Status 'backingUp' $null '正在备份当前版本，频道和收藏将保留'
    $backup=Join-Path $root ('Backups\Setup-'+$Version.Replace('+','_')+'-'+[Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $backup -Force|Out-Null
    foreach($item in Get-ChildItem -LiteralPath $AppDir -Force){Copy-Item -LiteralPath $item.FullName -Destination $backup -Recurse -Force}
    if((Hash (Join-Path $backup 'data\app.so')) -ne (Hash (Join-Path $AppDir 'data\app.so')) -or
       (Get-Item -LiteralPath (Join-Path $backup 'BobTV.exe')).VersionInfo.FileVersion -ne $OldVersion){throw 'Old version backup mismatch'}
    Status 'ready' 100 '下载、签章校验和旧版备份已完成。点击安装更新，授权后会自动关闭并安装。'
    $requestPath=Join-Path $root ('install-request-'+$RunId+'.txt')
    $watched=Get-Process -Id $CurrentPid -ErrorAction SilentlyContinue
    while($true){
      while($watched -and !$watched.HasExited -and !(Test-Path -LiteralPath $requestPath)){Start-Sleep -Milliseconds 300;$watched.Refresh()}
      if(Test-Path -LiteralPath $requestPath){
        $request=[IO.File]::ReadAllText($requestPath)|ConvertFrom-Json
        if($request.runId -ne $RunId -or $request.requestId -notmatch '^[A-Za-z0-9-]{1,100}$'){throw 'Invalid installation request'}
        $script:authorizationRequestId=[string]$request.requestId
        Remove-Item -LiteralPath $requestPath -Force
      }
      try{$script:cancelled=$false;$installer=Start-AuthorizedSetup $setup $AppDir $CurrentPid;break}
      catch{
        if(!(Test-AuthorizationCancelled $_.Exception)){throw}
        $script:cancelled=$true;Status 'ready' 100 '已取消授权，当前版本未改变。点击安装更新可再次授权。'
        if(!$watched -or $watched.HasExited){return}
      }
    }
    Suspend-AppCrashMonitor $AppDir
    Status 'awaitingExit' $null 'Windows 已授权，BobTV 即将关闭。请稍候，随后会显示安装进度。'
    if($watched -and !$watched.HasExited){$watched.WaitForExit()}
  }else{
    $setup=$previous
    $installer=Start-AuthorizedSetup $setup $AppDir $CurrentPid
    Suspend-AppCrashMonitor $AppDir
  }
  Status 'installing' $null '正在安装，请等待完成提示。Windows 不会自动重启。'
  $script:installationStarted=$true
  $installer.WaitForExit()
  $expected=if($Mode -eq 'Rollback'){$OldVersion}else{$Version}
  if($installer.ExitCode -ne 0){throw ('Installer did not complete successfully: '+$installer.ExitCode)}
  Assert-Installed $expected
  if($Mode -eq 'Rollback'){
    Add-Content -LiteralPath (Join-Path $root 'skipped_versions.txt') -Value $Version -Encoding ASCII
    Remove-Item -LiteralPath $candidatePath,(Join-Path $root 'startup.marker'),(Join-Path $root 'startup.healthy') -Force -ErrorAction SilentlyContinue
    $script:restored=$true
    Status 'failed' 0 '新版连续三次启动失败，已授权恢复旧版。故障记录已保留。'
  }else{
    $values=@{Version=$Version;AppDir=$AppDir;BackupDir=$backup;Attempts=0;InstallMethod='Setup';OldVersion=$OldVersion;
      PreviousUrl=$PreviousUrl;PreviousSha256=$PreviousSha256;PreviousBytes=$PreviousBytes;PreviousSignature=$PreviousSignature}
    $text="[Update]`r`n"+((@($values.Keys|Sort-Object)|ForEach-Object {$_+'='+$values[$_]}) -join "`r`n")+"`r`n"
    [IO.File]::WriteAllText($candidatePath,$text,(New-Object Text.UTF8Encoding($false)))
    Status 'installed' 100 '更新已完成，旧版已备份。可以启动 BobTV。'
  }
}catch{
  $failure=$_.Exception.Message
  Log $_.Exception.ToString()
  if($Mode -eq 'Update' -and $script:installationStarted -and $previous){
    try{
      $restore=Start-AuthorizedSetup $previous $AppDir 0 '新版安装未完成，请授权恢复已校验的旧版安装包。旧版备份和用户数据均已保留。'
      Status 'installing' $null '正在恢复旧版，请等待完成提示。'
      $restore.WaitForExit()
      if($restore.ExitCode -ne 0){throw 'Previous Setup failed'}
      Assert-Installed $OldVersion
      $script:restored=$true
      Add-Content -LiteralPath (Join-Path $root 'skipped_versions.txt') -Value $Version -Encoding ASCII
      $failure+='，已恢复旧版 '+$OldVersion
    }catch{
      Log ('restore_failed: '+$_.Exception.ToString())
      $failure+='，旧版恢复尚未完成，请保留更新日志和备份'
    }
  }
  if($Version -match '^\d+\.\d+\.\d+\+\d+$' -and $RunId){Status 'failed' 0 ('更新未完成：'+$failure+'。下载和备份已保留。')}
  exit 1
}finally{
  try{Resume-AppCrashMonitor $AppDir}catch{Log ('monitor_resume_failed: '+$_.Exception.Message)}
  if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()
}
