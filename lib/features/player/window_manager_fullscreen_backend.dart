import 'dart:async';
import 'dart:io';

import 'package:window_manager/window_manager.dart';

import 'desktop_fullscreen_session.dart';
import '../../core/app_diagnostics.dart';

/// Cocoa completes fullscreen through native events or verified native state.
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
    wasFullscreen: await windowManager.isFullScreen(),
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
        // Cocoa fullscreen windows must return to the normal window level
        // before leaving their Space. Restore the saved level afterwards.
        if (_isMacOS && !value) {
          await windowManager.setAlwaysOnTop(false);
        }
        await windowManager.setFullScreen(value);
        if (completion != null) {
          await _awaitNativeTransition(value, completion);
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

  Future<void> _awaitNativeTransition(
    bool value,
    Completer<void> completion,
  ) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    var matchingSamples = 0;
    while (!completion.isCompleted) {
      await Future.any([
        completion.future,
        Future<void>.delayed(const Duration(milliseconds: 250)),
      ]);
      if (completion.isCompleted) return;
      // Window delegate notifications may be lost after Cocoa restores a
      // fullscreen window. Confirm stable native state before recovering.
      matchingSamples = await isFullscreen() == value ? matchingSamples + 1 : 0;
      if (matchingSamples >= 4) {
        AppDiagnostics.instance.log('fullscreen_native_state_recovered', {
          'fullscreen': value,
        });
        _completed(value);
        return;
      }
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('Native fullscreen state did not reach $value');
      }
    }
  }

  @override
  Future<void> restore(FullscreenWindowSnapshot snapshot) async {
    await windowManager.setAlwaysOnTop(snapshot.alwaysOnTop);
    if (_isMacOS) {
      if (await windowManager.isMinimized()) return;
      // A caller already in a native fullscreen Space has no ordinary frame
      // to restore. Otherwise repair only a changed post-animation frame.
      if (snapshot.wasFullscreen) return;
      if (snapshot.maximized) {
        if (!await windowManager.isMaximized()) await windowManager.maximize();
      } else if (await windowManager.getBounds() != snapshot.bounds) {
        AppDiagnostics.instance.log('fullscreen_window_bounds_restored', {
          'width': snapshot.bounds.width,
          'height': snapshot.bounds.height,
        });
        await windowManager.setBounds(snapshot.bounds);
      }
      return;
    }
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
