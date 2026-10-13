import 'package:flutter/services.dart';

/// One owner for Android/mobile immersive mode. Rapid back/re-entry must finish
/// restoring the previous route's system UI before the next route enters it.
class MobileFullscreenSession {
  MobileFullscreenSession({Future<void> Function(SystemUiMode)? setMode})
    : _setMode = setMode ?? SystemChrome.setEnabledSystemUIMode;

  final Future<void> Function(SystemUiMode) _setMode;
  Future<void>? _entry;
  Future<void>? _exit;
  bool _leaving = false;

  Future<void> enter() {
    if (_leaving) return Future<void>.value();
    return _entry ??= _setMode(SystemUiMode.immersiveSticky);
  }

  Future<void> exit() {
    _leaving = true;
    return _exit ??= _restore().catchError((Object error, StackTrace stack) {
      _exit = null;
      Error.throwWithStackTrace(error, stack);
    });
  }

  Future<void> _restore() async {
    try {
      await _entry;
    } catch (_) {
      // A failed entry still needs ordinary system UI when leaving its route.
    }
    await _setMode(SystemUiMode.edgeToEdge);
  }
}
