$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'pe_architecture.ps1')
$root=(Get-Item -LiteralPath (Join-Path $PSScriptRoot '../..')).FullName
foreach($relative in @('tools/windows/build_arm64.ps1','tools/windows/build_installer.ps1',
  'tools/windows/pe_architecture.ps1','assets/updater/worker.ps1')) {
  $tokens=$null;$errors=$null
  $source=[IO.File]::ReadAllText((Join-Path $root $relative),[Text.Encoding]::UTF8)
  $null=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
  if($errors.Count){throw "PowerShell parse failed: $relative"}
}
$tokens=$null;$errors=$null
$source=[IO.File]::ReadAllText((Join-Path $root 'assets/updater/worker.ps1'),[Text.Encoding]::UTF8)
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
$function=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-UpdateMachine'},$true)
if(!$function){throw 'Worker PE validation function missing'}
Invoke-Expression $function.Extent.Text
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('BobTV-PE-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture|Out-Null
function Make-PE([string]$Path,[uint16]$Machine) {
  $bytes=New-Object byte[] 256
  $bytes[0]=0x4d;$bytes[1]=0x5a
  [BitConverter]::GetBytes([uint32]128).CopyTo($bytes,60)
  $bytes[128]=0x50;$bytes[129]=0x45
  [BitConverter]::GetBytes($Machine).CopyTo($bytes,132)
  [IO.File]::WriteAllBytes($Path,$bytes)
}
function Must-Throw([scriptblock]$Action) {
  $threw=$false
  try{& $Action|Out-Null}catch{$threw=$true}
  if(!$threw){throw 'Expected architecture rejection'}
}
try {
  $exe=Join-Path $fixture 'BobTV.exe';$dll=Join-Path $fixture 'flutter_windows.dll'
  Make-PE $exe 0xAA64;Make-PE $dll 0xAA64
  if((Get-BobTvPEMachine $exe) -ne 0xAA64 -or (Get-UpdateMachine $exe) -ne 0xAA64){throw 'ARM64 detection failed'}
  Assert-BobTvBundleArchitecture $fixture 'arm64'
  Must-Throw {Assert-BobTvBundleArchitecture $fixture 'x64'}
  Make-PE $dll 0x8664
  Must-Throw {Assert-BobTvBundleArchitecture $fixture 'arm64'}
  Make-PE $exe 0x8664
  Assert-BobTvBundleArchitecture $fixture 'x64'
  if((Get-UpdateMachine $exe) -ne 0x8664){throw 'Worker x64 detection failed'}
  Make-PE $exe 0x14c
  Must-Throw {Get-BobTvPEMachine $exe}
  Must-Throw {Get-UpdateMachine $exe}
  [IO.File]::WriteAllBytes($exe,(New-Object byte[] 20))
  Must-Throw {Get-BobTvPEMachine $exe}
  Must-Throw {Get-UpdateMachine $exe}
  Write-Host 'PASS: PowerShell syntax, ARM64/x64 selection, mixed DLL rejection and malformed PE rejection'
} finally {
  # This exact fixture directory was created above and contains no user data.
  Remove-Item -LiteralPath $fixture -Recurse -Force
}
