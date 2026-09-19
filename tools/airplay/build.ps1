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
