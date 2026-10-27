param([int]$CurrentPid, [int]$WorkerPid, [string]$Version, [string]$RunId, [string]$AppDir)
$ErrorActionPreference='Stop'
$root=$PSScriptRoot
$uiLog=Join-Path $root 'progress-ui.log'
function Log([string]$message){
  try{
    Add-Content -LiteralPath $uiLog -Value ([DateTime]::UtcNow.ToString('o')+' '+$message) -Encoding utf8 -ErrorAction Stop
  }catch{
    # Diagnostic logging must never interrupt window initialization or status updates.
  }
}
if($RunId -notmatch '^[A-Za-z0-9-]{1,100}$'){throw 'Invalid updater run ID'}
$statusPath=Join-Path $root ('status-'+$RunId+'.json')
# Only show the separate progress window after the player has been closed.
$player=Get-Process -Id $CurrentPid -ErrorAction SilentlyContinue
if($player){$player.WaitForExit()}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
# WinForms' disabled themed Button paints black text regardless of ForeColor.
Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing -TypeDefinition @'
public class BobTVUpdateButton : System.Windows.Forms.Button {
  protected override void OnPaint(System.Windows.Forms.PaintEventArgs e) {
    e.Graphics.Clear(BackColor);
    using (var pen = new System.Drawing.Pen(System.Drawing.Color.FromArgb(157,173,197)))
      e.Graphics.DrawRectangle(pen, 0, 0, Width-1, Height-1);
    System.Windows.Forms.TextRenderer.DrawText(e.Graphics, Text, Font, ClientRectangle,
      System.Drawing.Color.White, System.Windows.Forms.TextFormatFlags.HorizontalCenter |
      System.Windows.Forms.TextFormatFlags.VerticalCenter);
  }
}
'@

