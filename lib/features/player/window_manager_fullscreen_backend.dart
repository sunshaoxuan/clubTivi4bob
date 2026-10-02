import 'dart:async';
import 'dart:io';

import 'package:window_manager/window_manager.dart';

import 'desktop_fullscreen_session.dart';
import '../../core/app_diagnostics.dart';

/// Cocoa owns saved geometry and completes fullscreen through native events.
/// Windows/Linux keep their explicit titlebar and geometry restoration.
class WindowManagerFullscreenBackend extends WindowListener
    implements FullscreenWindowBackend {
  WindowManagerFullscreenBackend({bool? isMacOS})
    : _isMacOS = isMacOS ?? Platform.isMacOS {
    windowManager.addListener(this);
  }

  final bool _isMacOS;
  final _changes = StreamController<bool>.broadcast(sync: true);
  Completer<void>? _transition;
  bool? _transitionTarget;
  bool _disposed = false;

  @override
  Stream<bool> get fullscreenChanges => _changes.stream;

  @override
  Future<FullscreenWindowSnapshot> capture() async => FullscreenWindowSnapshot(
    bounds: await windowManager.getBounds(),
    maximized: await windowManager.isMaximized(),
    alwaysOnTop: await windowManager.isAlwaysOnTop(),
  );

  @override
  Future<bool> isFullscreen() => windowManager.isFullScreen();

  @override
  Future<void> prepareEntry() async {
    if (!_isMacOS) {
      await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
    }
  }

  @override
  Future<void> setFullscreen(bool value) async {
    if (await isFullscreen() != value) {
      // On macOS the method reply starts the animation; the event finishes it.
      final completion = _isMacOS ? Completer<void>() : null;
      _transition = completion;
      _transitionTarget = value;
      try {
        await windowManager.setFullScreen(value);
        if (completion != null) {
          await completion.future.timeout(const Duration(seconds: 10));
        }
      } finally {
        _transition = null;
        _transitionTarget = null;
      }
    }
    if (value) {
      // A user may have exited natively while the method reply was pending.
      if (_isMacOS && !await isFullscreen()) return;
      await windowManager.setAlwaysOnTop(true);
      if (!await windowManager.isMinimized() &&
          (!_isMacOS || await isFullscreen())) {
        await windowManager.focus();
      }
    }
  }

  @override
  Future<void> restore(FullscreenWindowSnapshot snapshot) async {
    await windowManager.setAlwaysOnTop(snapshot.alwaysOnTop);
    if (_isMacOS) return;
    await windowManager.setTitleBarStyle(TitleBarStyle.normal);
    // Never unminimize or resize a window that the user sent to the taskbar.
    if (await windowManager.isMinimized()) return;
    if (snapshot.maximized) {
      await windowManager.maximize();
    } else {
      await windowManager.setBounds(snapshot.bounds);
    }
  }

  void _completed(bool value) {
    if (_disposed) return;
    AppDiagnostics.instance.log('fullscreen_native_completion', {
      'fullscreen': value,
      'requested': _transitionTarget,
    });
    final transition = _transition;
    if (_transitionTarget == value &&
        transition != null &&
        !transition.isCompleted) {
      transition.complete();
    }
    _changes.add(value);
  }

  @override
  void onWindowEnterFullScreen() => _completed(true);

  @override
  void onWindowLeaveFullScreen() => _completed(false);

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    windowManager.removeListener(this);
    unawaited(_changes.close());
  }
}
