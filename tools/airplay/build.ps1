$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot\..\..").Path
$venv = Join-Path $root 'build\airplay-venv'
if (-not (Test-Path "$venv\Scripts\python.exe")) {
  python -m venv $venv
  if ($LASTEXITCODE) { throw 'AirPlay virtual environment failed' }
}
$python = "$venv\Scripts\python.exe"
& $python -m pip install -r "$PSScriptRoot\requirements.txt"
if ($LASTEXITCODE) { throw 'AirPlay dependency installation failed' }
& $python -m PyInstaller --noconfirm --clean --onedir --console --name bobtv-airplay --collect-all pyatv --recursive-copy-metadata pyatv --distpath "$root\build\airplay-dist" --workpath "$root\build\airplay-work" --specpath "$root\build" "$PSScriptRoot\bobtv_airplay.py"
if ($LASTEXITCODE) { throw 'AirPlay helper build failed' }
Copy-Item -LiteralPath "$PSScriptRoot\AIRSPAN-LICENSE.txt" -Destination "$root\build\airplay-dist\bobtv-airplay"
# The independently built FPSAP adapter is packaged only when its complete
# corresponding-source/license bundle is available. No binary-only fallback.
$native = Join-Path $root 'build\fpsap-dist'
if (Test-Path -LiteralPath "$native\fpsap-auth.exe") {
  foreach ($required in @('fpsap-upstream-source.zip','fpsap_auth.go','build-fpsap.ps1','FPSAP-LICENSE','FPSAP-COPYING.GPL-3.0','FPSAP-LICENSE.BlueOak-1.0.0','FPSAP-NOTICE.md')) {
    if (-not (Test-Path -LiteralPath (Join-Path $native $required))) { throw "Native Mac source/license bundle incomplete: $required" }
  }
  Copy-Item -Path "$native\*" -Destination "$root\build\airplay-dist\bobtv-airplay" -Force
}
