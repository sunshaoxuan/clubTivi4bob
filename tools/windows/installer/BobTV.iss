; Build with build_installer.ps1. No private keys or user data in this bundle.
#ifndef BundleDirectory
  #error BundleDirectory is required
#endif
#ifndef OutputDirectory
  #error OutputDirectory is required
#endif
#ifndef AppVersion
  #error AppVersion is required
#endif
#ifndef InstallerAppId
  #define InstallerAppId "{CE865318-6E48-44EB-B426-AC7B08534735}"
#endif
#ifndef DesktopRoot
  #define DesktopRoot "{commondesktop}"
#endif
#ifndef ProgramsRoot
  #define ProgramsRoot "{commonprograms}"
#endif
#ifndef OutputName
  #ifndef AppArchitecture
    #define AppArchitecture "x64"
  #endif
  #define OutputName "BobTV-" + AppVersion + "-windows-" + AppArchitecture + "-Setup"
#endif
#ifndef AppArchitecture
  #define AppArchitecture "x64"
#endif

[Setup]
AppId={{#InstallerAppId}
AppName=BobTV
AppVersion={#AppVersion}
VersionInfoVersion={#StringChange(AppVersion, "+", ".")}
VersionInfoTextVersion={#AppVersion}
VersionInfoProductVersion={#StringChange(AppVersion, "+", ".")}
VersionInfoProductTextVersion={#AppVersion}
VersionInfoProductName=BobTV
AppPublisher=BoB
AppPublisherURL=https://bobtv.briconbric.com
AppSupportURL=https://bobtv.briconbric.com
DefaultDirName={autopf}\BoB\BoBTV
DisableDirPage=no
DefaultGroupName=BoB\BobTV
DisableProgramGroupPage=yes
PrivilegesRequired=admin
#if AppArchitecture == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
MinVersion=10.0.22000
#else
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
#endif
OutputDir={#OutputDirectory}
OutputBaseFilename={#OutputName}
SetupIconFile={#BundleDirectory}\BobTV.ico
UninstallDisplayIcon={app}\BobTV.exe
UninstallDisplayName=BobTV
Compression=lzma2/fast
SolidCompression=yes
WizardStyle=modern
InfoBeforeFile=PrivacyNotice.txt
SetupLogging=yes
CloseApplications=yes
RestartApplications=no
RestartIfNeededByRun=no
UsePreviousTasks=yes
AppMutex=BobTVInstaller

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[CustomMessages]
english.DesktopIcon=创建桌面快捷方式
english.LaunchBobTV=启动 BobTV
english.FavoritesBackup=首次启动时启用本机收藏在线备份（仅原设备可恢复）

[Messages]
SetupAppTitle=安装
SetupWindowTitle=%1 安装
UninstallAppTitle=卸载
UninstallAppFullTitle=卸载 %1
ButtonBack=< 上一步(&B)
ButtonNext=下一步(&N) >
ButtonInstall=安装(&I)
ButtonCancel=取消
ButtonFinish=完成(&F)
ButtonBrowse=浏览(&B)...
ButtonWizardBrowse=浏览(&R)...
ButtonOK=确定
ButtonYes=是(&Y)
ButtonNo=否(&N)
ClickNext=点击“下一步”继续，或点击“取消”退出安装。
WelcomeLabel1=欢迎使用 [name] 安装向导
WelcomeLabel2=即将在电脑上安装 [name/ver]。%n%n频道、收藏和个人设置保存在当前用户的数据目录中，安装和卸载不会清除这些数据。
WizardSelectDir=选择安装位置
SelectDirDesc=将 [name] 安装到哪里？
SelectDirLabel3=程序将安装到以下文件夹。
SelectDirBrowseLabel=点击“下一步”继续，或点击“浏览”选择其他位置。
WizardSelectTasks=安装选项
SelectTasksDesc=选择快捷方式与本机收藏备份选项。
SelectTasksLabel2=开始菜单入口将自动创建。收藏备份仅原设备可恢复，也可在 BobTV 设置中关闭。
WizardReady=准备安装
ReadyLabel1=已准备好在电脑上安装 [name]。
ReadyLabel2a=点击“安装”开始，或点击“上一步”调整设置。
ReadyLabel2b=点击“安装”开始。
ReadyMemoDir=安装位置：
ReadyMemoGroup=开始菜单：
ReadyMemoTasks=其他选项：
WizardPreparing=准备安装
WizardInstalling=正在安装
InstallingLabel=正在安装 [name]，请稍候。
StatusCreateDirs=正在创建目录...
StatusExtractFiles=正在写入程序文件...
StatusCreateIcons=正在创建快捷方式...
StatusCreateIniEntries=正在保存安装选项...
StatusCreateRegistryEntries=正在登记应用...
StatusSavingUninstall=正在准备卸载程序...
StatusRunProgram=正在完成安装...
FinishedHeadingLabel=安装完成
FinishedLabel=[name] 已安装。下次可以通过开始菜单或桌面快捷方式打开。
FinishedLabelNoIcons=[name] 已安装。
ClickFinish=点击“完成”退出安装向导。
WizardUninstalling=正在卸载
UninstallStatusLabel=正在卸载 %1，个人频道、收藏和设置将保留。
UninstalledAll=%1 已卸载，个人数据已保留。

[Files]
Source: "{#BundleDirectory}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Excludes: "unins*,installation.ini"

[Tasks]
Name: "desktopicon"; Description: "{cm:DesktopIcon}"; GroupDescription: "快捷方式："
Name: "privatefavoritesbackup"; Description: "{cm:FavoritesBackup}"; GroupDescription: "隐私选项："

[Icons]
Name: "{#ProgramsRoot}\BoB\BobTV\BobTV"; Filename: "{app}\BobTV.exe"; WorkingDir: "{app}"; AppUserModelID: "BoB.BobTV"
Name: "{#DesktopRoot}\BobTV"; Filename: "{app}\BobTV.exe"; WorkingDir: "{app}"; Tasks: desktopicon; AppUserModelID: "BoB.BobTV"

[INI]
Filename: "{app}\installation.ini"; Section: "BobTVInstallation"; Key: "Managed"; String: "1"; Flags: uninsdeleteentry
Filename: "{app}\installation.ini"; Section: "BobTVInstallation"; Key: "DesktopShortcut"; String: "{code:DesktopShortcutChoice}"; Flags: uninsdeleteentry
Filename: "{app}\installation.ini"; Section: "BobTVPrivacy"; Key: "FavoritesBackup"; String: "{code:FavoritesBackupChoice}"; Flags: uninsdeleteentry

[UninstallDelete]
Type: files; Name: "{app}\installation.ini"

[Run]
Filename: "{app}\BobTV.exe"; WorkingDir: "{app}"; Description: "{cm:LaunchBobTV}"; Flags: nowait postinstall skipifsilent runasoriginaluser

[Code]
function OpenProcess(DesiredAccess: LongWord; InheritHandle: Boolean; ProcessId: LongWord): THandle;
  external 'OpenProcess@kernel32.dll stdcall';
function WaitForSingleObject(Handle: THandle; Milliseconds: LongWord): LongWord;
  external 'WaitForSingleObject@kernel32.dll stdcall';
function CloseHandle(Handle: THandle): Boolean;
  external 'CloseHandle@kernel32.dll stdcall';

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ProcessId: Integer;
  Handle: THandle;
begin
  Result := '';
  ProcessId := StrToIntDef(ExpandConstant('{param:BOBTVWAITPID|0}'), 0);
  if ProcessId <= 0 then Exit;
  Handle := OpenProcess($00100000, False, ProcessId);
  if Handle = 0 then Exit;
  try
    { Authorization is complete at this point. The ordinary updater now asks
      BobTV to close, so cancelling UAC never interrupts playback. }
    if WaitForSingleObject(Handle, 120000) <> 0 then
      Result := 'BobTV 仍在运行，请关闭 BobTV 后重试。当前程序不会被强制关闭。';
  finally
    CloseHandle(Handle);
  end;
end;

function DesktopShortcutChoice(Param: String): String;
begin
  if WizardIsTaskSelected('desktopicon') then Result := '1'
  else Result := '0';
end;

function FavoritesBackupChoice(Param: String): String;
begin
  if WizardIsTaskSelected('privatefavoritesbackup') then Result := '1'
  else Result := '0';
end;
