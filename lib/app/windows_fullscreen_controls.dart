import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../features/player/windows_window_chrome.dart';
import '../features/player/desktop_fullscreen_session.dart';
import '../core/desktop_app_exit.dart';

/// Mouse-accessible window chrome across every Windows fullscreen route.
/// macOS continues to use its native, edge-reveal titlebar.
class WindowsFullscreenControls extends StatefulWidget {
  const WindowsFullscreenControls({
    super.key,
    required this.child,
    this.enabled,
  });
  final Widget child;
  final bool? enabled;

  @override
  State<WindowsFullscreenControls> createState() =>
      _WindowsFullscreenControlsState();
}

class _WindowsFullscreenControlsState extends State<WindowsFullscreenControls>
    with WindowListener {
  bool _fullscreen = false;
  bool _hovered = false;
  bool _shown = false;
  Timer? _hide;
  bool _restoring = false;
  int _stateReadGeneration = 0;
  bool get _enabled => widget.enabled ?? Platform.isWindows;

  @override
  void initState() {
    super.initState();
    if (_enabled) {
      windowManager.addListener(this);
      unawaited(_readState());
    }
  }

  Future<void> _readState() async {
    final generation = ++_stateReadGeneration;
    final value = await windowManager.isFullScreen();
    if (mounted && generation == _stateReadGeneration && value != _fullscreen) {
      _changed(value);
    }
  }

  void _changed(bool value) {
    _hide?.cancel();
    setState(() {
      _fullscreen = value;
      _shown = value;
      _hovered = false;
    });
    if (value) {
      _hide = Timer(const Duration(seconds: 2), () {
        if (mounted && !_hovered) setState(() => _shown = false);
      });
    }
  }

  @override
  void onWindowEnterFullScreen() {
    ++_stateReadGeneration;
    _changed(true);
  }

  @override
  void onWindowLeaveFullScreen() {
    ++_stateReadGeneration;
    _changed(false);
  }

  @override
  void onWindowResize() => unawaited(_readState());

  @override
  void onWindowFocus() => unawaited(_readState());

  Future<void> _restoreWindow() async {
    if (_restoring) return;
    _restoring = true;
    try {
      if (await DesktopFullscreenSession.restoreActiveWindow()) {
        if (mounted) await _readState();
        return;
      }
      await windowManager.setAlwaysOnTop(false);
      await windowManager.setFullScreen(false);
      await restoreWindowsWindowChrome();
      // Windows may not emit a leave event when the previous placement was
      // maximized. Read the native flag after restoration instead of waiting.
      if (mounted) await _readState();
    } finally {
      _restoring = false;
    }
  }

  @override
  void dispose() {
    _hide?.cancel();
    if (_enabled) windowManager.removeListener(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_enabled) return widget.child;
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (_fullscreen)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: MouseRegion(
              key: const ValueKey('windows-fullscreen-edge'),
              cursor: SystemMouseCursors.basic,
              onEnter: (_) {
                _hide?.cancel();
                setState(() {
                  _hovered = true;
                  _shown = true;
                });
              },
              onExit: (_) {
                _hovered = false;
                _hide?.cancel();
                _hide = Timer(const Duration(milliseconds: 400), () {
                  if (mounted && !_hovered) setState(() => _shown = false);
                });
              },
              child: SizedBox(
                height: _shown ? 44 : 12,
                child: _shown
                    ? Material(
                        color: const Color(0xF2182030),
                        elevation: 8,
                        child: Row(
                          children: [
                            const SizedBox(width: 16),
                            const Expanded(
                              child: Text(
                                'BobTV',
                                style: TextStyle(color: Colors.white70),
                              ),
                            ),
                            IconButton(
                              tooltip: '最小化',
                              icon: const Icon(Icons.remove),
                              onPressed: windowManager.minimize,
                            ),
                            IconButton(
                              tooltip: '恢复窗口',
                              icon: const Icon(
                                Icons.filter_none_rounded,
                                size: 18,
                              ),
                              onPressed: _restoreWindow,
                            ),
                            IconButton(
                              tooltip: '关闭 BobTV',
                              icon: const Icon(Icons.close),
                              onPressed: () => DesktopAppExit.request(
                                'windows_fullscreen_close',
                              ),
                            ),
                          ],
                        ),
                      )
                    : const SizedBox.expand(),
              ),
            ),
          ),
      ],
    );
  }
}
