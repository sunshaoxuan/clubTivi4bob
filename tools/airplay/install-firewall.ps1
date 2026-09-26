param([Parameter(Mandatory=$true)][string]$ApplicationDirectory)
$ErrorActionPreference = 'Stop'
$program = Join-Path (Resolve-Path $ApplicationDirectory).Path 'AirPlay\bobtv-airplay.exe'
if (-not (Test-Path -LiteralPath $program)) { throw 'AirPlay helper is missing' }
foreach ($protocol in @('TCP','UDP')) {
  $name = "BobTV AirPlay $protocol"
  $rule = Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue
  if ($rule) { $rule | Remove-NetFirewallRule }
  New-NetFirewallRule -DisplayName $name -Direction Inbound -Action Allow -Program $program -Protocol $protocol -RemoteAddress LocalSubnet -Profile Any | Out-Null
}
