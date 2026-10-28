import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';
import 'app_diagnostics.dart';

abstract class WindowPinBackend {
  Future<bool> isFullscreen();
  Future<bool> isAlwaysOnTop();
  Future<void> setAlwaysOnTop(bool value);
}

class _NativeWindowPinBackend implements WindowPinBackend {
  @override
  Future<bool> isFullscreen() => windowManager.isFullScreen();
  @override
  Future<bool> isAlwaysOnTop() => windowManager.isAlwaysOnTop();
  @override
  Future<void> setAlwaysOnTop(bool value) =>
      windowManager.setAlwaysOnTop(value);
}

class WindowPinRequiresWindowMode implements Exception {}

/// One explicit pin preference for the application window during this run.
/// Fullscreen and PiP may temporarily own the native level independently.
class DesktopWindowPin extends ChangeNotifier with WindowListener {
  DesktopWindowPin({WindowPinBackend? backend})
    : _backend = backend ?? _NativeWindowPinBackend(),
      _nativeEvents = backend == null {
    if (_nativeEvents) windowManager.addListener(this);
  }

  static final instance = DesktopWindowPin();
  final WindowPinBackend _backend;
  final bool _nativeEvents;
  bool? _requested;
  bool _busy = false;
  int _presentationLocks = 0;
  bool _disposed = false;
  Future<void>? _operation;

  bool get pinned => _requested ?? false;
  bool get busy => _busy;
  bool get canToggle => !_disposed && !_busy && _presentationLocks == 0;
  bool restoreValue(bool previous) => _requested ?? previous;

  Future<void> get idle async {
    try {
      await _operation;
    } catch (_) {
      // The button reports failures. Presentation can capture the rolled-back
      // native state once that operation has finished.
    }
  }

  /// Prevent pin writes racing native fullscreen or PiP level changes.
  VoidCallback lockForPresentation() {
    _presentationLocks++;
    _notify();
    var released = false;
    return () {
      if (released) return;
      released = true;
      _presentationLocks--;
      _notify();
    };
  }

  Future<void> toggle() {
    if (!canToggle) return _operation ?? Future<void>.value();
    return _run(_toggle);
  }

  Future<void> _run(Future<void> Function() operation) {
    final completion = Completer<void>();
    _operation = completion.future;
    _busy = true;
    _notify();
    unawaited(() async {
      try {
        await operation();
        completion.complete();
      } catch (error, stack) {
        completion.completeError(error, stack);
      } finally {
        _busy = false;
        _operation = null;
        _notify();
      }
    }());
    return completion.future;
  }

  @override
  void onWindowLeaveFullScreen() => _restoreWindowedPin();

  @override
  void onWindowFocus() => _restoreWindowedPin();

  void _restoreWindowedPin() {
    if (_requested == null || !canToggle) return;
    unawaited(
      _run(() async {
        if (await _backend.isFullscreen()) return;
        final desired = _requested!;
        if (await _backend.isAlwaysOnTop() != desired) {
          await _backend.setAlwaysOnTop(desired);
          if (await _backend.isAlwaysOnTop() != desired) {
            throw StateError('Native window pin restoration was not applied');
          }
        }
      }).catchError((Object error, StackTrace stack) {
        AppDiagnostics.instance.recordError(
          'desktop_window_pin_restore',
          error,
          stack,
        );
      }),
    );
  }

  Future<void> _toggle() async {
    if (await _backend.isFullscreen()) throw WindowPinRequiresWindowMode();
    final previous = await _backend.isAlwaysOnTop();
    final desired = !pinned;
    try {
      await _backend.setAlwaysOnTop(desired);
      if (await _backend.isAlwaysOnTop() != desired) {
        throw StateError('Native window pin state was not applied');
      }
    } catch (_) {
      // Retain the last verified preference and attempt to undo a partial write.
      try {
        await _backend.setAlwaysOnTop(previous);
      } catch (_) {}
      rethrow;
    }
    _requested = desired;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    if (_nativeEvents) windowManager.removeListener(this);
    super.dispose();
  }
}
