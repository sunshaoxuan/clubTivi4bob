$ErrorActionPreference='Stop'
Set-ExecutionPolicy -Scope Process Bypass -Force
$source='C:\Users\sunsx\src\BobTV-Release105-source'
$output='C:\Users\sunsx\src\BobTV-Release105'
$baseline='C:\Users\sunsx\src\BobTV-Test84\BobTV'
if(Test-Path -LiteralPath $source){throw 'Preserve existing source staging'}
if(Test-Path -LiteralPath $output){throw 'Preserve existing release staging'}
New-Item -ItemType Directory -Path $source,$output | Out-Null
$archive=Join-Path $output 'source.tar.gz'
Invoke-WebRequest -UseBasicParsing 'http://100.65.248.58:8768/windows-source.tar.gz' -OutFile $archive
if((Get-FileHash -LiteralPath $archive).Hash.ToLower() -ne 'c588cffea0fe80eb6f14254d5f0b95ad43d47c8a500506eb9680604baea80521'){throw 'Source archive checksum mismatch'}
& tar.exe -xzf $archive -C $source
if($LASTEXITCODE -ne 0){throw 'Source extraction failed'}
$env:Path='C:\Users\sunsx\src\flutter\bin;C:\Users\sunsx\src\B84\build\airplay-venv\Scripts;'+$env:Path
Set-Location $source
$fpsap=Join-Path $source 'build\fpsap-dist'
New-Item -ItemType Directory -Path $fpsap -Force | Out-Null
foreach($name in @('fpsap-auth.exe','fpsap-upstream-source.zip','fpsap_auth.go','build-fpsap.ps1','FPSAP-LICENSE','FPSAP-COPYING.GPL-3.0','FPSAP-LICENSE.BlueOak-1.0.0','FPSAP-NOTICE.md')) {
  Copy-Item -LiteralPath (Join-Path $baseline ('AirPlay\'+$name)) -Destination $fpsap
}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\airplay\build.ps1
if($LASTEXITCODE -ne 0){throw 'Sender helper build failed'}
flutter pub get --offline
if($LASTEXITCODE -ne 0){throw 'Dependencies failed'}
flutter build windows --release --no-pub
if($LASTEXITCODE -ne 0){throw 'Windows build failed'}
$release=Join-Path $source 'build\windows\x64\runner\Release'
if((Get-Item (Join-Path $release 'clubtivi.exe')).VersionInfo.FileVersion -ne '1.0.5+90'){throw 'Version mismatch'}
$bundle=Join-Path $output 'BobTV'
New-Item -ItemType Directory -Path $bundle | Out-Null
Copy-Item -Path (Join-Path $release '*') -Destination $bundle -Recurse
Rename-Item -LiteralPath (Join-Path $bundle 'clubtivi.exe') -NewName BobTV.exe
if(Test-Path -LiteralPath (Join-Path $bundle 'AirPlay')) { Remove-Item -LiteralPath (Join-Path $bundle 'AirPlay') -Recurse }
Copy-Item -LiteralPath (Join-Path $source 'build\airplay-dist\bobtv-airplay') -Destination (Join-Path $bundle 'AirPlay') -Recurse
foreach($name in @('Tools','BobTV.ico','vc-runtime-manifest.json','VC-RUNTIME-NOTICE.txt')){Copy-Item -LiteralPath (Join-Path $baseline $name) -Destination $bundle -Recurse}
Get-ChildItem $baseline -File | Where-Object {$_.Name -match '^(concrt|msvcp|vccorlib|vcruntime)140.*\.dll$'} | ForEach-Object {
  if((Get-AuthenticodeSignature $_.FullName).Status -ne 'Valid'){throw 'Invalid VC runtime signature'}
  Copy-Item -LiteralPath $_.FullName -Destination $bundle
}
& tools\windows\build_installer.ps1 -BundleDirectory $bundle -OutputDirectory $output -CompilerPath 'C:\Users\sunsx\src\BobTV-Installer80\InnoSetup\ISCC.exe'
& tools\windows\test_installer.ps1 -BundleDirectory $bundle -CompilerPath 'C:\Users\sunsx\src\BobTV-Installer80\InnoSetup\ISCC.exe'
Compress-Archive -LiteralPath $bundle -DestinationPath (Join-Path $output 'BobTV-1.0.5+90-windows-x64.zip') -CompressionLevel Optimal
foreach($file in Get-ChildItem $output -File | Where-Object {$_.Extension -in '.exe','.zip'}) {
  Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256
  & 'C:\Program Files\Tailscale\tailscale.exe' file cp $file.FullName '100.65.248.58:'
  if($LASTEXITCODE -ne 0){throw 'Package transfer failed'}
}
[IO.File]::WriteAllText((Join-Path $output 'build-success.txt'),'PASS: Windows 1.0.5+90, sender helper, installer fixtures and package transfer')
