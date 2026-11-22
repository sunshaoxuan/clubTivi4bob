// Own-window Windows presentation regression. No user catalogue is opened.
// Launch with an isolated LOCALAPPDATA: the native runner's update bootstrap
// executes before this Dart entry point, even for a diagnostic target.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi' hide Size;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit/src/player/native/player/real.dart' as native;
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';

import 'package:clubtivi/core/app_diagnostics.dart';
import 'package:clubtivi/core/player_resources.dart';
import 'package:clubtivi/features/player/player_service.dart';

class _OwnWindowPixels {
  _OwnWindowPixels() {
    final user = DynamicLibrary.open('user32.dll');
    final gdi = DynamicLibrary.open('gdi32.dll');
    _find = user
        .lookupFunction<
          IntPtr Function(Pointer<Utf16>, Pointer<Utf16>),
          int Function(Pointer<Utf16>, Pointer<Utf16>)
        >('FindWindowW');
    _foreground = user.lookupFunction<IntPtr Function(), int Function()>(
      'GetForegroundWindow',
    );
    _getDC = user.lookupFunction<IntPtr Function(IntPtr), int Function(int)>(
      'GetDC',
    );
    _releaseDC = user
        .lookupFunction<Int32 Function(IntPtr, IntPtr), int Function(int, int)>(
          'ReleaseDC',
        );
    _pixel = gdi
        .lookupFunction<
          Uint32 Function(IntPtr, Int32, Int32),
          int Function(int, int, int)
        >('GetPixel');
  }
  late final int Function(Pointer<Utf16>, Pointer<Utf16>) _find;
  late final int Function() _foreground;
  late final int Function(int) _getDC;
  late final int Function(int, int) _releaseDC;
  late final int Function(int, int, int) _pixel;

  List<int> sample() {
    final title = 'BobTV presentation fixture $pid'.toNativeUtf16();
    final int hwnd;
    try {
      hwnd = _find(nullptr, title);
    } finally {
      calloc.free(title);
    }
    if (hwnd == 0 || hwnd != _foreground()) {
      throw StateError(
        'Only the foreground fixture window may be sampled '
        '(fixture=$hwnd, foreground=${_foreground()})',
      );
    }
    final dc = _getDC(hwnd);
    if (dc == 0) throw StateError('Fixture client capture unavailable');
    try {
      final color = _pixel(dc, 180, 150);
      if (color == 0xffffffff) throw StateError('Fixture pixel unavailable');
      return [color & 255, (color >> 8) & 255, (color >> 16) & 255];
    } finally {
      _releaseDC(hwnd, dc);
    }
  }

