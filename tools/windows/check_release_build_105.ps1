$ErrorActionPreference='Stop'
Get-CimInstance Win32_Process | Where-Object {$_.ProcessId -in @(9744,22864,12844,15584,18024,19820)} | Select-Object ProcessId,ParentProcessId,CommandLine | Format-List
$build='C:\Users\sunsx\src\BobTV-Release105-source\build\windows\x64'
Get-ChildItem -LiteralPath $build -File -Recurse -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 10 FullName,Length,LastWriteTime | Format-List
Get-NetTCPConnection -ErrorAction SilentlyContinue | Where-Object {$_.OwningProcess -in @(9744,22864,12844)} | Select-Object OwningProcess,RemoteAddress,RemotePort,State
Get-Process gen_snapshot,dart,cl,link -ErrorAction SilentlyContinue | Select-Object Id,ProcessName,CPU,WorkingSet64