$form=New-Object Windows.Forms.Form
$form.Text='BobTV 更新'
$form.ClientSize=New-Object Drawing.Size(500,340)
$form.StartPosition='CenterScreen'
$form.FormBorderStyle='FixedDialog'
$form.MaximizeBox=$false
$form.MinimizeBox=$true
$form.BackColor=[Drawing.Color]::FromArgb(16,25,42)
$form.ForeColor=[Drawing.Color]::FromArgb(232,238,255)
$form.Font=New-Object Drawing.Font('Segoe UI',10)
function Label([string]$text,[int]$y,[int]$height) {
  $label=New-Object Windows.Forms.Label
  $label.Text=$text; $label.Location=New-Object Drawing.Point(24,$y)
  $label.Size=New-Object Drawing.Size(440,$height)
  $form.Controls.Add($label)
  return $label
}
$title=Label ('BobTV '+$Version) 20 36
$title.Font=New-Object Drawing.Font('Segoe UI',19,[Drawing.FontStyle]::Bold)
$phase=Label '正在读取更新进度' 70 30
$detail=Label '请稍候，更新会在此窗口显示进度。' 152 65
$note=Label '关闭这个状态窗口不会中止更新。' 225 28
$note.ForeColor=[Drawing.Color]::FromArgb(157,173,197)
$bar=New-Object Windows.Forms.ProgressBar
$bar.Location=New-Object Drawing.Point(24,116)
$bar.Size=New-Object Drawing.Size(440,10)
$bar.Style='Marquee'; $bar.MarqueeAnimationSpeed=25
$form.Controls.Add($bar)
$open=New-Object BobTVUpdateButton
$open.ForeColor=[Drawing.Color]::White
$open.BackColor=$form.BackColor
$open.Text='立即启动 BobTV'
$open.Location=New-Object Drawing.Point(300,265)
$open.Size=New-Object Drawing.Size(165,30)
$open.Enabled=$false
$open.FlatStyle='Flat'; $form.Controls.Add($open)
$close=New-Object BobTVUpdateButton
$close.Text='关闭窗口'; $close.BackColor=$form.BackColor
$close.Location=New-Object Drawing.Point(24,265)
$close.Size=New-Object Drawing.Size(120,30)
$close.Add_Click({$form.Close()})
$form.Controls.Add($close)
$form.CancelButton=$close
function Get-CompletedExecutable {
  if(!(Test-Path -LiteralPath $statusPath)){return $null}
  $completed=[IO.File]::ReadAllText($statusPath)|ConvertFrom-Json
  $cancelled=$completed.phase -eq 'ready' -and $completed.authorizationCancelled -eq $true
  $restored=$completed.phase -eq 'failed' -and $completed.restored -eq $true
  if(($completed.phase -ne 'installed' -and !$cancelled -and !$restored) -or $completed.runId -ne $RunId -or
     $completed.version -ne $Version -or [int]$completed.workerPid -ne $WorkerPid){return $null}
  $expected=if($cancelled -or $restored){[string]$completed.oldVersion}else{$Version}
  if($expected -notmatch '^\d+\.\d+\.\d+\+\d+$'){return $null}
  foreach($name in @('clubtivi.exe','BobTV.exe')){
    $path=Join-Path $AppDir $name
    if((Test-Path -LiteralPath $path -PathType Leaf) -and
       (Get-Item -LiteralPath $path).VersionInfo.FileVersion -eq $expected -and
       (Test-Path -LiteralPath (Join-Path $AppDir 'data\app.so'))){return $path}
  }
  return $null
}
$open.Add_Click({
  $exe=Get-CompletedExecutable
  if($exe){Start-Process -FilePath $exe -WorkingDirectory $AppDir; $form.Close()}
})
$timer=New-Object Windows.Forms.Timer
$timer.Interval=500
$script:finishedAt=$null
$script:statusWait=[DateTime]::UtcNow
$script:lastPhase=''
$timer.Add_Tick({
  $open.Enabled=$false
  try {
    $status=if(Test-Path -LiteralPath $statusPath){
      [IO.File]::ReadAllText($statusPath)|ConvertFrom-Json
    }
    if(!$status -or $status.runId -ne $RunId -or $status.version -ne $Version -or
        [int]$status.workerPid -ne $WorkerPid){
      if(([DateTime]::UtcNow-$script:statusWait).TotalSeconds -gt 30){
        $phase.Text='更新助手未返回状态'
        $detail.Text='下载或安装尚未确认，启动按钮已禁用。请查看更新日志。'
        $bar.Style='Continuous'; $bar.Value=0
      }
      return
    }
    if($status.phase -notin @('installed','failed') -and
       !(Get-Process -Id $WorkerPid -ErrorAction SilentlyContinue)){
      $final=[IO.File]::ReadAllText($statusPath)|ConvertFrom-Json
      if($final.runId -eq $RunId -and $final.version -eq $Version -and
         [int]$final.workerPid -eq $WorkerPid){$status=$final}
    }
    $phase.Text=switch($status.phase){
      'starting' {'正在准备下载'}
      'waiting' {'等待启动检查完成'}
      'downloading' {"正在下载更新 $($status.percent)%"}
      'verifying' {'正在校验安装包'}
      'ready' {'下载完成，正在等待播放器退出'}
      'authorizing' {'请确认 Windows 授权提示'}
      'awaitingExit' {'已授权，正在等待 BobTV 退出'}
      'backingUp' {'正在备份旧版'}
      'installing' {if($null -ne $status.percent){"正在安装更新 $($status.percent)%"}else{'正在安装更新'}}
      'installed' {'更新已完成'}
      'failed' {'更新未完成'}
      default {'正在处理更新'}
    }
    $detail.Text=[string]$status.message
    $capture=$script:lastPhase -ne $status.phase
    if($capture){
      $script:lastPhase=$status.phase
      Log ('phase='+$status.phase+' run='+$RunId)
    }
    if($status.phase -eq 'downloading' -and $status.totalBytes -gt 0){
      $detail.Text+=('  {0:N1} / {1:N1} MB' -f ($status.receivedBytes/1MB),($status.totalBytes/1MB))
    }
    if($status.phase -in @('downloading','installing','installed','failed','ready') -and $null -ne $status.percent){
      $bar.Style='Continuous'; $bar.Value=[Math]::Max(0,[Math]::Min(100,[int]$status.percent))
    }else{$bar.Style='Marquee'}
    if($status.phase -eq 'ready' -and $status.authorizationCancelled -eq $true){
      $phase.Text='授权已取消，当前版本保留'
      $open.Text='继续使用当前版本'
      $open.Enabled=[bool](Get-CompletedExecutable)
      $note.Text='更新包已保留，下次打开 BobTV 后可以重试安装。'
    }elseif($status.phase -eq 'failed' -and $status.restored -eq $true){
      $phase.Text='更新未完成，旧版已恢复'
      $open.Text='启动已恢复的旧版'
      $open.Enabled=[bool](Get-CompletedExecutable)
      $note.Text='已跳过本次失败版本，用户数据和故障记录已保留。'
    }elseif($status.phase -eq 'installed'){
      $open.Text='立即启动 BobTV'
      $open.Enabled=[bool](Get-CompletedExecutable)
      if($open.Enabled){
        if(!$script:finishedAt){$script:finishedAt=[DateTime]::UtcNow}
        $remaining=20-[int]([DateTime]::UtcNow-$script:finishedAt).TotalSeconds
        $note.Text="安装完成，旧版备份已保留。此窗口将在 $remaining 秒后关闭。"
        if($remaining -le 0){$form.Close();return}
      }else{
        $script:finishedAt=$null
        $phase.Text='安装结果未通过检查'
        $detail.Text='程序文件缺失或版本不符，启动按钮已禁用。请查看更新日志。'
        $note.Text='旧版备份已保留，尚未确认安装成功。'
      }
    }elseif($status.phase -eq 'failed'){
      $note.Text='安装未完成，启动按钮已禁用。旧版备份不会被删除。'
    }elseif(!(Get-Process -Id $WorkerPid -ErrorAction SilentlyContinue)){
      $phase.Text='更新助手意外退出'
      $detail.Text='更新尚未完成，启动按钮已禁用。启动错误记录在 launcher.log。'
      $bar.Style='Continuous'
    }
    if($capture -and $env:CI -eq 'true' -and $env:BOBTV_PROGRESS_CAPTURE_DIR){
      $folder=[IO.Path]::GetFullPath($env:BOBTV_PROGRESS_CAPTURE_DIR)
      $allowed=[IO.Path]::GetFullPath((Join-Path $env:TEMP 'BobTVUpdaterTests'))+'\'
      if($folder.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)){
        New-Item -ItemType Directory -Path $folder -Force|Out-Null
        $bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height)
        try{$form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)));$bitmap.Save((Join-Path $folder ($status.phase+'.png')),[Drawing.Imaging.ImageFormat]::Png)}finally{$bitmap.Dispose()}
        @{phase=$status.phase;launchEnabled=$open.Enabled;launchText=$open.Text;launchForeColor=$open.ForeColor.Name;closeEnabled=$close.Enabled}|ConvertTo-Json -Compress|Set-Content -LiteralPath (Join-Path $folder ($status.phase+'.json')) -Encoding UTF8
      }
    }
  }catch{
    # Atomic status replacement can briefly fail a read; retry on the next tick.
    Log ('status_read_failed: '+$_.Exception.Message)
  }
})
$form.Add_Shown({Log ('window_shown run='+$RunId);$timer.Start()})
$form.Add_FormClosed({$timer.Stop();$timer.Dispose()})
[void]$form.ShowDialog()
$form.Dispose()
