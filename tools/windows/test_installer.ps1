param([Parameter(Mandatory=$true)][string]$BundleDirectory,
      [Parameter(Mandatory=$true)][string]$CompilerPath)
$ErrorActionPreference='Stop'
$fixture=Join-Path $env:TEMP ('BobTVInstallerTests-'+[guid]::NewGuid().ToString('N'))
$app=Join-Path $fixture '安装 日本語\BoB\BoBTV'
$desktop=Join-Path $fixture 'Desktop'
$programs=Join-Path $fixture 'Programs'
foreach($directory in @($fixture,$desktop,$programs)){New-Item -ItemType Directory -Path $directory -Force|Out-Null}
$id='{'+[guid]::NewGuid().ToString()+'}'
$bundle=(Get-Item -LiteralPath $BundleDirectory).FullName
$version=(Get-Item -LiteralPath "$bundle\BobTV.exe").VersionInfo.FileVersion
& $CompilerPath "/DBundleDirectory=$bundle" "/DOutputDirectory=$fixture" "/DAppVersion=$version" "/DInstallerAppId=$id" "/DDesktopRoot=$desktop" "/DProgramsRoot=$programs" '/DOutputName=BobTV-Setup-fixture' (Join-Path $PSScriptRoot 'installer\BobTV.iss')
if($LASTEXITCODE -ne 0){throw 'Fixture compilation failed'}
$setup=Join-Path $fixture 'BobTV-Setup-fixture.exe'
foreach($selected in @($false,$true)) {
 $tasks=if($selected){'desktopicon'}else{''}
 $process=Start-Process -FilePath $setup -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',('/DIR="'+$app+'"'),('/TASKS="'+$tasks+'"'),('/LOG="'+$fixture+'\install-'+$selected+'.log"')) -Wait -PassThru
 if($process.ExitCode -ne 0){throw "Fixture installation failed: $($process.ExitCode)"}
 if((Get-Item -LiteralPath "$app\BobTV.exe").VersionInfo.FileVersion -ne $version){throw 'Installed version mismatch'}
 $choice=if($selected){'1'}else{'0'}
 if([IO.File]::ReadAllText("$app\installation.ini") -notmatch "DesktopShortcut=$choice"){throw 'Desktop preference not persisted'}
 if((Test-Path -LiteralPath "$desktop\BobTV.lnk") -ne $selected){throw 'Desktop shortcut task ignored'}
 if(!(Test-Path -LiteralPath "$programs\BoB\BobTV\BobTV.lnk")){throw 'Start menu shortcut missing'}
 $linksBefore=@(Get-ChildItem ([Environment]::GetFolderPath('DesktopDirectory')) -Filter '*.lnk'|ForEach-Object {$_.FullName})
 & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$app\data\flutter_assets\assets\updater\ensure_shortcut.ps1" -ExecutablePath "$app\BobTV.exe"
 if($LASTEXITCODE -ne 0){throw 'Managed shortcut policy failed'}
 $linksAfter=@(Get-ChildItem ([Environment]::GetFolderPath('DesktopDirectory')) -Filter '*.lnk'|ForEach-Object {$_.FullName})
 if(($linksBefore -join "`n") -ne ($linksAfter -join "`n")){throw 'Application overrode installer desktop preference'}
 $uninstaller=Get-ChildItem -LiteralPath $app -Filter 'unins*.exe'|Select-Object -First 1
 $uninstall=Start-Process -FilePath $uninstaller.FullName -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART') -Wait -PassThru
 if($uninstall.ExitCode -ne 0){throw 'Fixture uninstall failed'}
 if(Test-Path -LiteralPath "$app\BobTV.exe"){throw 'Uninstall left executable behind'}
 if(Test-Path -LiteralPath "$desktop\BobTV.lnk"){throw 'Uninstall left desktop shortcut behind'}
 Write-Output "PASS: installer Unicode path, desktop=$selected, start menu, launch shortcut policy, uninstall"
}
Write-Output ('Fixture retained: '+$fixture)
