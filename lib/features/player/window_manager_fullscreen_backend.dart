import 'dart:async';
import 'dart:io';

import 'package:window_manager/window_manager.dart';

import 'desktop_fullscreen_session.dart';
import 'windows_window_chrome.dart';
import '../../core/app_diagnostics.dart';
import '../../core/desktop_window_sizing.dart';

/// Cocoa completes fullscreen through native events or verified native state.
/// Windows/Linux keep their explicit titlebar and geometry restoration.
class WindowManagerFullscreenBackend extends WindowListener
    implements FullscreenWindowBackend {
  WindowManagerFullscreenBackend({
    bool? isMacOS,
    bool? isWindows,
    DesktopWindowSizing? sizing,
  }) : _isMacOS = isMacOS ?? Platform.isMacOS,
       _isWindows = isWindows ?? Platform.isWindows,
       _sizing = sizing ?? DesktopWindowSizing.instance {
    windowManager.addListener(this);
  }

  final bool _isMacOS;
  final bool _isWindows;
  final DesktopWindowSizing _sizing;
  final _changes = StreamController<bool>.broadcast(sync: true);
  Completer<void>? _transition;
  bool? _transitionTarget;
  bool _disposed = false;
  void Function()? _releaseSizing;

  @override
  Stream<bool> get fullscreenChanges => _changes.stream;

  @override
  Future<FullscreenWindowSnapshot> capture() async {
    final fullscreen = await windowManager.isFullScreen();
    return FullscreenWindowSnapshot(
      bounds: await windowManager.getBounds(),
      maximized: await windowManager.isMaximized(),
      alwaysOnTop: await windowManager.isAlwaysOnTop(),
      wasFullscreen: fullscreen,
      resizable: _isWindows ? await windowManager.isResizable() : true,
      // The Windows plugin temporarily removes WS_MAXIMIZEBOX in fullscreen.
      // It must not become the saved normal-window capability on re-entry.
      maximizable: _isWindows && !fullscreen
          ? await windowManager.isMaximizable()
          : true,
    );
  }

  @override
  Future<bool> isFullscreen() => windowManager.isFullScreen();

  @override
  Future<void> prepareEntry() async {
    _releaseSizing ??= _sizing.suspend();
    // Cocoa owns titlebar suppression. Windows' native plugin only removes the
    // caption from an already-maximized window when this style is hidden.
    if (_isWindows) {
      await windowManager.setTitleBarStyle(
        TitleBarStyle.hidden,
        windowButtonVisibility: false,
      );
    }
  }

  @override
  Future<void> setFullscreen(bool value) async {
    if (_isMacOS) {
      // Native Escape can leave the fullscreen Space after the player route
      // transferred ownership to the channel page. Cocoa must never inherit a
      // floating level on the next entry; the native fullscreen Space already
      // provides the Mac presentation and does not need a floating window.
      await windowManager.setAlwaysOnTop(false);
    }
    if (await isFullscreen() != value) {
      // On macOS the method reply starts the animation; the event finishes it.
      final completion = _isMacOS ? Completer<void>() : null;
      // A native cancel can precede the method acknowledgement. Observe errors
      // immediately; the transition waiter still receives the same result.
      completion?.future.ignore();
      _transition = completion;
      _transitionTarget = value;
      try {
        await windowManager.setFullScreen(value);
        if (completion != null) {
          await _awaitNativeTransition(value, completion);
        }
      } finally {
        _transition = null;
        _transitionTarget = null;
      }
    }
    if (_isWindows) {
      if (await isFullscreen() != value) {
        throw StateError('Windows fullscreen state did not reach $value');
      }
      await setWindowsVideoFullscreenChrome(value);
      // Windows omits fullscreen notifications for some normal/maximized
      // placements. A verified method result still completes this session.
      _completed(value);
    }
    if (value) {
      // A user may have exited natively while the method reply was pending.
      if (_isMacOS && !await isFullscreen()) return;
      if (!_isMacOS) await windowManager.setAlwaysOnTop(true);
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
    // Cancellation may already have arrived before the method replied.
    await completion.future;
  }

  @override
  Future<void> restore(FullscreenWindowSnapshot snapshot) async {
    try {
      await _restore(snapshot);
    } finally {
      _releaseSizing?.call();
      _releaseSizing = null;
    }
  }

  Future<void> _restore(FullscreenWindowSnapshot snapshot) async {
    await windowManager.setAlwaysOnTop(snapshot.alwaysOnTop);
    if (_isMacOS) {
      if (await windowManager.isMinimized()) return;
      // A caller already in a native fullscreen Space has no ordinary frame
      // to restore. Otherwise repair only a changed post-animation frame.
      if (snapshot.wasFullscreen) return;
      if (snapshot.maximized) {
        if (!await windowManager.isMaximized()) await windowManager.maximize();
      } else {
        if (await windowManager.isMaximized()) await windowManager.unmaximize();
        final bounds = await _sizing.constrain(snapshot.bounds);
        await _sizing.restoreMinimumSize(bounds);
        if (await windowManager.getBounds() == bounds) return;
        AppDiagnostics.instance.log('fullscreen_window_bounds_restored', {
          'width': bounds.width,
          'height': bounds.height,
        });
        await windowManager.setBounds(bounds);
      }
      return;
    }
    if (_isWindows) {
      // A caller using native window fullscreen keeps that window state while
      // the video route returns to its original channel layout.
      if (await isFullscreen()) return;
      await restoreWindowsWindowChrome(
        resizable: snapshot.resizable,
        maximizable: snapshot.maximizable,
      );
    } else {
      await windowManager.setTitleBarStyle(TitleBarStyle.normal);
    }
    if (_isWindows && snapshot.wasFullscreen) return;
    // Never unminimize or resize a window that the user sent to the taskbar.
    if (await windowManager.isMinimized()) return;
    if (snapshot.maximized) {
      await windowManager.maximize();
    } else {
      if (await windowManager.isMaximized()) await windowManager.unmaximize();
      final bounds = await _sizing.constrain(snapshot.bounds);
      await _sizing.restoreMinimumSize(bounds);
      await windowManager.setBounds(bounds);
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
    } else if (_transitionTarget == true &&
        !value &&
        transition != null &&
        !transition.isCompleted) {
      // Escape can cancel entry before Cocoa has sent didEnterFullScreen.
      // Finish the cancelled request now instead of holding navigation for
      // the full transition timeout.
      transition.completeError(const FullscreenEntryCancelled());
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
    _releaseSizing?.call();
    _releaseSizing = null;
    windowManager.removeListener(this);
    unawaited(_changes.close());
  }
}
