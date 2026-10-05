import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:screen_retriever/screen_retriever.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'desktop_fullscreen_session.dart';
import 'desktop_pip_session.dart';

class WindowManagerPipBackend implements DesktopPipBackend {
  WindowManagerPipBackend({bool? isMacOS})
    : _isMacOS = isMacOS ?? Platform.isMacOS;
  final bool _isMacOS;
  static const _boundsKey = 'desktop_pip_bounds_v1';
  bool _allWorkspaces = false;
  bool _resizable = true;

  @override
  Future<FullscreenWindowSnapshot> capture() async {
    _resizable = await windowManager.isResizable();
    if (_isMacOS) {
      _allWorkspaces = await windowManager.isVisibleOnAllWorkspaces();
    }
    return FullscreenWindowSnapshot(
      bounds: await windowManager.getBounds(),
      maximized: await windowManager.isMaximized(),
      alwaysOnTop: await windowManager.isAlwaysOnTop(),
    );
  }

  @override
  Future<void> compact() async {
    final displays = await screenRetriever.getAllDisplays();
    final areas = displays
        .map(
          (display) =>
              (display.visiblePosition ?? Offset.zero) &
              (display.visibleSize ?? display.size),
        )
        .where((area) => !area.isEmpty)
        .toList();
    Rect? saved;
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_boundsKey);
      if (raw != null) {
        final values = (jsonDecode(raw) as List).cast<num>();
        if (values.length == 4 && values.every((value) => value.isFinite)) {
          saved = Rect.fromLTWH(
            values[0].toDouble(),
            values[1].toDouble(),
            values[2].toDouble(),
            values[3].toDouble(),
          );
        }
      }
    } catch (_) {
      /* Invalid preferences fall back to the current display. */
    }
    final bounds = desktopPipBounds(
      areas,
      await windowManager.getBounds(),
      remembered: saved,
    );
    await windowManager.unmaximize();
    await windowManager.setMinimumSize(const Size(320, 220));
    await windowManager.setTitleBarStyle(
      TitleBarStyle.hidden,
      windowButtonVisibility: false,
    );
    await windowManager.setResizable(true);
    await windowManager.setBounds(bounds);
    await windowManager.setAlwaysOnTop(true);
    if (_isMacOS) {
      await windowManager.setVisibleOnAllWorkspaces(
        true,
        visibleOnFullScreen: true,
      );
    }
    await windowManager.show();
  }

  @override
  Future<void> rememberBounds() async {
    final bounds = await windowManager.getBounds();
    await (await SharedPreferences.getInstance()).setString(
      _boundsKey,
      jsonEncode([bounds.left, bounds.top, bounds.width, bounds.height]),
    );
  }

  @override
  Future<void> restore(FullscreenWindowSnapshot snapshot) async {
    if (_isMacOS) {
      await windowManager.setVisibleOnAllWorkspaces(_allWorkspaces);
    }
    await windowManager.setTitleBarStyle(
      TitleBarStyle.normal,
      windowButtonVisibility: true,
    );
    await windowManager.setMinimumSize(
      _isMacOS ? const Size(800, 500) : Size.zero,
    );
    await windowManager.setResizable(_resizable);
    await windowManager.setAlwaysOnTop(snapshot.alwaysOnTop);
    await windowManager.setBounds(snapshot.bounds);
    if (snapshot.maximized) await windowManager.maximize();
  }
}