  bool get foreground {
    final title = 'BobTV presentation fixture $pid'.toNativeUtf16();
    try {
      final hwnd = _find(nullptr, title);
      return hwnd != 0 && hwnd == _foreground();
    } finally {
      calloc.free(title);
    }
  }
}

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await windowManager.ensureInitialized();
  final root = Directory(Platform.environment['BOBTV_PRESENTATION_REPORT']!);
  await root.create(recursive: true);
  await AppDiagnostics.instance.initialize(
    directoryOverride: Directory('${root.path}/diagnostics'),
  );
  final events = File('${root.path}/presentation.jsonl');
  void record(String event, Map<String, Object?> fields) {
    events.writeAsStringSync(
      '${jsonEncode({'time': DateTime.now().toUtc().toIso8601String(), 'event': event, 'pid': pid, ...fields})}\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  final responsiveness = Stopwatch()..start();
  var lastTick = 0;
  var maxEventLoopGapMs = 0;
  final heartbeat = Timer.periodic(const Duration(milliseconds: 20), (_) {
    final now = responsiveness.elapsedMilliseconds;
    final gap = now - lastTick;
    if (gap > maxEventLoopGapMs) maxEventLoopGapMs = gap;
    lastTick = now;
  });
  FlutterError.onError = (details) =>
      record('flutter_error', {'error': details.exception.toString()});
  record('fixture_started', {'installedAppsChanged': false});
  final service = PlayerService();
  final initial = service.videoController;
  final visible = ValueNotifier<bool>(true);
  await windowManager.setTitle('BobTV presentation fixture $pid');
  await windowManager.setSize(const Size(800, 500));
  runApp(
    MaterialApp(
      title: 'BobTV presentation fixture $pid',
      home: Scaffold(
        backgroundColor: Colors.black,
        body: ValueListenableBuilder<bool>(
          valueListenable: visible,
          builder: (_, show, _) => !show
              ? const SizedBox.shrink()
              : Stack(
                  fit: StackFit.expand,
                  children: [
                    ValueListenableBuilder<VideoController?>(
                      valueListenable: service.activeVideoController,
                      builder: (_, controller, _) => Video(
                        key: ValueKey(controller ?? initial),
                        controller: controller ?? initial,
                        controls: NoVideoControls,
                        fit: BoxFit.fill,
                        pauseUponEnteringBackgroundMode: false,
                      ),
                    ),
                    Positioned(
                      right: 12,
                      bottom: 12,
                      width: 160,
                      height: 90,
                      child: ValueListenableBuilder<VideoController?>(
                        valueListenable: service.previewVideoController,
                        builder: (_, controller, _) => controller == null
                            ? const SizedBox.shrink()
                            : Video(
                                key: ValueKey(controller),
                                controller: controller,
                                controls: NoVideoControls,
                                pauseUponEnteringBackgroundMode: false,
                              ),
                      ),
                    ),
                    Positioned(
                      left: 12,
                      bottom: 12,
                      child: ValueListenableBuilder<bool>(
                        valueListenable: service.channelSwitching,
                        builder: (_, preparing, _) => preparing
                            ? const CircularProgressIndicator()
                            : const SizedBox.shrink(),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    ),
  );
  await windowManager.show();
  await windowManager.focus();
  await WidgetsBinding.instance.endOfFrame;
  await (service.player.platform as native.NativePlayer).setProperty(
    'ao',
    'null',
  );
  final pixels = _OwnWindowPixels();
  Future<int> untilColor(bool green, Stopwatch watch) async {
    while (watch.elapsed < const Duration(seconds: 10)) {
      // Window activation and the first native frame can finish after show().
      // Allow startup to settle without sampling another application's pixels.
      if (!pixels.foreground && watch.elapsed < const Duration(seconds: 3)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        continue;
      }
      final rgb = pixels.sample();
      if (green
          ? rgb[1] > 100 && rgb[1] > rgb[0] * 2 && rgb[1] > rgb[2] * 2
          : rgb[0] > 100 && rgb[0] > rgb[1] * 2 && rgb[0] > rgb[2] * 2) {
        return watch.elapsedMicroseconds;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    throw StateError('Expected fixture video pixels were not presented');
  }

  try {
    await service.play(
      Platform.environment['BOBTV_PRESENTATION_RED']!,
      channelId: 'fixture-red',
    );
    await untilColor(false, Stopwatch()..start());
    record('initial_picture_verified', {'rgb': pixels.sample()});
    for (var cycle = 0; cycle < 6; cycle++) {
      final green = cycle.isEven;
      final media =
          Platform.environment[green
              ? 'BOBTV_PRESENTATION_GREEN'
              : 'BOBTV_PRESENTATION_RED']!;
      final channelId = 'fixture-$cycle';
      final ready = await service.switchChannel(
        media,
        channelId: channelId,
        previewOnly: true,
        onlyRequestedRoute: true,
      );
      final controller = service.previewVideoController.value;
      if (!ready || controller == null) throw StateError('Preview not ready');
      await (controller.player.platform as native.NativePlayer).setProperty(
        'ao',
        'null',
      );
      await WidgetsBinding.instance.endOfFrame;
      await Future<void>.delayed(const Duration(milliseconds: 150));
      // Simulate another decoder waiting for native stop/disposal while this
      // already-decoded preview is promoted. The shared SDK lock must not be
      // part of the handoff's volume-control path.
      final acquired = Completer<void>();
      final release = Completer<void>();
      final contended = cycle == 2;
      final held = contended
          ? native.NativePlayer.lock.synchronized(() async {
              acquired.complete();
              await release.future;
            })
          : Future<void>.value();
      if (contended) await acquired.future;
      final watch = Stopwatch()..start();
      late final bool committed;
      late final int logicalUs;
      try {
        committed = await service.commitPreparedChannel(channelId);
        logicalUs = watch.elapsedMicroseconds;
      } finally {
        if (contended) release.complete();
        await held;
      }
      if (!committed || !identical(service.videoController, controller)) {
        record('handoff_failed', {
          'cycle': cycle,
          'logicalMicroseconds': logicalUs,
          'unrelatedNativeLockHeld': contended,
        });
        throw StateError('Preview was not reused');
      }
      final visibleUs = await untilColor(green, watch);
      record('picture_handoff', {
        'cycle': cycle,
        'logicalMicroseconds': logicalUs,
        'visibleMicroseconds': visibleUs,
        'rgb': pixels.sample(),
        'sameController': identical(service.videoController, controller),
        'unrelatedNativeLockHeld': contended,
        'localFixtureOnly': true,
        'audibleContinuityTested': false,
      });
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    visible.value = false;
    await WidgetsBinding.instance.endOfFrame;
    await service.dispose();
    await PlayerResourceRegistry.instance.disposeAll();
    heartbeat.cancel();
    record('completed', {
      'resources': PlayerResourceRegistry.instance.resourceCount,
      'passed': true,
      'installedAppsChanged': false,
      'maxEventLoopGapMs': maxEventLoopGapMs,
      'cleanupIncludesNativeTermination':
          Platform.environment['BOBTV_PRESENTATION_TRACKS_NATIVE'] == '1',
    });
    exit(0);
  } catch (error, stack) {
    record('failed', {'error': error.toString(), 'stack': stack.toString()});
    visible.value = false;
    await WidgetsBinding.instance.endOfFrame;
    await service.dispose();
    await PlayerResourceRegistry.instance.disposeAll();
    heartbeat.cancel();
    exit(2);
  }
}
