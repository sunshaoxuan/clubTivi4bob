$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$app='C:\Users\sunsx\Apps\HotelTV'
$bundle='C:\Users\sunsx\src\BobTV-Release105\BobTV'
$source='C:\Users\sunsx\src\BobTV-Release105-source'
$update='C:\Users\sunsx\AppData\Local\HotelTV\Update'
$root=$update
if(!(Test-Path 'C:\Users\sunsx\src\BobTV-Release105\build-success.txt')){throw 'Build validation is incomplete'}
if((Get-Item "$bundle\BobTV.exe").VersionInfo.FileVersion -ne '1.0.5+90'){throw 'Bundle version mismatch'}
if((Get-Item "$app\clubtivi.exe").VersionInfo.FileVersion -ne '1.0.4+89'){throw 'Installed version changed; recheck'}
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput([IO.File]::ReadAllText("$source\assets\updater\worker.ps1",[Text.Encoding]::UTF8),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Updater parser errors'}
$names=@('Suspend-AppCrashMonitor','Resume-AppCrashMonitor','Write-Log','Get-Sha256','Copy-AppFile','Copy-Contents')
foreach($f in $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){
 if($f.Name -in $names){. ([scriptblock]::Create($f.Extent.Text))}
}
$logPath="$update\manual105-install.log"
$stamp=[DateTime]::UtcNow.ToString('yyyyMMddHHmmss')
$backup="$update\Backups\manual105-$stamp"
if(Test-Path $backup){throw 'Preserve earlier backup'}
New-Item -ItemType Directory -Path $backup | Out-Null
$updatePrefix=[regex]::Escape($update+'\')
Get-CimInstance Win32_Process | Where-Object {
 $_.Name -eq 'powershell.exe' -and $_.CommandLine -match ($updatePrefix+'(worker|progress_ui)\.ps1["\s]')
} | ForEach-Object {Stop-Process -Id $_.ProcessId -Force}
$players=@(Get-Process clubtivi,BobTV -ErrorAction SilentlyContinue | Where-Object {$_.Path -eq "$app\clubtivi.exe"})
foreach($player in $players){[void]$player.CloseMainWindow()}
Start-Sleep -Seconds 3
foreach($player in $players){$live=Get-Process -Id $player.Id -ErrorAction SilentlyContinue;if($live -and $live.Path -eq "$app\clubtivi.exe"){Stop-Process -Id $live.Id -Force}}
if(Get-Process clubtivi,BobTV -ErrorAction SilentlyContinue | Where-Object {$_.Path -eq "$app\clubtivi.exe"}){throw 'Player still running'}
Suspend-AppCrashMonitor $app
$oldHash=(Get-FileHash "$app\data\app.so").Hash
Move-Item -LiteralPath $app -Destination "$backup\app"
if((Get-FileHash "$backup\app\data\app.so").Hash -ne $oldHash){throw 'Backup mismatch'}
foreach($name in @('candidate.ini','startup.marker','startup.healthy','status.json','new-files.txt')){
 if(Test-Path "$update\$name"){Move-Item -LiteralPath "$update\$name" -Destination "$backup\prior-$name"}
}
try {
 Copy-Item -LiteralPath $bundle -Destination $app -Recurse
 Rename-Item -LiteralPath "$app\BobTV.exe" -NewName 'clubtivi.exe'
 foreach($file in Get-ChildItem -LiteralPath $bundle -Recurse -File){
  $rel=$file.FullName.Substring($bundle.Length).TrimStart('\')
  if($rel -ieq 'BobTV.exe'){$rel='clubtivi.exe'}
  if((Get-FileHash (Join-Path $app $rel)).Hash -ne (Get-FileHash $file.FullName).Hash){throw "Installed file mismatch: $rel"}
 }
 [IO.File]::WriteAllText("$update\candidate.ini","[Update]`r`nVersion=1.0.5+90`r`nAppDir=$app`r`nBackupDir=$backup\app`r`nAttempts=0`r`n",[Text.UTF8Encoding]::new($false))
 $newFiles=@(Get-ChildItem $app -Recurse -File | ForEach-Object {$rel=$_.FullName.Substring($app.Length).TrimStart('\');if(!(Test-Path (Join-Path "$backup\app" $rel))){$rel}})
 [IO.File]::WriteAllLines("$update\new-files.txt",[string[]]$newFiles)
}catch {
 if(Test-Path $app){Move-Item -LiteralPath $app -Destination "$backup\failed-candidate"}
 Move-Item -LiteralPath "$backup\app" -Destination $app
 throw
}
Resume-AppCrashMonitor $app
Start-ScheduledTask 'BobTV-Local86-Test'
Start-ScheduledTask 'BobTV-CrashMonitor-Test86'
@{version='1.0.5+90';backup=$backup;userDataUntouched=$true;freshBundle=$true}|ConvertTo-Json -Compress
