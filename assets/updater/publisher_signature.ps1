# Verify the BobTV P-256 publisher signature with Windows CNG. This is payload
# authentication, independent of Authenticode/SmartScreen publisher reputation.
function Test-BobTvPublisherSignature([string]$Path,[string]$Signature,[string]$PublicKeyPath) {
  if($Signature -notmatch '^[A-Za-z0-9+/]{80,120}={0,2}$'){throw 'Invalid publisher signature'}
  $pem=[IO.File]::ReadAllText($PublicKeyPath)
  if($pem -notmatch '^\s*-----BEGIN PUBLIC KEY-----\s+([A-Za-z0-9+/=\s]+)-----END PUBLIC KEY-----\s*$'){throw 'Invalid publisher key'}
  $key=[Convert]::FromBase64String(($matches[1] -replace '\s',''))
  $prefix=[byte[]]@(0x30,0x59,0x30,0x13,0x06,0x07,0x2a,0x86,0x48,0xce,0x3d,0x02,0x01,0x06,0x08,0x2a,0x86,0x48,0xce,0x3d,0x03,0x01,0x07,0x03,0x42,0x00,0x04)
  if($key.Length -ne 91){throw 'Unsupported publisher key'}
  for($i=0;$i -lt $prefix.Length;$i++){if($key[$i] -ne $prefix[$i]){throw 'Unsupported publisher key'}}
  $blob=New-Object byte[] 72
  [Array]::Copy([Text.Encoding]::ASCII.GetBytes('ECS1'),0,$blob,0,4)
  $blob[4]=32
  [Array]::Copy($key,27,$blob,8,64)
  $der=[Convert]::FromBase64String($Signature)
  if($der.Length -lt 8 -or $der.Length -gt 72 -or $der[0] -ne 0x30 -or $der[1] -ne $der.Length-2){throw 'Invalid signature encoding'}
  $raw=New-Object byte[] 64
  $offset=2
  for($part=0;$part -lt 2;$part++){
    if($offset+2 -gt $der.Length){throw 'Truncated signature integer'}
    if($der[$offset++] -ne 2){throw 'Invalid signature integer'}
    $length=[int]$der[$offset++]
    if($length -lt 1 -or $length -gt 33 -or $offset+$length -gt $der.Length){throw 'Invalid signature length'}
    if($der[$offset] -ge 128){throw 'Negative signature integer'}
    if($length -eq 33){
      if($der[$offset] -ne 0 -or $der[$offset+1] -lt 128){throw 'Invalid signature padding'}
      $offset++;$length--
    }elseif($length -gt 1 -and $der[$offset] -eq 0 -and $der[$offset+1] -lt 128){throw 'Noncanonical signature padding'}
    [Array]::Copy($der,$offset,$raw,($part*32+32-$length),$length)
    $offset+=$length
  }
  if($offset -ne $der.Length){throw 'Trailing signature bytes'}
  $cng=[Security.Cryptography.CngKey]::Import($blob,[Security.Cryptography.CngKeyBlobFormat]::EccPublicBlob)
  $ecdsa=New-Object Security.Cryptography.ECDsaCng($cng)
  $stream=[IO.File]::OpenRead($Path)
  try {
    $ecdsa.HashAlgorithm=[Security.Cryptography.CngAlgorithm]::Sha256
    return $ecdsa.VerifyData($stream,$raw)
  } finally {$stream.Dispose();$ecdsa.Dispose();$cng.Dispose()}
}
