import 'package:window_manager/window_manager.dart';
import 'package:flutter/services.dart';

const _windowChrome = MethodChannel('bobtv/window_chrome');

/// Remove the actual Win32 caption during video fullscreen. Hiding its layout
/// alone lets Windows reveal a native caption/snap surface over Flutter.
Future<void> setWindowsVideoFullscreenChrome(bool fullscreen) =>
    _windowChrome.invokeMethod<void>('setVideoFullscreenChrome', fullscreen);

/// Restore every normal-window capability together, after native fullscreen.
/// Never call this while transferring fullscreen to the channel page.
Future<void> restoreWindowsWindowChrome({
  bool resizable = true,
  bool maximizable = true,
}) async {
  await setWindowsVideoFullscreenChrome(false);
  await windowManager.setTitleBarStyle(
    TitleBarStyle.normal,
    windowButtonVisibility: true,
  );
  await windowManager.setResizable(resizable);
  await windowManager.setMaximizable(maximizable);
}
