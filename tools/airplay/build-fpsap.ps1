param([Parameter(Mandatory=$true)][string]$SourceDirectory,
      [Parameter(Mandatory=$true)][string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$expected = '370f9db2e26b21b4a710bdba5d51012c1239e736'
$source = (Resolve-Path -LiteralPath $SourceDirectory).Path
$commit = (& git -C $source rev-parse HEAD).Trim()
if ($LASTEXITCODE -or $commit -ne $expected) { throw 'FPSAP source revision mismatch' }
$changes = & git -C $source status --porcelain
if ($changes) { throw 'Use a clean FPSAP source checkout for the release build' }
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$output = (Resolve-Path -LiteralPath $OutputDirectory).Path
$adapter = Join-Path $PSScriptRoot 'fpsap_auth.go'
$oldGoos = $env:GOOS
$oldGoarch = $env:GOARCH
$oldCgo = $env:CGO_ENABLED
$oldProxy = $env:GOPROXY
Push-Location $source
try {
  $env:GOOS = 'windows'
  $env:GOARCH = 'amd64'
  $env:CGO_ENABLED = '0'
  $env:GOPROXY = 'off'
  & go build -trimpath -o (Join-Path $output 'fpsap-auth.exe') $adapter
  if ($LASTEXITCODE) { throw 'FPSAP adapter build failed' }
  & git archive --format=zip --output=(Join-Path $output 'fpsap-upstream-source.zip') $expected
  if ($LASTEXITCODE) { throw 'FPSAP corresponding source archive failed' }
  Copy-Item -LiteralPath $adapter -Destination $output
  Copy-Item -LiteralPath $PSCommandPath -Destination $output
  foreach ($name in @('LICENSE','COPYING.GPL-3.0','LICENSE.BlueOak-1.0.0','NOTICE.md')) {
    Copy-Item -LiteralPath (Join-Path $source $name) -Destination (Join-Path $output "FPSAP-$name")
  }
} finally {
  Pop-Location
  $env:GOOS = $oldGoos
  $env:GOARCH = $oldGoarch
  $env:CGO_ENABLED = $oldCgo
  $env:GOPROXY = $oldProxy
}
