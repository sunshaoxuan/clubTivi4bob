$ErrorActionPreference='Stop'
$source=Join-Path $PSScriptRoot '../../assets/updater/worker.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
$node=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Remove-ObsoleteBackups'},$true)
if(!$node){throw 'Backup retention helper missing'}
. ([scriptblock]::Create($node.Extent.Text))
function Write-Log {param($message)}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('BobTVBackupRetention-'+[guid]::NewGuid().ToString('N'))
$root=Join-Path $fixture 'Update'
$candidateFile=Join-Path $root 'candidate.ini'
function New-Backup([string]$name){
  $path=Join-Path $root ('Backups/'+$name)
  New-Item -ItemType Directory -Path (Join-Path $path 'data') -Force|Out-Null
  [IO.File]::WriteAllText((Join-Path $path 'data/app.so'),$name)
  return $path
}
function Set-BackupRecord([string]$path){[IO.File]::WriteAllText($candidateFile,"[Update]`nBackupDir=$path`n")}
try {
  $first=New-Backup 'first'
  $second=New-Backup 'second'
  $latest=New-Backup 'latest'
  Set-BackupRecord $second
  Remove-ObsoleteBackups $latest $candidateFile
  if(!(Test-Path $first) -or !(Test-Path $second)){throw 'Unpublished backup removed recovery history'}
  Set-BackupRecord $latest
  Remove-Item -LiteralPath (Join-Path $latest 'data/app.so')
  Remove-ObsoleteBackups $latest $candidateFile
  if(!(Test-Path $first) -or !(Test-Path $second)){throw 'Incomplete backup removed recovery history'}
  [IO.File]::WriteAllText((Join-Path $latest 'data/app.so'),'latest')
  Remove-ObsoleteBackups $latest $candidateFile
  if((Test-Path $first) -or (Test-Path $second) -or
      [IO.File]::ReadAllText((Join-Path $latest 'data/app.so')) -ne 'latest'){throw 'Successful rotation did not keep exactly the current backup'}
  Remove-ObsoleteBackups $latest $candidateFile
  if(!(Test-Path $latest)){throw 'Repeated cleanup deleted the retained backup'}
  $next=New-Backup 'next'
  Set-BackupRecord $next
  Remove-ObsoleteBackups $next $candidateFile
  if((Test-Path $latest) -or !(Test-Path $next)){throw 'Subsequent update accumulated older backups'}
  $external=Join-Path $fixture 'external'
  New-Item -ItemType Directory -Path (Join-Path $external 'data') -Force|Out-Null
  [IO.File]::WriteAllText((Join-Path $external 'data/app.so'),'external')
  Set-BackupRecord $external
  Remove-ObsoleteBackups $external $candidateFile
  if(!(Test-Path $next)){throw 'External backup pointer removed local recovery files'}
  $link=Join-Path $root 'Backups/linked'
  $kind=if($env:OS -eq 'Windows_NT'){'Junction'}else{'SymbolicLink'}
  New-Item -ItemType $kind -Path $link -Target $external|Out-Null
  $old=New-Backup 'with-nested-link'
  New-Item -ItemType $kind -Path (Join-Path $old 'nested-link') -Target $external|Out-Null
  Set-BackupRecord $next
  Remove-ObsoleteBackups $next $candidateFile
  if(!(Test-Path $link) -or [IO.File]::ReadAllText((Join-Path $external 'data/app.so')) -ne 'external'){throw 'Cleanup followed or removed a directory link'}
  if(Test-Path $old){throw 'Obsolete backup containing a link was not removed'}
  Set-BackupRecord $link
  Remove-ObsoleteBackups $link $candidateFile
  if(!(Test-Path $next)){throw 'Linked retained backup removed real backups'}
  # Remove the link itself before fixture disposal on Windows PowerShell 5.1.
  [IO.Directory]::Delete($link)
  Write-Output 'PASS: repeated upgrades retain one verified rollback backup; unpublished, incomplete, external and linked backups preserve recovery files.'
} finally {Remove-Item -LiteralPath $fixture -Recurse -Force}
