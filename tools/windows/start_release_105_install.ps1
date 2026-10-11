$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$script='C:\Users\sunsx\src\BobTV-Release105-install.ps1'
Invoke-WebRequest -UseBasicParsing 'http://100.65.248.58:8768/install.ps1' -OutFile $script
if((Get-FileHash $script).Hash.ToLower() -ne 'c3b1106576448c2244f072da9feafe258a3232c9caa15aad9a828cfd0ee7a798'){throw 'Installation script mismatch'}
& ([scriptblock]::Create([IO.File]::ReadAllText($script)))
