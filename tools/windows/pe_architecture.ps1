function Get-BobTvPEMachine([string]$Path) {
  $stream=[IO.File]::OpenRead($Path)
  $reader=New-Object IO.BinaryReader($stream)
  try {
    if($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5A4D){throw 'Invalid PE DOS header'}
    $stream.Position=0x3c
    $offset=$reader.ReadUInt32()
    if($offset -lt 64 -or $offset -gt 1048576 -or $offset+6 -gt $stream.Length){throw 'Invalid PE offset'}
    $stream.Position=$offset
    if($reader.ReadUInt32() -ne 0x4550){throw 'Invalid PE signature'}
    $machine=$reader.ReadUInt16()
    if($machine -notin @(0x8664,0xAA64)){throw 'Unsupported application architecture'}
    return $machine
  } finally {$reader.Dispose();$stream.Dispose()}
}

function Assert-BobTvBundleArchitecture([string]$BundleDirectory,[string]$Architecture) {
  $expected=if($Architecture -eq 'arm64'){0xAA64}else{0x8664}
  foreach($file in Get-ChildItem -LiteralPath $BundleDirectory -File|Where-Object {$_.Extension -eq '.dll' -or $_.Name -eq 'BobTV.exe'}) {
    if((Get-BobTvPEMachine $file.FullName) -ne $expected){throw "Wrong architecture in app process: $($file.Name)"}
  }
}

function Assert-BobTvAotArchitecture([string]$Path,[string]$Architecture) {
  $stream=[IO.File]::OpenRead($Path)
  $reader=New-Object IO.BinaryReader($stream)
  try {
    if($stream.Length -lt 64 -or $reader.ReadUInt32() -ne 0x464C457F){throw 'Invalid AOT ELF header'}
    if($reader.ReadByte() -ne 2 -or $reader.ReadByte() -ne 1){throw 'AOT must be a 64-bit little-endian ELF'}
    $stream.Position=18
    $machine=$reader.ReadUInt16()
    $expected=if($Architecture -eq 'arm64'){183}else{62}
    if($machine -ne $expected){throw 'AOT architecture does not match the application'}
  } finally {$reader.Dispose();$stream.Dispose()}
}
