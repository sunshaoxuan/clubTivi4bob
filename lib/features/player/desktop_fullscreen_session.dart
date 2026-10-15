import 'dart:async';
import 'dart:ui';

/// A native leave superseded an in-flight fullscreen entry.
class FullscreenEntryCancelled implements Exception {
  const FullscreenEntryCancelled();

  @override
  String toString() => 'Native fullscreen entry was cancelled';
}

class FullscreenWindowSnapshot {
  const FullscreenWindowSnapshot({
    required this.bounds,
    required this.maximized,
    required this.alwaysOnTop,
    this.wasFullscreen = false,
    this.resizable = true,
    this.maximizable = true,
  });
  final Rect bounds;
  final bool maximized;
  final bool alwaysOnTop;
  final bool wasFullscreen;
  final bool resizable;
  final bool maximizable;
}

abstract class FullscreenWindowBackend {
  Stream<bool> get fullscreenChanges;
  Future<FullscreenWindowSnapshot> capture();
  Future<bool> isFullscreen();
  Future<void> setFullscreen(bool value);
  Future<void> prepareEntry();
  Future<void> restore(FullscreenWindowSnapshot snapshot);
  void dispose();
}

/// One owner for entry, native exit, explicit exit and route disposal.
/// The backend must acknowledge transitions only when they actually complete.
class DesktopFullscreenSession {
  DesktopFullscreenSession({
    required FullscreenWindowBackend backend,
    required void Function(bool) onChanged,
    required void Function() onExternalExit,
    void Function(Object, StackTrace)? onError,
    FullscreenWindowSnapshot? returnSnapshot,
    Future<bool> Function()? onWindowRestore,
  }) : _backend = backend,
       _snapshot = returnSnapshot,
       _onWindowRestore = onWindowRestore,
       _onChanged = onChanged,
       _onExternalExit = onExternalExit,
       _onError = onError {
    _subscription = _backend.fullscreenChanges.listen((fullscreen) {
      // Native entry can precede the backend's asynchronous focus work.
      // Observe it now so a fast native exit cannot be lost during that work.
      if (fullscreen) {
        _entered = true;
        return;
      }
      if (!fullscreen &&
          (_entered || _entering) &&
          !_exitRequested &&
          !_disposed &&
          !_externalExitReported) {
        _externalExitReported = true;
        _onExternalExit();
      }
    });
  }

  final FullscreenWindowBackend _backend;
  static DesktopFullscreenSession? _windowOwner;
  final Future<bool> Function()? _onWindowRestore;

  /// Window chrome can finish the owning video route even when a platform
  /// omits its native leave-fullscreen notification.
  static Future<bool> restoreActiveWindow() async {
    final restore = _windowOwner?._onWindowRestore;
    if (restore == null) return false;
    // A busy owner can decline duplicate input. Do not let window chrome start
    // an independent native exit while that route transition is still pending.
    await restore();
    return true;
  }

  final void Function(bool) _onChanged;
  final void Function() _onExternalExit;
  final void Function(Object, StackTrace)? _onError;
  late final StreamSubscription<bool> _subscription;
  FullscreenWindowSnapshot? _snapshot;
  Future<void>? _entryFuture;
  Future<void>? _exitFuture;
  bool _entered = false;
  bool _entering = false;
  bool _exitRequested = false;
  bool _forceWindowed = false;
  bool _externalExitReported = false;
  bool _disposed = false;

  FullscreenWindowSnapshot? get returnSnapshot => _snapshot;

  Future<void> enter() {
    if (_exitRequested || _disposed) return Future<void>.value();
    _windowOwner = this;
    return _entryFuture ??= _performEntry();
  }

  Future<void> _performEntry() async {
    _entering = true;
    try {
      _snapshot ??= await _backend.capture();
      if (_exitRequested) return;
      await _backend.prepareEntry();
      await _backend.setFullscreen(true);
      _entered = !_externalExitReported;
      if (!_disposed && !_exitRequested && _entered) _onChanged(true);
    } on FullscreenEntryCancelled {
      _entered = false;
      if (!_disposed && !_exitRequested && !_externalExitReported) {
        _externalExitReported = true;
        _onExternalExit();
      }
    } finally {
      _entering = false;
    }
  }

  Future<void> exit({bool forceWindowed = false}) {
    final existingExit = _exitFuture;
    if (existingExit != null) return existingExit;
    _forceWindowed = forceWindowed;
    _exitRequested = true;
    return _exitFuture ??= _performExit().catchError((
      Object error,
      StackTrace stack,
    ) {
      _exitFuture = null;
      Error.throwWithStackTrace(error, stack);
    });
  }

  Future<void> _performExit() async {
    // An exit requested during entry waits for its native animation first.
    try {
      await _entryFuture;
    } catch (error, stack) {
      _onError?.call(error, stack);
    }
    final snapshot = _snapshot;
    if (snapshot != null) {
      final targetFullscreen =
          snapshot.wasFullscreen && !_forceWindowed && !_externalExitReported;
      if (await _backend.isFullscreen() != targetFullscreen) {
        await _backend.setFullscreen(targetFullscreen);
      }
      await _backend.restore(snapshot);
    }
    // Disposal shares this completed exit and cannot replay saved geometry.
    _snapshot = null;
    if (identical(_windowOwner, this)) _windowOwner = null;
    _entered = false;
    if (!_disposed) _onChanged(false);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (identical(_windowOwner, this)) _windowOwner = null;
    unawaited(_subscription.cancel());
    unawaited(
      exit().then(
        (_) => _backend.dispose(),
        onError: (Object error, StackTrace stack) {
          _onError?.call(error, stack);
          _backend.dispose();
        },
      ),
    );
  }
}
