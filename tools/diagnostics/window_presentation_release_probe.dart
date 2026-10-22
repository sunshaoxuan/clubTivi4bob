// Tests only this fixture's window. No media, user catalogue or preferences.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'package:clubtivi/core/app_diagnostics.dart';
import 'package:clubtivi/core/desktop_window_pin.dart';
import 'package:clubtivi/features/player/player_presentation_buttons.dart';
import 'package:clubtivi/features/player/window_manager_fullscreen_backend.dart';
import 'package:clubtivi/features/player/window_playback_session.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  final output = File(Platform.environment['BOBTV_WINDOW_QA_REPORT']!);
  await output.parent.create(recursive: true);
  await AppDiagnostics.instance.initialize(
    directoryOverride: Directory('${output.parent.path}/diagnostics'),
  );
  final surface = GlobalKey();
  final events = <Map<String, Object?>>[];
  var backendCreations = 0;
  final pin = DesktopWindowPin.instance;
  final session = WindowPlaybackSession(
    createBackend: () {
      backendCreations++;
      return WindowManagerFullscreenBackend();
    },
    onChanged: (value) => events.add({'fullscreen': value}),
  );
  void require(bool condition, String message) {
    if (!condition) throw StateError(message);
  }

  bool near(Rect a, Rect b) =>
      (a.left - b.left).abs() <= 3 &&
      (a.top - b.top).abs() <= 3 &&
      (a.width - b.width).abs() <= 3 &&
      (a.height - b.height).abs() <= 3;
  var passed = false;
  Object? failure;
  try {
    await windowManager.setTitle('BobTV 1.1.9 window fixture $pid');
    await windowManager.setFullScreen(false);
    await windowManager.setAlwaysOnTop(false);
    await windowManager.setSize(const Size(900, 600));
    runApp(
      MaterialApp(
        home: Scaffold(
          body: SizedBox.expand(
            key: surface,
            child: ColoredBox(
              color: const Color(0xFF14243B),
              child: Center(
                child: PlayerPresentationButtons(
                  showWindowPin: true,
                  onWindowPlayback: () {},
                  onFullscreen: () {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await windowManager.show();
    await windowManager.focus();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final initial = await windowManager.getBounds();
    final context = surface.currentContext!;
    final size = (context.findRenderObject()! as RenderBox).size;
    require(
      size == MediaQuery.sizeOf(context),
      'Client surface does not fill window',
    );
    require(
      !await windowManager.isFullScreen(),
      'Ordinary presentation entered fullscreen',
    );
    require(
      backendCreations == 0,
      'Ordinary presentation created native fullscreen backend',
    );
    events.add({
      'windowSurfaceWidth': size.width,
      'windowSurfaceHeight': size.height,
    });
    await pin.toggle();
    require(
      pin.pinned && await windowManager.isAlwaysOnTop(),
      'Pin was not applied',
    );
    for (var cycle = 0; cycle < 2; cycle++) {
      await session.enterFullscreen();
      require(
        await windowManager.isFullScreen(),
        'Fullscreen entry not applied',
      );
      require(!pin.canToggle, 'Pin remains writable during fullscreen');
      await session.exitFullscreen();
      require(
        !await windowManager.isFullScreen(),
        'Fullscreen exit not applied',
      );
      require(
        await windowManager.isAlwaysOnTop() == pin.pinned,
        'Pin preference not restored',
      );
      require(
        near(initial, await windowManager.getBounds()),
        'Window geometry not restored',
      );
      events.add({
        'cycle': cycle,
        'pinRestored': pin.pinned,
        'geometryRestored': true,
      });
      if (cycle == 0) {
        await pin.toggle();
        require(
          !pin.pinned && !await windowManager.isAlwaysOnTop(),
          'Unpin failed',
        );
      }
    }
    require(
      backendCreations == 2,
      'Fullscreen sessions did not capture fresh geometry',
    );
    passed = true;
  } catch (error) {
    failure = error;
  } finally {
    try {
      await session.exitFullscreen();
      await windowManager.setAlwaysOnTop(false);
    } catch (_) {}
    session.dispose();
    pin.dispose();
    await output.writeAsString(
      jsonEncode({
        'passed': passed,
        'platform': Platform.operatingSystem,
        'checkedAtUtc': DateTime.now().toUtc().toIso8601String(),
        'pid': pid,
        'events': events,
        'mediaOpened': false,
        'audioProduced': false,
        'installedAppsModified': false,
        if (failure != null) 'error': failure.toString(),
      }),
    );
    exit(passed ? 0 : 1);
  }
}
