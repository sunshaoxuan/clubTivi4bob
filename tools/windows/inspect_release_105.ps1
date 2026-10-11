$ErrorActionPreference='Stop'
Get-Process BobTV,clubtivi,flutter,dart,cmake,ninja,MSBuild,python,pyinstaller -ErrorAction SilentlyContinue | Select-Object Id,ProcessName,CPU,Path | Format-List
Get-ChildItem 'C:\Users\sunsx\src\BobTV-Release105' -ErrorAction SilentlyContinue | Select-Object Name,Length,LastWriteTime | Format-List
$keys=@('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')
Get-ItemProperty $keys -ErrorAction SilentlyContinue | Where-Object {$_.DisplayName -like '*BobTV*'} | Select-Object DisplayName,DisplayVersion,InstallLocation,UninstallString | Format-List
$shell=New-Object -ComObject WScript.Shell
foreach($desktop in @([Environment]::GetFolderPath('Desktop'),'C:\Users\Public\Desktop')) {
  Get-ChildItem -LiteralPath $desktop -Filter '*.lnk' -ErrorAction SilentlyContinue | ForEach-Object {
    $shortcut=$shell.CreateShortcut($_.FullName)
    if($shortcut.TargetPath -match 'BobTV|clubtivi|HotelTV') {[PSCustomObject]@{Shortcut=$_.FullName;Target=$shortcut.TargetPath;Arguments=$shortcut.Arguments} | Format-List}
  }
}
foreach($candidate in @('C:\Program Files\BoB\BoBTV\BobTV.exe','C:\Users\sunsx\Apps\HotelTV\clubtivi.exe','C:\Users\sunsx\AppData\Local\BobTV\BobTV.exe','C:\Users\sunsx\AppData\Local\HotelTV\BobTV.exe','C:\Users\sunsx\Desktop\BobTV.lnk')) {
  if(Test-Path -LiteralPath $candidate){Get-Item -LiteralPath $candidate | Select-Object FullName,@{n='Version';e={$_.VersionInfo.FileVersion}} | Format-List}
}
