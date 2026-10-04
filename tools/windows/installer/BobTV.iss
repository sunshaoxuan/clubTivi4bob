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
  #define OutputName "BobTV-" + AppVersion + "-windows-x64-Setup"
#endif

[Setup]
AppId={{#InstallerAppId}
AppName=BobTV
AppVersion={#AppVersion}
VersionInfoVersion={#StringChange(AppVersion, "+", ".")}
AppPublisher=BoB
AppPublisherURL=https://bobtv.briconbric.com
AppSupportURL=https://bobtv.briconbric.com
DefaultDirName={autopf}\BoB\BoBTV
DisableDirPage=no
DefaultGroupName=BoB\BobTV
DisableProgramGroupPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#OutputDirectory}
OutputBaseFilename={#OutputName}
SetupIconFile={#BundleDirectory}\BobTV.ico
UninstallDisplayIcon={app}\BobTV.exe
UninstallDisplayName=BobTV
Compression=lzma2/fast
SolidCompression=yes
WizardStyle=modern
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
WizardSelectTasks=快捷方式
SelectTasksDesc=选择需要创建的快捷方式。
SelectTasksLabel2=开始菜单入口将自动创建。你可以选择是否另外创建桌面图标。
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

[Icons]
Name: "{#ProgramsRoot}\BoB\BobTV\BobTV"; Filename: "{app}\BobTV.exe"; WorkingDir: "{app}"; AppUserModelID: "BoB.BobTV"
Name: "{#DesktopRoot}\BobTV"; Filename: "{app}\BobTV.exe"; WorkingDir: "{app}"; Tasks: desktopicon; AppUserModelID: "BoB.BobTV"

[INI]
Filename: "{app}\installation.ini"; Section: "BobTVInstallation"; Key: "Managed"; String: "1"; Flags: uninsdeleteentry
Filename: "{app}\installation.ini"; Section: "BobTVInstallation"; Key: "DesktopShortcut"; String: "{code:DesktopShortcutChoice}"; Flags: uninsdeleteentry

[UninstallDelete]
Type: files; Name: "{app}\installation.ini"

[Run]
Filename: "{app}\BobTV.exe"; WorkingDir: "{app}"; Description: "{cm:LaunchBobTV}"; Flags: nowait postinstall skipifsilent runasoriginaluser

[Code]
function DesktopShortcutChoice(Param: String): String;
begin
  if WizardIsTaskSelected('desktopicon') then Result := '1'
  else Result := '0';
end;
