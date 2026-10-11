$ErrorActionPreference='Stop'
$script='C:\Users\sunsx\src\BobTV-Release105-build.ps1'
if(Test-Path -LiteralPath $script){throw 'Preserve earlier build launcher'}
Invoke-WebRequest -UseBasicParsing 'http://100.65.248.58:8768/build.ps1' -OutFile $script
if((Get-FileHash -LiteralPath $script).Hash.ToLower() -ne '6de0840d7495afb8d2f3c51865735f6c5d86b2eec44ee6c64762cea12eb71d65'){throw 'Build script checksum mismatch'}
& ([scriptblock]::Create([IO.File]::ReadAllText($script)))
