import 'dart:async';
import 'dart:ui';

class FullscreenWindowSnapshot {
  const FullscreenWindowSnapshot({
    required this.bounds,
    required this.maximized,
    required this.alwaysOnTop,
    this.wasFullscreen = false,
  });
  final Rect bounds;
  final bool maximized;
  final bool alwaysOnTop;
  final bool wasFullscreen;
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
  }) : _backend = backend,
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
          _entered &&
          !_exitRequested &&
          !_disposed &&
          !_externalExitReported) {
        _externalExitReported = true;
        _onExternalExit();
      }
    });
  }

  final FullscreenWindowBackend _backend;
  final void Function(bool) _onChanged;
  final void Function() _onExternalExit;
  final void Function(Object, StackTrace)? _onError;
  late final StreamSubscription<bool> _subscription;
  FullscreenWindowSnapshot? _snapshot;
  Future<void>? _entryFuture;
  Future<void>? _exitFuture;
  bool _entered = false;
  bool _exitRequested = false;
  bool _keepWindowFullscreen = false;
  bool _externalExitReported = false;
  bool _disposed = false;

  Future<void> enter() {
    if (_exitRequested || _disposed) return Future<void>.value();
    return _entryFuture ??= _performEntry();
  }

  Future<void> _performEntry() async {
    _snapshot = await _backend.capture();
    if (_exitRequested && !_keepWindowFullscreen) return;
    await _backend.prepareEntry();
    await _backend.setFullscreen(true);
    _entered = !_externalExitReported;
    if (!_disposed && !_exitRequested && _entered) _onChanged(true);
  }

  Future<void> exit({bool keepWindowFullscreen = false}) {
    final existingExit = _exitFuture;
    if (existingExit != null) return existingExit;
    _keepWindowFullscreen = keepWindowFullscreen;
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
    if (!_keepWindowFullscreen && await _backend.isFullscreen()) {
      await _backend.setFullscreen(false);
    }
    final snapshot = _snapshot;
    if (snapshot != null && !_keepWindowFullscreen) {
      await _backend.restore(snapshot);
    }
    // Returning to the caller transfers the existing fullscreen window to
    // that page. Disposal must not replay native exit or saved geometry.
    _snapshot = null;
    _entered = false;
    if (!_disposed) _onChanged(false);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
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
