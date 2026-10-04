# BobTV Windows Setup

Build locally with the official Inno Setup 6 compiler. GitHub Actions is not
required. Supply the same verified bundle used for the portable ZIP, with its
executable named `BobTV.exe` and its icon named `BobTV.ico`.

```powershell
tools/windows/build_installer.ps1 -BundleDirectory C:\Build\BobTV -OutputDirectory C:\Build\Packages
tools/windows/test_installer.ps1 -BundleDirectory C:\Build\BobTV -CompilerPath 'C:\Program Files (x86)\Inno Setup 6\ISCC.exe'
```

Default destination: `C:\Program Files\BoB\BoBTV` on 64-bit Windows.
Setup requests administrator authorization and uses a stable application ID so
future Setup packages upgrade the same installation. Desktop shortcut creation
is an optional task, initially selected. A Start menu entry is always created.
The app launches as the original, non-elevated user from the finish page.

`installation.ini` marks a managed installation. The application and ZIP updater
must preserve it and must not recreate shortcuts against the installer's choice.
Portable installations retain their automatic desktop-shortcut behavior.

Setup and Uninstall never remove per-user channel, favorite, preference, or log
directories. Uninstall only removes its tracked application files and shortcuts.
The isolated tests do not start BobTV or touch its live database. They use a
unique application ID, private shortcut directories, and a Chinese/Japanese path.

The ZIP remains the update payload; Setup is the initial installation interface.
Program Files is protected: the current per-user ZIP updater does not acquire
administrator rights. A controlled update service or explicit administrator
authorization is required before deploying unattended updates to this location.
Do not grant ordinary users write access to Program Files to bypass this boundary.
