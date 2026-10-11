$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
foreach($id in @(18960,25792,28688)) {
 $p=Get-CimInstance Win32_Process -Filter "ProcessId=$id"
 if(!$p){continue}
 $line=[string]$p.CommandLine
 if($line -match '-encodedcommand\s+(\S+)'){$line=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($matches[1]))}
 $markers=@('BobTV-window-qa-20261012','BobTV-Release105','fullscreen_qa','build_fullscreen','winrm','BobTV') | Where-Object {$line.Contains($_)}
 @{pid=$id;parent=$p.ParentProcessId;markers=$markers;scriptFiles=@([regex]::Matches($line,'[A-Za-z0-9_./\\:-]+\.ps1') | ForEach-Object {$_.Value})}|ConvertTo-Json -Compress
}
