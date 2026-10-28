import 'dart:async';

import 'desktop_fullscreen_session.dart';

/// A window-filling player can temporarily enter native fullscreen without
/// leaving its route. Ordinary window playback never touches native geometry.
class WindowPlaybackSession {
  WindowPlaybackSession({
    required FullscreenWindowBackend Function() createBackend,
    required void Function(bool) onChanged,
    void Function(Object, StackTrace)? onError,
  }) : _createBackend = createBackend,
       _onChanged = onChanged,
       _onError = onError;

  final FullscreenWindowBackend Function() _createBackend;
  final void Function(bool) _onChanged;
  final void Function(Object, StackTrace)? _onError;
  DesktopFullscreenSession? _session;
  Future<void>? _exitFuture;
  bool _fullscreen = false;
  bool _disposed = false;

  bool get isFullscreen => _fullscreen;
  bool get fullscreenRequested => _session != null;

  /// Presentation changes also preserve paused playback and failover URLs.
  static bool canReusePlayback({
    required String? activeUrl,
    required String? activeChannelId,
    required String? selectedChannelId,
    required Iterable<String> selectedUrls,
  }) {
    if (activeUrl == null || activeUrl.isEmpty) return false;
    if (activeChannelId != null && selectedChannelId != null) {
      return activeChannelId == selectedChannelId;
    }
    return selectedUrls.contains(activeUrl);
  }

  Future<void> toggleFullscreen() {
    if (_disposed || _exitFuture != null) return Future<void>.value();
    return _session == null ? enterFullscreen() : exitFullscreen();
  }

  Future<void> enterFullscreen() async {
    if (_disposed) return;
    final exiting = _exitFuture;
    if (exiting != null) await exiting;
    if (_disposed) return;
    final session = _session ??= DesktopFullscreenSession(
      backend: _createBackend(),
      onChanged: (fullscreen) {
        if (_disposed) return;
        _fullscreen = fullscreen;
        _onChanged(fullscreen);
      },
      onExternalExit: () {
        unawaited(exitFullscreen().catchError(_reportError));
      },
      onWindowRestore: () async {
        await exitFullscreen();
        return true;
      },
      onError: _reportError,
    );
    try {
      await session.enter();
    } catch (error, stack) {
      try {
        await exitFullscreen();
      } catch (cleanupError, cleanupStack) {
        _reportError(cleanupError, cleanupStack);
      }
      Error.throwWithStackTrace(error, stack);
    }
  }

  Future<void> exitFullscreen() {
    final session = _session;
    if (session == null) return Future<void>.value();
    return _exitFuture ??= _exit(
      session,
    ).whenComplete(() => _exitFuture = null);
  }

  Future<void> _exit(DesktopFullscreenSession session) async {
    await session.exit(forceWindowed: true);
    if (identical(_session, session)) {
      _session = null;
      session.dispose();
    }
  }

  void _reportError(Object error, StackTrace stack) =>
      _onError?.call(error, stack);

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _fullscreen = false;
    _session?.dispose();
    _session = null;
  }
}
