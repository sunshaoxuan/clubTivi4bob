import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';
import 'app_diagnostics.dart';
import 'desktop_window_geometry.dart';

/// One ordinary-window policy. Maximization, fullscreen and PiP are exempt.
class DesktopWindowSizing with WindowListener, ScreenListener {
  DesktopWindowSizing({bool? isWindows, double Function()? pixelRatio})
    : _isWindows = isWindows ?? Platform.isWindows,
      _pixelRatio = pixelRatio ?? windowManager.getDevicePixelRatio;
  static final instance = DesktopWindowSizing();
  final bool _isWindows;
  final double Function() _pixelRatio;
  Timer? _timer;
  bool _started = false;
  bool _busy = false;
  bool _again = false;
  int _suspended = 0;
  int _generation = 0;
  Size? _minimumApplied;

  Future<Rect> constrain(
    Rect requested, {
    Size minimum = const Size(800, 500),
  }) async {
    final ratio = _pixelRatio();
    final scale = ratio.isFinite && ratio > 0 ? ratio : 1.0;
    final areas = <Rect>[];
    try {
      for (final display in await screenRetriever.getAllDisplays().timeout(
        const Duration(seconds: 2),
      )) {
        final area =
            (display.visiblePosition ?? Offset.zero) &
            (display.visibleSize ?? display.size);
        // Windows monitor coordinates are divided by each monitor's own DPI,
        // while GetWindowRect is divided by the current window's DPI.
        final monitorScale = display.scaleFactor?.toDouble() ?? scale;
        final factor = _isWindows ? monitorScale / scale : 1.0;
        areas.add(
          Rect.fromLTWH(
            area.left * factor,
            area.top * factor,
            area.width * factor,
            area.height * factor,
          ),
        );
      }
    } catch (_) {
      // Keep the physical cap even if the display API is briefly unavailable.
    }
    return boundedDesktopWindowBounds(
      requested,
      areas,
      pixelRatio: scale,
      minimum: minimum,
    );
  }

  Future<void> restoreMinimumSize(
    Rect reference, {
    bool onlyIfChanged = false,
  }) async {
    final minimum = await constrain(
      Rect.fromLTWH(reference.left, reference.top, 800, 500),
      minimum: Size.zero,
    );
    if (onlyIfChanged && _minimumApplied == minimum.size) return;
    await windowManager.setMinimumSize(minimum.size);
    _minimumApplied = minimum.size;
  }

  Future<void> start() async {
    if (_started) return;
    _started = true;
    await normalize(initial: true);
    windowManager.addListener(this);
    screenRetriever.addListener(this);
  }

  void dispose() {
    if (!_started) return;
    _started = false;
    ++_generation;
    _minimumApplied = null;
    _timer?.cancel();
    windowManager.removeListener(this);
    screenRetriever.removeListener(this);
  }

  /// Native presentation transitions temporarily own geometry. Leases nest so
  /// PiP and fullscreen cannot accidentally resume each other's resize work.
  void Function() suspend() {
    ++_suspended;
    ++_generation;
    _minimumApplied = null;
    _timer?.cancel();
    var released = false;
    return () {
      if (released) return;
      released = true;
      --_suspended;
      _schedule();
    };
  }

  void _schedule() {
    if (!_started || _suspended > 0) return;
    _timer?.cancel();
    _timer = Timer(
      const Duration(milliseconds: 180),
      () => unawaited(normalize()),
    );
  }

  Future<void> normalize({bool initial = false}) async {
    if (_suspended > 0 || !_started) return;
    if (_busy) {
      _again = true;
      return;
    }
    _busy = true;
    final generation = _generation;
    try {
      if (await windowManager.isFullScreen() ||
          await windowManager.isMinimized()) {
        return;
      }
      if (await windowManager.isMaximized()) {
        if (!initial) return;
        await windowManager.unmaximize();
      }
      final current = await windowManager.getBounds();
      final requested = initial
          ? Rect.fromLTWH(current.left, current.top, 1000, 650)
          : current;
      final bounds = await constrain(requested);
      if (_suspended > 0 ||
          generation != _generation ||
          !_started ||
          await windowManager.isFullScreen() ||
          await windowManager.isMinimized() ||
          await windowManager.isMaximized()) {
        return;
      }
      await restoreMinimumSize(bounds, onlyIfChanged: true);
      if (_suspended > 0 ||
          generation != _generation ||
          !_started ||
          await windowManager.isFullScreen() ||
          await windowManager.isMinimized() ||
          await windowManager.isMaximized()) {
        return;
      }
      if (bounds != current) {
        await windowManager.setBounds(bounds);
        AppDiagnostics.instance.log('ordinary_window_bounds_adjusted', {
          'initial': initial,
          'width': bounds.width,
          'height': bounds.height,
          'pixelRatio': _pixelRatio(),
        });
      }
    } catch (error, stack) {
      AppDiagnostics.instance.recordError(
        'ordinary_window_bounds',
        error,
        stack,
      );
    } finally {
      _busy = false;
      if (_again) {
        _again = false;
        _schedule();
      }
    }
  }

  @override
  void onWindowRestore() => _schedule();
  @override
  void onWindowUnmaximize() => _schedule();
  @override
  void onWindowResized() => _schedule();
  @override
  void onWindowMoved() => _schedule();
  @override
  void onWindowLeaveFullScreen() => _schedule();
  @override
  void onScreenEvent(String eventName) => _schedule();
}
