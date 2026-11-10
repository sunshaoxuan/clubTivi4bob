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
VersionInfoTextVersion={#StringChange(AppVersion, "+", ".")}
VersionInfoProductVersion={#StringChange(AppVersion, "+", ".")}
VersionInfoProductTextVersion={#StringChange(AppVersion, "+", ".")}
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
Name: "english"; MessagesFile: "compiler:Default.isl"; InfoBeforeFile: "languages\PrivacyNotice.en.txt"
Name: "simplified"; MessagesFile: "languages\ChineseSimplified.isl"; InfoBeforeFile: "PrivacyNotice.txt"
Name: "traditional"; MessagesFile: "languages\ChineseTraditional.isl"; InfoBeforeFile: "languages\PrivacyNotice.zh-TW.txt"
Name: "japanese"; MessagesFile: "compiler:Languages\Japanese.isl"; InfoBeforeFile: "languages\PrivacyNotice.ja.txt"
Name: "french"; MessagesFile: "compiler:Languages\French.isl"; InfoBeforeFile: "languages\PrivacyNotice.fr.txt"
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"; InfoBeforeFile: "languages\PrivacyNotice.es.txt"
Name: "korean"; MessagesFile: "compiler:Languages\Korean.isl"; InfoBeforeFile: "languages\PrivacyNotice.ko.txt"

[CustomMessages]
english.DesktopIcon=Create desktop shortcut
english.LaunchBobTV=Start BobTV
english.FavoritesBackup=Enable online backup of local collections when starting for the first time (only the original device can be restored)
english.ShortcutGroup=shortcut
english.PrivacyGroup=Privacy options
english.StillRunning=BobTV is still running, please close BobTV and try again. The current program will not be forced to close.
simplified.DesktopIcon=创建桌面快捷方式
simplified.LaunchBobTV=启动 BobTV
simplified.FavoritesBackup=首次启动时启用本机收藏在线备份（仅原设备可恢复）
simplified.ShortcutGroup=快捷方式
simplified.PrivacyGroup=隐私选项
simplified.StillRunning=BobTV 仍在运行，请关闭 BobTV 后重试。当前程序不会被强制关闭。
traditional.DesktopIcon=建立桌面快捷方式
traditional.LaunchBobTV=啟動 BobTV
traditional.FavoritesBackup=首次啟動時啟用本機收藏線上備份（僅原裝置可恢復）
traditional.ShortcutGroup=快速方式
traditional.PrivacyGroup=隱私權選項
traditional.StillRunning=BobTV 仍在運行，請關閉 BobTV 後重試。當前程式不會被強制關閉。
japanese.DesktopIcon=デスクトップショートカットを作成する
japanese.LaunchBobTV=BobTV を開始する
japanese.FavoritesBackup=初回起動時にローカル コレクションのオンライン バックアップを有効にする (元のデバイスのみ復元可能)
japanese.ShortcutGroup=ショートカット
japanese.PrivacyGroup=プライバシーオプション
japanese.StillRunning=BobTV はまだ実行中です。BobTV を閉じて、もう一度お試しください。現在のプログラムは強制的に終了されません。
french.DesktopIcon=Créer un raccourci sur le bureau
french.LaunchBobTV=Démarrer BobTV
french.FavoritesBackup=Activer la sauvegarde en ligne des collections locales lors du premier démarrage (seul le périphérique d'origine peut être restauré)
french.ShortcutGroup=raccourci
french.PrivacyGroup=Options de confidentialité
french.StillRunning=BobTV est toujours en cours d'exécution, veuillez fermer BobTV et réessayer. Le programme actuel ne sera pas contraint de fermer.
spanish.DesktopIcon=Crear acceso directo en el escritorio
spanish.LaunchBobTV=Iniciar BobTV
spanish.FavoritesBackup=Habilite la copia de seguridad en línea de las colecciones locales al iniciar por primera vez (solo se puede restaurar el dispositivo original)
spanish.ShortcutGroup=atajo
spanish.PrivacyGroup=Opciones de privacidad
spanish.StillRunning=BobTV aún se está ejecutando, cierre BobTV e inténtelo nuevamente. El programa actual no se verá obligado a cerrar.
korean.DesktopIcon=바탕화면 바로가기 만들기
korean.LaunchBobTV=밥TV 시작
korean.FavoritesBackup=처음 시작할 때 로컬 컬렉션의 온라인 백업 활성화(원래 장치만 복원 가능)
korean.ShortcutGroup=바로가기
korean.PrivacyGroup=개인정보 보호 옵션
korean.StillRunning=BobTV가 아직 실행 중입니다. BobTV를 종료하고 다시 시도하세요. 현재 프로그램은 강제로 닫히지 않습니다.

[Messages]
english.SelectTasksDesc=Select the shortcuts and local favorites backup option.
english.SelectTasksLabel2=The start menu entry will be created automatically. Collection backup can only be restored to the original device and can also be turned off in BobTV settings.
english.WelcomeLabel2=[name/ver] is about to be installed on your computer. %n%nChannels, collections and personal settings are saved in the current user's data directory and will not be cleared by installation and uninstallation.
english.UninstallStatusLabel=%1 is being uninstalled, personal channels, favorites and settings will be retained.
simplified.SelectTasksDesc=选择快捷方式与本机收藏备份选项。
simplified.SelectTasksLabel2=开始菜单入口将自动创建。收藏备份仅原设备可恢复，也可在 BobTV 设置中关闭。
simplified.WelcomeLabel2=即将在电脑上安装 [name/ver]。%n%n频道、收藏和个人设置保存在当前用户的数据目录中，安装和卸载不会清除这些数据。
simplified.UninstallStatusLabel=正在卸载 %1，个人频道、收藏和设置将保留。
traditional.SelectTasksDesc=選擇快捷方式與本機收藏備份選項。
traditional.SelectTasksLabel2=開始功能表入口將自動建立。收藏備份僅原設備可恢復，也可在 BobTV 設定中關閉。
traditional.WelcomeLabel2=即將在電腦上安裝 [name/ver]。 %n%n頻道、收藏和個人設定保存在目前使用者的資料目錄中，安裝和解除安裝不會清除這些資料。
traditional.UninstallStatusLabel=正在卸載 %1，個人頻道、收藏和設定將保留。
japanese.SelectTasksDesc=ショートカットとローカルのお気に入りのバックアップ オプションを選択します。
japanese.SelectTasksLabel2=スタート メニュー エントリは自動的に作成されます。コレクションのバックアップは元のデバイスにのみ復元でき、BobTV 設定でオフにすることもできます。
japanese.WelcomeLabel2=[name/ver] がコンピュータにインストールされようとしています。 %n%nチャンネル、お気に入り、個人設定は現在のユーザーのデータ ディレクトリに保存され、インストールやアンインストールによってこのデータは消去されません。
japanese.UninstallStatusLabel=%1 はアンインストールされますが、個人チャンネル、お気に入り、設定は保持されます。
french.SelectTasksDesc=Sélectionnez l’option de sauvegarde des raccourcis et des favoris locaux.
french.SelectTasksLabel2=L’entrée du menu Démarrer sera créée automatiquement. La sauvegarde de la collection ne peut être restaurée que sur l'appareil d'origine et peut également être désactivée dans les paramètres de BobTV.
french.WelcomeLabel2=[name/ver] est sur le point d’être installé sur votre ordinateur. %n%nLes chaînes, les collections et les paramètres personnels sont enregistrés dans le répertoire de données de l'utilisateur actuel et ne seront pas effacés par l'installation et la désinstallation.
french.UninstallStatusLabel=%1 est en cours de désinstallation, les chaînes personnelles, les favoris et les paramètres seront conservés.
spanish.SelectTasksDesc=Seleccione la opción de copia de seguridad de accesos directos y favoritos locales.
spanish.SelectTasksLabel2=La entrada del menú de inicio se creará automáticamente. La copia de seguridad de la colección solo se puede restaurar en el dispositivo original y también se puede desactivar en la configuración de BobTV.
spanish.WelcomeLabel2=[name/ver] está a punto de instalarse en su computadora. %n%nLos canales, las colecciones y la configuración personal se guardan en el directorio de datos del usuario actual y no se borrarán durante la instalación ni la desinstalación.
spanish.UninstallStatusLabel=%1 se está desinstalando, se conservarán los canales personales, los favoritos y la configuración.
korean.SelectTasksDesc=바로가기 및 로컬 즐겨찾기 백업 옵션을 선택하세요.
korean.SelectTasksLabel2=시작 메뉴 항목이 자동으로 생성됩니다. 컬렉션 백업은 원래 장치로만 복원할 수 있으며 BobTV 설정에서도 끌 수 있습니다.
korean.WelcomeLabel2=[name/ver]가 컴퓨터에 설치되려고 합니다. %n%n채널, 컬렉션 및 개인 설정은 현재 사용자의 데이터 디렉터리에 저장되며 설치 및 제거로 지워지지 않습니다.
korean.UninstallStatusLabel=%1가 제거되고 있으며 개인 채널, 즐겨찾기 및 설정은 유지됩니다.

[Files]
Source: "{#BundleDirectory}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Excludes: "unins*,installation.ini"

[Tasks]
Name: "desktopicon"; Description: "{cm:DesktopIcon}"; GroupDescription: "{cm:ShortcutGroup}"
Name: "privatefavoritesbackup"; Description: "{cm:FavoritesBackup}"; GroupDescription: "{cm:PrivacyGroup}"

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
      Result := ExpandConstant('{cm:StillRunning}');
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
