import 'package:window_manager/window_manager.dart';

/// Restore every normal-window capability together, after native fullscreen.
/// Never call this while transferring fullscreen to the channel page.
Future<void> restoreWindowsWindowChrome({
  bool resizable = true,
  bool maximizable = true,
}) async {
  await windowManager.setTitleBarStyle(
    TitleBarStyle.normal,
    windowButtonVisibility: true,
  );
  await windowManager.setResizable(resizable);
  await windowManager.setMaximizable(maximizable);
}
