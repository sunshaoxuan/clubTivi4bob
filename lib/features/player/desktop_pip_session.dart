import 'dart:ui';

import 'desktop_fullscreen_session.dart';

abstract class DesktopPipBackend {
  Future<FullscreenWindowSnapshot> capture();
  Future<void> compact();
  Future<void> rememberBounds();
  Future<void> restore(FullscreenWindowSnapshot snapshot);
}

/// Changes window presentation only. The active player and video stay alive.
class DesktopPipSession {
  DesktopPipSession(this.backend);
  final DesktopPipBackend backend;
  FullscreenWindowSnapshot? _snapshot;
  Future<void>? _entry;
  Future<void>? _exit;

  Future<void> enter() => _entry ??= _enter();
  Future<void> _enter() async {
    _snapshot = await backend.capture();
    try {
      await backend.compact();
    } catch (_) {
      await backend.restore(_snapshot!);
      _snapshot = null;
      rethrow;
    }
  }

  Future<void> exit() =>
      _exit ??= _restore().catchError((Object error, StackTrace stack) {
        _exit = null;
        Error.throwWithStackTrace(error, stack);
      });
  Future<void> _restore() async {
    try {
      await _entry;
    } catch (_) {
      // A failed entry may still need a retry after failed native restoration.
    }
    final snapshot = _snapshot;
    if (snapshot == null) return;
    // Preference persistence must never prevent the user leaving the window.
    try {
      await backend.rememberBounds();
    } catch (_) {}
    await backend.restore(snapshot);
    _snapshot = null;
  }
}

/// All coordinates are logical desktop pixels, including negative monitors.
Rect desktopPipBounds(List<Rect> displays, Rect main, {Rect? remembered}) {
  if (displays.isEmpty) throw ArgumentError('No usable displays');
  double overlap(Rect a, Rect b) {
    final intersection = a.intersect(b);
    return intersection.isEmpty ? 0 : intersection.width * intersection.height;
  }

  var screen = displays.first;
  final reference = remembered ?? main;
  for (final candidate in displays) {
    if (overlap(candidate, reference) > overlap(screen, reference)) {
      screen = candidate;
    }
  }
  if (remembered != null && overlap(screen, remembered) == 0) {
    return desktopPipBounds(displays, main);
  }
  final width = (remembered?.width ?? 420)
      .clamp(320.0, 640.0)
      .clamp(1.0, screen.width);
  final height = (remembered?.height ?? width * 9 / 16 + 40)
      .clamp(220.0, 480.0)
      .clamp(1.0, screen.height);
  final left = (remembered?.left ?? screen.right - width - 20).clamp(
    screen.left,
    screen.right - width,
  );
  final top = (remembered?.top ?? screen.bottom - height - 20).clamp(
    screen.top,
    screen.bottom - height,
  );
  return Rect.fromLTWH(left, top, width, height);
}
