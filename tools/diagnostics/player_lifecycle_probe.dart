import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitType;

import 'package:clubtivi/app/desktop_app_lifecycle.dart';
import 'package:clubtivi/core/app_diagnostics.dart';
import 'package:clubtivi/core/desktop_app_exit.dart';
import 'package:clubtivi/core/player_resources.dart';
import 'package:clubtivi/features/player/player_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit/src/player/native/player/real.dart' as native;
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';

// Isolated real-decoder regression. Never opens BobTV's catalogue, updater,
// favourites or normal diagnostic directory, and never targets another PID.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final directory = Directory(Platform.environment['BOBTV_LIFECYCLE_REPORT']!);
  await directory.create(recursive: true);
  final report = File('${directory.path}/probe.jsonl');
  void record(String event, [Map<String, Object?> fields = const {}]) {
    report.writeAsStringSync(
      '${jsonEncode({'time': DateTime.now().toUtc().toIso8601String(), 'event': event, 'pid': pid, ...fields})}\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  await AppDiagnostics.instance.initialize(
    directoryOverride: Directory('${directory.path}/diagnostics'),
  );
  FlutterError.onError = (details) {
    record('flutter_error', {'error': details.exception.toString()});
  };
  await windowManager.ensureInitialized();
  await windowManager.setPreventClose(true);
  await windowManager.setTitle('BobTV 清理回归测试，请暂时保留');
  final visible = ValueNotifier<VideoController?>(null);
  final preview = ValueNotifier<VideoController?>(null);
  final media = Platform.environment['BOBTV_LIFECYCLE_MEDIA']!;
  final seconds = int.parse(
    Platform.environment['BOBTV_LIFECYCLE_SECONDS'] ?? '600',
  );
  final cycles = int.parse(
    Platform.environment['BOBTV_LIFECYCLE_CYCLES'] ?? '20',
  );
  final mode = Platform.environment['BOBTV_LIFECYCLE_EXIT'] ?? 'native_close';
  final hiddenIdle =
      Platform.isMacOS &&
      Platform.environment['BOBTV_LIFECYCLE_IDLE_HIDDEN'] == '1';
  final service = Platform.environment['BOBTV_LIFECYCLE_SERVICE'] == '1'
      ? PlayerService()
      : null;
  final container = ProviderContainer(
    overrides: [
      if (service != null) playerServiceProvider.overrideWithValue(service),
    ],
  );
  if (service != null) container.read(playerServiceProvider);
  runApp(
    UncontrolledProviderScope(
      container: container,
      child: DesktopAppLifecycle(
        child: MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                Positioned.fill(
                  child: ValueListenableBuilder<VideoController?>(
                    valueListenable: visible,
                    builder: (_, controller, __) => controller == null
                        ? const SizedBox()
                        : Video(
                            key: ValueKey(controller),
                            controller: controller,
                            controls: NoVideoControls,
                            pauseUponEnteringBackgroundMode: false,
                          ),
                  ),
                ),
                Positioned(
                  right: 12,
                  bottom: 12,
                  width: 180,
                  height: 100,
                  child: ValueListenableBuilder<VideoController?>(
                    valueListenable: preview,
                    builder: (_, controller, __) => controller == null
                        ? const SizedBox()
                        : Video(
                            key: ValueKey(controller),
                            controller: controller,
                            controls: NoVideoControls,
                            pauseUponEnteringBackgroundMode: false,
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await WidgetsBinding.instance.endOfFrame;
  try {
    Future<Player> create(
      String role,
      ValueNotifier<VideoController?> slot,
      bool hardware,
    ) async {
      final usingService = role == 'probe_main' && service != null;
      final player = usingService
          ? service.player
          : ManagedPlayer(
              role: role,
              configuration: const PlayerConfiguration(
                logLevel: MPVLogLevel.error,
              ),
            );
      slot.value = usingService
          ? service.videoController
          : VideoController(
              player,
              configuration: VideoControllerConfiguration(
                enableHardwareAcceleration: hardware,
              ),
            );
      await WidgetsBinding.instance.endOfFrame;
      if (usingService) {
        final readyLimit = DateTime.now().add(const Duration(seconds: 15));
        bool serviceReady() => Directory('${directory.path}/diagnostics')
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.log'))
            .any(
              (f) => f.readAsStringSync().contains('"event":"player_ready"'),
            );
        while (!serviceReady() && DateTime.now().isBefore(readyLimit)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        if (!serviceReady())
          throw StateError('PlayerService initialization failed');
        record('production_player_service_ready');
      }
      await (player.platform as native.NativePlayer).setProperty('ao', 'null');
      await player.setVolume(0);
      await player.setPlaylistMode(PlaylistMode.loop);
      await player.open(Media(media)).timeout(const Duration(seconds: 20));
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while ((player.state.width ?? 0) == 0 &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      if ((player.state.width ?? 0) == 0)
        throw StateError('No decoded video frame');
      record('decoder_ready', {
        'role': role,
        'hardwareRequested': hardware,
        'hwdec': await (player.platform as native.NativePlayer).getProperty(
          'hwdec-current',
        ),
        'width': player.state.width,
        'height': player.state.height,
      });
      return player;
    }

    final mainPlayer = await create('probe_main', visible, true);
    final errors = <String>[];
    final mainErrors = mainPlayer.stream.error.listen(errors.add);
    for (var i = 0; i < cycles; i++) {
      final candidate = await create('probe_preview_$i', preview, i.isEven);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      preview.value = null;
      await WidgetsBinding.instance.endOfFrame;
      // Duplicate callers share one native cleanup transaction.
      await Future.wait([
        candidate.dispose(),
        candidate.dispose(),
      ]).timeout(const Duration(seconds: 20));
      record('preview_cycle_passed', {
        'cycle': i,
        'resources': PlayerResourceRegistry.instance.resourceCount,
      });
    }
    final second = await create('probe_idle_preview', preview, false);
    final secondaryErrors = second.stream.error.listen(errors.add);
    Future<void> enterFullscreen() async {
      await windowManager.setFullScreen(true);
      final limit = DateTime.now().add(const Duration(seconds: 5));
      while (!await windowManager.isFullScreen() &&
          DateTime.now().isBefore(limit)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      if (!await windowManager.isFullScreen())
        throw StateError('Native fullscreen transition failed');
    }

    if (mode == 'native_close' && !hiddenIdle) await enterFullscreen();
    if (hiddenIdle) await windowManager.hide();
    record('idle_started', {
      'seconds': seconds,
      'mode': mode,
      'resources': PlayerResourceRegistry.instance.resourceCount,
    });
    var positionChanges = 0,
        secondaryChanges = 0,
        videoSamples = 0,
        audioSamples = 0;
    var last = Duration.zero, secondaryLast = Duration.zero;
    final memory = <int>[];
    for (var elapsed = 0; elapsed < seconds; elapsed++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      if (DesktopAppExit.controller!.closing.value) {
        record('interrupted_by_native_close');
        // Preserve the evidence as an interrupted test while allowing the
        // production cleanup barrier to finish. Do not abort it mid-drain.
        await Future<void>.delayed(const Duration(seconds: 30));
        throw StateError('Unexpected idle exit did not finish cleanup');
      }
      if (mainPlayer.state.position != last) positionChanges++;
      if (second.state.position != secondaryLast) secondaryChanges++;
      last = mainPlayer.state.position;
      secondaryLast = second.state.position;
      if ((mainPlayer.state.width ?? 0) > 0 && (second.state.width ?? 0) > 0)
        videoSamples++;
      if (mainPlayer.state.tracks.audio.any(
            (t) => t.id != 'auto' && t.id != 'no',
          ) &&
          second.state.tracks.audio.any((t) => t.id != 'auto' && t.id != 'no'))
        audioSamples++;
      if (elapsed >= 30) memory.add(ProcessInfo.currentRss);
      if (elapsed % 30 == 0)
        record('idle_heartbeat', {
          'elapsed': elapsed,
          'positionChanges': positionChanges,
          'secondaryChanges': secondaryChanges,
          'rss': ProcessInfo.currentRss,
          'errors': errors.length,
        });
    }
    if (positionChanges < seconds * .7 ||
        secondaryChanges < seconds * .7 ||
        videoSamples < seconds * .7 ||
        audioSamples < seconds * .7 ||
        errors.isNotEmpty) {
      throw StateError(
        'Playback coverage/error failure: $positionChanges/$secondaryChanges/$videoSamples/$audioSamples $errors',
      );
    }
    int median(List<int> values) {
      final v = [...values]..sort();
      return v[v.length ~/ 2];
    }

    final growth = memory.length < 60
        ? 0
        : median(memory.sublist(memory.length - 30)) -
              median(memory.take(30).toList());
    if (growth > 128 * 1024 * 1024)
      throw StateError('Sustained RSS growth $growth');
    await mainErrors.cancel();
    await secondaryErrors.cancel();
    record('idle_passed', {
      'seconds': seconds,
      'positionChanges': positionChanges,
      'secondaryChanges': secondaryChanges,
      'videoSamples': videoSamples,
      'audioSamples': audioSamples,
      'rssGrowth': growth,
    });
    if (mode == 'native_close' && hiddenIdle) {
      await windowManager.show();
      await enterFullscreen();
    }
    record('expected_close_requested', {
      'mode': mode,
      'resources': PlayerResourceRegistry.instance.resourceCount,
    });
    if (mode == 'native_close') {
      await windowManager.close();
    } else if (mode == 'platform_exit') {
      await ServicesBinding.instance.exitApplication(AppExitType.cancelable);
    } else {
      await DesktopAppExit.request('probe_explicit_exit');
    }
  } catch (error, stack) {
    record('failed', {'error': error.toString(), 'stack': stack.toString()});
    // A failed fixture remains distinguishable from a successful native exit.
    exit(2);
  }
}
