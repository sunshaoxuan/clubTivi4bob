param(
  [Parameter(Mandatory = $true)][string]$ExecutablePath
)

$ErrorActionPreference = 'Stop'
$exe = [IO.Path]::GetFullPath($ExecutablePath)
if (!(Test-Path -LiteralPath $exe -PathType Leaf) -or
    [IO.Path]::GetExtension($exe) -ine '.exe') {
  throw 'BobTV executable missing'
}

# A managed installation owns its shortcut choice. Do not undo an unchecked
# installer task on first launch or during an automatic ZIP update.
$policy=Join-Path ([IO.Path]::GetDirectoryName($exe)) 'installation.ini'
if(Test-Path -LiteralPath $policy -PathType Leaf) {
  $text=[IO.File]::ReadAllText($policy)
  if($text -match '(?m)^\[BobTVInstallation\]\s*$' -and
     $text -match '(?m)^Managed\s*=\s*1\s*$') { return }
}

$desktop = [Environment]::GetFolderPath('DesktopDirectory')
if ([string]::IsNullOrWhiteSpace($desktop) -or
    !(Test-Path -LiteralPath $desktop -PathType Container)) {
  throw 'Current user desktop is unavailable'
}

$shell = New-Object -ComObject WScript.Shell
$visibleDesktops = @($desktop)
$commonDesktop = [Environment]::GetFolderPath('CommonDesktopDirectory')
if ($commonDesktop -and (Test-Path -LiteralPath $commonDesktop -PathType Container)) {
  $visibleDesktops += $commonDesktop
}

function Get-ShortcutTarget([string]$path) {
  try {
    $target = $shell.CreateShortcut($path).TargetPath
    if ($target) {
      return [IO.Path]::GetFullPath(
        [Environment]::ExpandEnvironmentVariables($target))
    }
  } catch {}
  return ''
}

foreach ($folder in $visibleDesktops) {
  foreach ($link in @(Get-ChildItem -LiteralPath $folder -Filter '*.lnk' -File)) {
    if ([string]::Equals((Get-ShortcutTarget $link.FullName), $exe,
                         [StringComparison]::OrdinalIgnoreCase)) {
      return
    }
  }
}

$shortcutPath = Join-Path $desktop 'BobTV.lnk'
if (Test-Path -LiteralPath $shortcutPath) {
  $oldTarget = Get-ShortcutTarget $shortcutPath
  $oldName = [IO.Path]::GetFileName($oldTarget)
  if ($oldName -ine 'BobTV.exe' -and $oldName -ine 'clubtivi.exe') {
    $number = 2
    do {
      $shortcutPath = Join-Path $desktop ("BobTV ($number).lnk")
      $number++
    } while (Test-Path -LiteralPath $shortcutPath)
  }
}

$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $exe
$shortcut.WorkingDirectory = [IO.Path]::GetDirectoryName($exe)
$shortcut.IconLocation = "$exe,0"
$shortcut.Description = 'BobTV'
$shortcut.Save()
