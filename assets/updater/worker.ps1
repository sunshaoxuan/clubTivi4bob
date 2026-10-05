param(
  [ValidateSet('Update', 'Rollback', 'Monitor')][string]$Mode,
  [string]$AppDir,
  [int]$CurrentPid,
  [string]$Version,
  [string]$ArchiveUrl,
  [string]$Sha256,
  [long]$Bytes,
  [string]$RunId,
  [string]$TestRoot
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = Join-Path $env:LOCALAPPDATA 'HotelTV\Update'
if ($TestRoot) {
  if ($env:BOBTV_UPDATE_TESTING -ne '1') { throw 'Test root not enabled' }
  $allowed = [IO.Path]::GetFullPath(
    (Join-Path $env:TEMP 'BobTVUpdaterTests')).TrimEnd('\') + '\'
  $requested = [IO.Path]::GetFullPath($TestRoot).TrimEnd('\') + '\'
  if (!$requested.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Test root is outside temporary fixtures'
  }
  $root = $requested.TrimEnd('\')
}
$statePath = Join-Path $root 'candidate.ini'
$statusPath = Join-Path $root 'status.json'
$runStatusPath = $null
if($RunId) {
  if($RunId -notmatch '^[A-Za-z0-9-]{1,100}$'){throw 'Invalid updater run ID'}
  $runStatusPath=Join-Path $root ('status-'+$RunId+'.json')
}
$markerPath = Join-Path $root 'startup.marker'
$healthyPath = Join-Path $root 'startup.healthy'
$skippedPath = Join-Path $root 'skipped_versions.txt'
$logPath = Join-Path $root 'worker.log'
New-Item -ItemType Directory -Path $root -Force | Out-Null
$watchedProcess = if ($CurrentPid -gt 0) {
  Get-Process -Id $CurrentPid -ErrorAction SilentlyContinue
}

function Write-Log([string]$message) {
  Add-Content -LiteralPath $logPath -Value (
    [DateTime]::UtcNow.ToString('o') + ' ' + $message) -Encoding utf8
}

function Get-Sha256([string]$path) {
  # Do not depend on script-module discovery inherited from PowerShell 7 hosts.
  $stream=[IO.File]::OpenRead($path)
  $hash=[Security.Cryptography.SHA256]::Create()
  try { return [BitConverter]::ToString($hash.ComputeHash($stream)).Replace('-','') }
  finally { $hash.Dispose(); $stream.Dispose() }
}

function Write-Status([string]$phase, [string]$version, [int]$percent,
                      [string]$message) {
  if($script:lastWrittenPhase -eq $phase -and
     $script:lastWrittenPercent -eq $percent -and
     $script:lastWrittenMessage -eq $message){return}
  if($script:lastPhase -ne $phase){
    $script:lastPhase=$phase
    Write-Log ('Phase='+$phase+' version='+$version+' run='+$RunId)
  }
  $json = @{
    phase = $phase
    version = $version
    percent = $percent
    message = $message
    time = [DateTime]::UtcNow.ToString('o')
    runId = $RunId
    workerPid = $PID
    receivedBytes = $script:receivedBytes
    totalBytes = $Bytes
  } | ConvertTo-Json -Compress
  $paths=@()
  if(!$RunId -or $script:locked){$paths+=@($statusPath)}
  if($runStatusPath){$paths+=@($runStatusPath)}
  foreach($path in $paths){
    $temp = $path + '.tmp'
    [IO.File]::WriteAllText($temp, $json, (New-Object Text.UTF8Encoding($false)))
    $published=$false
    for($attempt=0;$attempt -lt 100;$attempt++){
      try{
        if([IO.File]::Exists($path)){
          # Windows PowerShell 5.1 coerces $null to an empty string here.
          [IO.File]::Replace($temp,$path,[NullString]::Value,$true)
        }else{[IO.File]::Move($temp,$path)}
        $published=$true
        break
      }catch [IO.IOException]{Start-Sleep -Milliseconds 20}
    }
    if(!$published){throw ('Unable to publish updater status: '+$path)}
  }
  $script:lastWrittenPhase=$phase
  $script:lastWrittenPercent=$percent
  $script:lastWrittenMessage=$message
}

function Read-State {
  $result = @{}
  if (!(Test-Path -LiteralPath $statePath)) { return $result }
  foreach ($line in [IO.File]::ReadAllLines($statePath)) {
    if ($line -match '^([A-Za-z]+)=(.*)$') {
      $result[$matches[1]] = $matches[2]
    }
  }
  return $result
}

function Set-Attempts([int]$count) {
  if (!(Test-Path -LiteralPath $statePath)) { return }
  $source = [IO.File]::ReadAllText($statePath)
  $updated = [regex]::Replace(
    $source, '(?m)^Attempts=\d+\r?$', ('Attempts=' + $count))
  if ($updated -eq $source -and $count -ne 0) {
    throw 'Candidate attempt counter missing'
  }
  [IO.File]::WriteAllText(
    $statePath, $updated, (New-Object Text.UTF8Encoding($false)))
}

function Assert-AppDir([string]$path) {
  if ([string]::IsNullOrWhiteSpace($path) -or
      !(Test-Path -LiteralPath $path -PathType Container)) {
    throw 'Application directory missing'
  }
  $full = [IO.Path]::GetFullPath($path).TrimEnd('\')
  if ($full -match '^[A-Za-z]:$' -or $full -ieq $env:LOCALAPPDATA) {
    throw 'Unsafe application directory'
  }
  return $full
}

function Wait-ForExit([int]$processId) {
  if ($processId -le 0) { throw 'Missing process ID' }
  if ($script:watchedProcess) {
    $script:watchedProcess.WaitForExit()
  }
}

function Wait-ForAppIdle([string]$path) {
  $prefix = [IO.Path]::GetFullPath($path).TrimEnd('\') + '\'
  while ($true) {
    $running = @(Get-Process -Name 'clubtivi','BobTV' -ErrorAction SilentlyContinue |
      Where-Object {
        try {
          $_.Path -and $_.Path.StartsWith(
            $prefix, [StringComparison]::OrdinalIgnoreCase)
        } catch { $false }
      })
    if ($running.Count -eq 0) { return }
    Start-Sleep -Seconds 2
  }
}

function Copy-AppFile([string]$source, [string]$destination) {
  if((Test-Path -LiteralPath $destination -PathType Leaf) -and
     (Get-Sha256 $source) -eq (Get-Sha256 $destination)){return}
  New-Item -ItemType Directory -Path (Split-Path $destination) -Force | Out-Null
  Copy-Item -LiteralPath $source -Destination $destination -Force
  if((Get-Sha256 $source) -ne (Get-Sha256 $destination)){
    throw ('Installed file verification failed: '+$destination)
  }
}

function Suspend-AppCrashMonitor([string]$path) {
  $script:crashMonitorDir=$path
  $monitor=Join-Path $path 'Tools\hoteltv_crash_monitor.ps1'
  $escaped=[regex]::Escape($monitor)
  $script:resumeCrashMonitor=$false
  $processes=@(Get-CimInstance Win32_Process)
  foreach($process in $processes){
    if($process.Name -ieq 'powershell.exe' -and
       $process.CommandLine -match ('["\s]'+$escaped+'["\s]')){
      Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
      $script:resumeCrashMonitor=$true
      Write-Log ('Paused BobTV crash monitor PID='+$process.ProcessId)
    }
  }
  $toolsPrefix=[IO.Path]::GetFullPath((Join-Path $path 'Tools')).TrimEnd('\')+'\'
  foreach($process in $processes){
    if($process.Name -in @('procdump.exe','procdump64.exe') -and
       $process.ExecutablePath -and $process.ExecutablePath.StartsWith($toolsPrefix,[StringComparison]::OrdinalIgnoreCase)){
      $live=Get-Process -Id $process.ProcessId -ErrorAction SilentlyContinue
      if($live){
        Stop-Process -Id $live.Id -Force -ErrorAction Stop
        if(!$live.WaitForExit(5000)){throw 'BobTV crash monitor did not release its executable'}
        Write-Log ('Stopped BobTV ProcDump PID='+$process.ProcessId)
      }
    }
  }
}

function Resume-AppCrashMonitor([string]$path) {
  if(!$script:resumeCrashMonitor){return}
  $path=$script:crashMonitorDir
  $monitor=Join-Path $path 'Tools\hoteltv_crash_monitor.ps1'
  $tool=Join-Path $path 'Tools\procdump64.exe'
  if(!(Test-Path -LiteralPath $monitor) -or !(Test-Path -LiteralPath $tool)){return}
  $dumps=Join-Path (Split-Path $root) 'CrashDumps'
  Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @(
    '-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$monitor+'"'),
    '-ProcDumpPath',('"'+$tool+'"'),'-DumpFolder',('"'+$dumps+'"')) | Out-Null
  Write-Log 'Resumed BobTV crash monitor'
}

function Copy-Contents([string]$source, [string]$destination) {
  New-Item -ItemType Directory -Path $destination -Force | Out-Null
  Get-ChildItem -LiteralPath $source -Recurse -File -Force | ForEach-Object {
    $relative=$_.FullName.Substring($source.TrimEnd('\').Length).TrimStart('\')
    Copy-AppFile $_.FullName (Join-Path $destination $relative)
  }
}

function Compare-BobVersion([string]$left, [string]$right) {
  if ($left -notmatch '^\d+\.\d+\.\d+\+\d+$' -or
      $right -notmatch '^\d+\.\d+\.\d+\+\d+$') {
    throw 'Invalid installed version'
  }
  $a=@(($left -split '[.+]') | ForEach-Object { [long]$_ })
  $b=@(($right -split '[.+]') | ForEach-Object { [long]$_ })
  for($i=0; $i -lt 4; $i++) {
    if($a[$i] -lt $b[$i]) { return -1 }
    if($a[$i] -gt $b[$i]) { return 1 }
  }
  return 0
}

function Restore-Backup([string]$backup, [string]$destination,
                        [string]$newFilesPath) {
  if (!(Test-Path -LiteralPath (Join-Path $backup 'data\app.so'))) {
    throw 'Backup missing or incomplete'
  }
  Copy-Contents $backup $destination
  if (Test-Path -LiteralPath $newFilesPath) {
    $prefix = [IO.Path]::GetFullPath($destination).TrimEnd('\') + '\'
    foreach ($relative in [IO.File]::ReadAllLines($newFilesPath)) {
      if ([string]::IsNullOrWhiteSpace($relative) -or
          [IO.Path]::IsPathRooted($relative) -or
          $relative.Split('\') -contains '..') { continue }
      $file = [IO.Path]::GetFullPath((Join-Path $destination $relative))
      if ($file.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
      }
    }
  }
}

function Report-Failure([string]$badVersion) {
  $body = @{
    schema = 1
    failedVersion = $badVersion
    time = [DateTime]::UtcNow.ToString('o')
  } | ConvertTo-Json -Depth 5 -Compress
  $queue = Join-Path $root ('failure-' + $badVersion.Replace('+', '_') + '.json')
  [IO.File]::WriteAllText($queue, $body, (New-Object Text.UTF8Encoding($false)))
  Write-Log 'Failure report retained locally'
}

function Perform-Rollback {
  $candidate = Read-State
  $badVersion = [string]$candidate.Version
  $backup = [string]$candidate.BackupDir
  $target = Assert-AppDir ([string]$candidate.AppDir)
  $backupPrefix = [IO.Path]::GetFullPath((Join-Path $root 'Backups')).TrimEnd('\') + '\'
  if ($badVersion -notmatch '^\d+\.\d+\.\d+\+\d+$' -or
      !$backup -or
      ![IO.Path]::GetFullPath($backup).StartsWith(
        $backupPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Invalid rollback state'
  }
  Wait-ForAppIdle $target
  Suspend-AppCrashMonitor $target
  Restore-Backup $backup $target (Join-Path $root 'new-files.txt')
  Add-Content -LiteralPath $skippedPath -Value $badVersion -Encoding ascii
  Remove-Item -LiteralPath $statePath, $markerPath, $healthyPath -Force -ErrorAction SilentlyContinue
  Write-Status 'failed' $badVersion 0 '新版连续三次启动失败，已恢复旧版'
  Write-Log ('Rolled back ' + $badVersion)
  Report-Failure $badVersion
}

$monitoring = $Mode -eq 'Monitor'
if($Mode -eq 'Update') {
  Write-Log ('Worker started for ' + $Version + '; PID=' + $PID + '; run=' + $RunId)
  Write-Status 'starting' $Version 0 '更新助手已启动，正在准备下载'
}
if ($monitoring) { Wait-ForExit $CurrentPid }
$mutex = New-Object Threading.Mutex($false, 'Local\BobTVUpdater')
$locked = $false
try {
  $locked = $mutex.WaitOne(0)
  if (!$locked) {
    if($Mode -eq 'Update') {
      Write-Status 'failed' $Version 0 '已有更新任务正在运行，请等待完成后再重试'
    }
    return
  }

  if ($Mode -eq 'Rollback') {
    Wait-ForExit $CurrentPid
    Perform-Rollback
    return
  }

  if ($Mode -eq 'Monitor') {
    $candidate = Read-State
    if (!$candidate.Version) { return }
    if (Test-Path -LiteralPath $healthyPath) {
      Set-Attempts 0
      Remove-Item -LiteralPath $healthyPath, $markerPath -Force -ErrorAction SilentlyContinue
      return
    }
    if (!(Test-Path -LiteralPath $markerPath)) { return }
    $markerPid = [IO.File]::ReadAllText($markerPath).Trim()
    if ($markerPid -ne [string]$CurrentPid) { return }
    $attempts = [int]$candidate.Attempts + 1
    Set-Attempts $attempts
    Remove-Item -LiteralPath $markerPath -Force
    Write-Log ('Startup failed for ' + $candidate.Version +
               '; consecutive failures=' + $attempts)
    if ($attempts -ge 3) { Perform-Rollback }
    return
  }

  if ($Mode -ne 'Update') { throw 'Invalid worker mode' }
  $AppDir = Assert-AppDir $AppDir
  if (!(Test-Path -LiteralPath (Join-Path $AppDir 'data\app.so'))) {
    throw 'Installed app data missing'
  }
  if ($Version -notmatch '^\d+\.\d+\.\d+\+\d+$' -or
      $Sha256 -notmatch '^[a-fA-F0-9]{64}$' -or
      $Bytes -lt 1000000 -or $Bytes -gt 2000000000) {
    throw 'Invalid update metadata'
  }
  $uri = [Uri]$ArchiveUrl
  if ($uri.Scheme -ne 'https' -or
      $uri.Host -ne 'bobtv.briconbric.com' -or
      !$uri.AbsolutePath.StartsWith('/updates/') -or
      !$uri.AbsolutePath.EndsWith('.zip') -or
      $uri.Query -ne '' -or $uri.Fragment -ne '') {
    throw 'Invalid archive URL'
  }
  if (Test-Path -LiteralPath $skippedPath) {
    if ([IO.File]::ReadAllLines($skippedPath) -contains $Version) { return }
  }
  if ((Test-Path -LiteralPath $statePath) -and
      (Test-Path -LiteralPath $markerPath)) {
    Write-Log 'Waiting for previous update startup acknowledgement'
    Write-Status 'waiting' $Version 0 '等待当前版本完成启动检查'
    for($attempt=0; $attempt -lt 120 -and
        (Test-Path -LiteralPath $markerPath); $attempt++) {
      Start-Sleep -Seconds 1
    }
    if(Test-Path -LiteralPath $markerPath) {
      Write-Status 'failed' $Version 0 '当前版本启动检查未完成，稍后重试'
      Write-Log 'Previous update startup acknowledgement timed out'
      return
    }
  }

  $archive = Join-Path $root ('BobTV-' + $Version.Replace('+', '_') + '.zip')
  $partial = $archive + '.part'
  Write-Status 'downloading' $Version 0 '正在下载更新'
  if (!(Test-Path -LiteralPath $archive) -or
      (Get-Item -LiteralPath $archive).Length -ne $Bytes -or
      (Get-Sha256 $archive) -ine $Sha256) {
    Add-Type -AssemblyName System.Net.Http
    $handler = New-Object Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false
    $http = New-Object Net.Http.HttpClient($handler)
    $http.Timeout = [TimeSpan]::FromSeconds(45)
    $http.DefaultRequestHeaders.UserAgent.ParseAdd('BobTV/0.9.1 updater')
    try {
      $response = $http.GetAsync(
        $uri, [Net.Http.HttpCompletionOption]::ResponseHeadersRead
      ).GetAwaiter().GetResult()
      if ([int]$response.StatusCode -ne 200) { throw 'Download failed' }
      $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
      $output = [IO.File]::Open(
        $partial, [IO.FileMode]::Create, [IO.FileAccess]::Write,
        [IO.FileShare]::None)
      try {
        $buffer = New-Object byte[] (1024 * 1024)
        [long]$received = 0
        $lastPercent = -1
        while ($true) {
          $read=$stream.ReadAsync($buffer,0,$buffer.Length)
          if(!$read.Wait(30000)){throw '下载连接连续 30 秒没有收到数据，请重试'}
          $count=$read.GetAwaiter().GetResult()
          if($count -le 0){break}
          $output.Write($buffer, 0, $count)
          $received += $count
          $script:receivedBytes = $received
          if ($received -gt $Bytes) { throw 'Downloaded file too large' }
          $percent = [int][Math]::Floor(100.0 * $received / $Bytes)
          if ($percent -ne $lastPercent) {
            Write-Status 'downloading' $Version $percent '正在下载更新'
            $lastPercent = $percent
          }
        }
      } finally {
        $output.Dispose()
        $stream.Dispose()
      }
    } finally {
      $http.Dispose()
      $handler.Dispose()
    }
    Write-Status 'verifying' $Version 100 '下载完成，正在校验文件大小与完整性'
    if ((Get-Item -LiteralPath $partial).Length -ne $Bytes -or
        (Get-Sha256 $partial) -ine $Sha256) {
      throw 'Download integrity check failed'
    }
    Move-Item -LiteralPath $partial -Destination $archive -Force
  }

  Write-Status 'verifying' $Version 100 '正在检查安装包内容与版本'

  $stage = Join-Path $root ('Stage\' + $Version.Replace('+', '_') + '-' +
                             [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $stage -Force | Out-Null
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip = [IO.Compression.ZipFile]::OpenRead($archive)
  try {
    if ($zip.Entries.Count -gt 5000) { throw 'Too many archive entries' }
    [long]$expandedBytes = 0
    foreach ($entry in $zip.Entries) {
      $expandedBytes += $entry.Length
      if ($expandedBytes -gt 2000000000) {
        throw 'Expanded update package too large'
      }
      $relative = $entry.FullName.Replace('\', '/')
      if (!$relative.StartsWith('BobTV/') -or
          $relative.Split('/') -contains '..' -or
          $relative.Contains(':') -or $relative.Length -gt 300) {
        throw 'Unsafe archive entry'
      }
      $target = [IO.Path]::GetFullPath((Join-Path $stage $relative.Replace('/', '\')))
      $prefix = [IO.Path]::GetFullPath($stage).TrimEnd('\') + '\'
      if (!$target.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Archive path escaped stage'
      }
      if ($relative.EndsWith('/')) {
        New-Item -ItemType Directory -Path $target -Force | Out-Null
      } else {
        New-Item -ItemType Directory -Path (Split-Path $target) -Force | Out-Null
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $false)
      }
    }
  } finally {
    $zip.Dispose()
  }
  $bundle = Join-Path $stage 'BobTV'
  if ((Get-Item (Join-Path $bundle 'BobTV.exe')).VersionInfo.FileVersion -ne $Version -or
      !(Test-Path -LiteralPath (Join-Path $bundle 'data\app.so'))) {
    throw 'Package version or app data mismatch'
  }
  Write-Status 'ready' $Version 100 '更新已下载并校验通过，关闭 BobTV 后自动安装'
  Wait-ForExit $CurrentPid
  Wait-ForAppIdle $AppDir
  Suspend-AppCrashMonitor $AppDir
  $exe = @('clubtivi.exe', 'BobTV.exe') |
    Where-Object { Test-Path -LiteralPath (Join-Path $AppDir $_) } |
    Select-Object -First 1
  if (!$exe) { throw 'Installed executable missing' }
  $installedVersion=(Get-Item (Join-Path $AppDir $exe)).VersionInfo.FileVersion
  if($installedVersion -match '^\d+\.\d+\.\d+\+\d+$' -and
     (Compare-BobVersion $installedVersion $Version) -ge 0) {
    Write-Log ('No install needed: already at ' + $installedVersion)
    return
  }
  $backup = Join-Path $root ('Backups\' + $Version.Replace('+', '_') + '-' +
                             [DateTime]::UtcNow.ToString('yyyyMMddHHmmss') + '-' +
                             [guid]::NewGuid().ToString('N'))
  Write-Status 'backingUp' $Version 0 '正在备份旧版，完成后开始安装'
  Copy-Contents $AppDir $backup
  if ((Get-Sha256 (Join-Path $AppDir 'data\app.so')) -ne
      (Get-Sha256 (Join-Path $backup 'data\app.so'))) {
    throw 'Backup verification failed'
  }
  Write-Status 'installing' $Version 0 '正在安装更新'
  $newFileList = Join-Path $root 'new-files.txt'
  $files = @(Get-ChildItem -LiteralPath $bundle -Recurse -File -Force)
  $newFiles = @($files | ForEach-Object {
    $relative = $_.FullName.Substring($bundle.Length).TrimStart('\')
    if ($relative -ine 'BobTV.exe' -and
        !(Test-Path -LiteralPath (Join-Path $AppDir $relative))) {
      $relative
    }
  })
  [IO.File]::WriteAllLines($newFileList, [string[]]$newFiles)
  $newline = [Environment]::NewLine
  $state = '[Update]' + $newline + 'Version=' + $Version + $newline +
           'AppDir=' + $AppDir + $newline + 'BackupDir=' + $backup +
           $newline + 'Attempts=0' + $newline
  [IO.File]::WriteAllText($statePath, $state, (New-Object Text.UTF8Encoding($false)))
  try {
    $installedFiles=0
    foreach ($file in $files) {
      $relative = $file.FullName.Substring($bundle.Length).TrimStart('\')
      if ($relative -ieq 'BobTV.exe') { continue }
      $destination = Join-Path $AppDir $relative
      Copy-AppFile $file.FullName $destination
      $installedFiles++
      Write-Status 'installing' $Version ([int](100*$installedFiles/$files.Count)) '正在安装更新，请稍候'
    }
    Copy-AppFile (Join-Path $bundle 'BobTV.exe') (Join-Path $AppDir $exe)
    if ((Get-Item (Join-Path $AppDir $exe)).VersionInfo.FileVersion -ne $Version) {
      throw 'Installed executable version mismatch'
    }
  } catch {
    $installError=$_
    try { Restore-Backup $backup $AppDir $newFileList }
    catch { throw ('Installation failed: '+$installError.Exception.Message+'; rollback failed: '+$_.Exception.Message+'; backup retained at '+$backup) }
    Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
    throw $installError
  }
  if (!$TestRoot) {
    $shortcutScript = Join-Path $root 'ensure_shortcut.ps1'
    if (Test-Path -LiteralPath $shortcutScript) {
      try {
        & $shortcutScript -ExecutablePath (Join-Path $AppDir $exe)
      } catch {
        Write-Log ('Desktop shortcut check failed: ' + $_.Exception.Message)
      }
    }
  }
  Write-Status 'installed' $Version 100 '安装完成，旧版已备份，下次启动即为新版本'
  Write-Log ('Installed ' + $Version)
  try { Remove-Item -LiteralPath $stage -Recurse -Force }
  catch { Write-Log ('Stage cleanup deferred: ' + $_.Exception.Message) }
} catch {
  Write-Log $_.Exception.ToString()
  if ($Version -match '^\d+\.\d+\.\d+\+\d+$') {
    Write-Status 'failed' $Version 0 ('更新未完成：' + $_.Exception.Message + '。详细记录见 worker.log 和 launcher.log。')
  }
} finally {
  try { Resume-AppCrashMonitor $AppDir }
  catch { Write-Log ('Crash monitor restart deferred: '+$_.Exception.Message) }
  if ($locked) { $mutex.ReleaseMutex() }
  $mutex.Dispose()
}
