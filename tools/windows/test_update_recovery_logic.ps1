# Pure logic checks runnable in PowerShell on macOS; no Windows UI or installer runs.
$ErrorActionPreference='Stop'
$source=Join-Path $PSScriptRoot '../../assets/updater/worker.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
foreach($name in @('Invoke-UpdateDownload','Compare-BobVersion')){
  $node=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
  if(!$node){throw "Missing helper $name"}
  . ([scriptblock]::Create($node.Extent.Text))
}
function Write-Log {param($message)}
function Start-Sleep {param($Seconds)}
$script:attempts=0
Invoke-UpdateDownload { $script:attempts++;if($script:attempts -lt 3){throw 'Transient connection failure'} }
if($script:attempts -ne 3){throw 'Transient failure did not recover'}
$script:attempts=0;$failed=$false
try {Invoke-UpdateDownload {$script:attempts++;throw 'Persistent failure'}}catch{$failed=$true}
if(!$failed -or $script:attempts -ne 3){throw 'Persistent failure was hidden or retried without bound'}
$script:attempts=0
Invoke-UpdateDownload {$script:attempts++}
if($script:attempts -ne 1){throw 'Successful transfer repeated'}
$branch=$ast.Find({param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text.StartsWith('if($installedVersion -match')},$true)
if(!$branch){throw 'No-op install branch missing'}
function Test-Path {param($LiteralPath) return $script:appDataExists}
function Write-Status {param($phase,$version,$percent,$message) $script:receipt=$phase}
$AppDir='/tmp/bobtv-fixture';$Version='1.1.14+109'
foreach($case in @(@('1.1.14+109',$true,$true),@('1.1.14+109',$false,$false),@('1.1.15+110',$true,$false))){
  $installedVersion=$case[0];$script:appDataExists=$case[1];$script:receipt=$null;$failed=$false
  try {& ([scriptblock]::Create($branch.Extent.Text))}catch{$failed=$true}
  if($case[2]){if($failed -or $script:receipt -ne 'installed'){throw 'Verified no-op did not finish'}}
  elseif(!$failed -or $script:receipt){throw 'Unverified install reported success'}
}
Write-Output 'PASS: transient download recovers; persistent failure stops after 3; success runs once; exact installed no-op publishes completion; missing data/newer version rejected.'
