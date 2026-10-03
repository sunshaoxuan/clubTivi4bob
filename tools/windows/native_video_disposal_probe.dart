import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

// Isolated native regression runner. It does not load BobTV settings or data.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final file = File(Platform.environment['BOBTV_NATIVE_DISPOSAL_LOG']!);
  void record(String text) =>
      file.writeAsStringSync('$text\n', mode: FileMode.append, flush: true);
  final media = Platform.environment['BOBTV_NATIVE_DISPOSAL_MEDIA']!;
  final visible = ValueNotifier<VideoController?>(null);
  final preview = ValueNotifier<VideoController?>(null);
  runApp(
    MaterialApp(
      home: ValueListenableBuilder<VideoController?>(
        valueListenable: visible,
        builder: (_, controller, __) => controller == null
            ? const ColoredBox(color: Colors.black)
            : ValueListenableBuilder<VideoController?>(
                valueListenable: preview,
                builder: (_, secondary, __) => Stack(
                  children: [
                    Positioned.fill(
                      child: Video(
                        key: ValueKey(controller),
                        controller: controller,
                        controls: NoVideoControls,
                      ),
                    ),
                    if (secondary != null)
                      Positioned(
                        right: 20,
                        bottom: 20,
                        width: 240,
                        height: 135,
                        child: Video(
                          key: ValueKey(secondary),
                          controller: secondary,
                          controls: NoVideoControls,
                        ),
                      ),
                  ],
                ),
              ),
      ),
    ),
  );
  try {
    const channel = MethodChannel('com.alexmercerind/media_kit_video');
    for (var cycle = 0; cycle < 30; cycle++) {
      final player = Player(
        configuration: const PlayerConfiguration(logLevel: MPVLogLevel.error),
      );
      final controller = VideoController(
        player,
        configuration: VideoControllerConfiguration(
          // GitHub's virtual Mac runners do not expose an accelerated CGL
          // pixel format. Exercise the software-to-Metal path there; Windows
          // still alternates both native texture backends.
          enableHardwareAcceleration: !Platform.isMacOS && cycle.isEven,
        ),
      );
      await player.setVolume(0);
      visible.value = controller;
      await player.open(Media(media));
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while ((player.state.width ?? 0) == 0 &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      if ((player.state.width ?? 0) == 0)
        throw StateError('No decoded fixture frame');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      visible.value = null;
      await WidgetsBinding.instance.endOfFrame;
      if (cycle % 3 == 0) {
        final handle = await player.handle;
        await Future.wait([
          channel.invokeMethod('VideoOutputManager.Dispose', {
            'handle': '$handle',
          }),
          channel.invokeMethod('VideoOutputManager.Dispose', {
            'handle': '$handle',
          }),
        ]).timeout(const Duration(seconds: 25));
      }
      await player.dispose().timeout(const Duration(seconds: 25));
      record(
        'disposed cycle=$cycle hardware=${!Platform.isMacOS && cycle.isEven}',
      );
    }
    // media_kit destroys native cores five seconds after Player.dispose.
    await Future<void>.delayed(const Duration(seconds: 7));
    record(
      'PASS: 30 real video create/render/dispose cycles, including duplicate releases',
    );
    final seconds =
        int.tryParse(Platform.environment['BOBTV_NATIVE_SOAK_SECONDS'] ?? '') ??
        0;
    if (seconds > 0) {
      final primary = Player(
        configuration: const PlayerConfiguration(logLevel: MPVLogLevel.warn),
      );
      final secondary = Player(
        configuration: const PlayerConfiguration(logLevel: MPVLogLevel.warn),
      );
      final errors = <String>[];
      final subscriptions = [
        primary.stream.error.listen(errors.add),
        secondary.stream.error.listen(errors.add),
      ];
      for (final player in [primary, secondary]) {
        await player.setVolume(0);
        await player.setPlaylistMode(PlaylistMode.loop);
        await player.open(Media(media));
      }
      final configuration = VideoControllerConfiguration(
        enableHardwareAcceleration: !Platform.isMacOS,
      );
      visible.value = VideoController(primary, configuration: configuration);
      final secondaryController = VideoController(
        secondary,
        configuration: configuration,
      );
      final memory = <int>[];
      var changes = 0;
      var previous = Duration.zero;
      for (var elapsed = 0; elapsed < seconds; elapsed++) {
        // Alternate single-player and PiP rendering without replacing cores.
        preview.value = elapsed % 60 >= 30 ? secondaryController : null;
        await Future<void>.delayed(const Duration(seconds: 1));
        if (primary.state.position != previous) changes++;
        previous = primary.state.position;
        if (elapsed >= 30) memory.add(ProcessInfo.currentRss);
        if (elapsed % 30 == 0)
          record(
            'soak elapsed=$elapsed rss=${ProcessInfo.currentRss} mainPosition=${primary.state.position.inMilliseconds} preview=${preview.value != null} errors=${errors.length}',
          );
      }
      if (changes < seconds * .7 || errors.isNotEmpty)
        throw StateError('Soak stalled or reported decoder errors: $errors');
      if (!primary.state.tracks.audio.any(
            (t) => t.id != 'auto' && t.id != 'no',
          ) ||
          !secondary.state.tracks.audio.any(
            (t) => t.id != 'auto' && t.id != 'no',
          ))
        throw StateError('Audio track missing');
      int median(List<int> values) {
        values.sort();
        return values[values.length ~/ 2];
      }

      final growth = memory.length < 60
          ? 0
          : median(memory.sublist(memory.length - 30)) -
                median(memory.take(30).toList());
      if (growth > 128 * 1024 * 1024)
        throw StateError('Sustained memory growth: $growth');
      visible.value = null;
      preview.value = null;
      await WidgetsBinding.instance.endOfFrame;
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
      await primary.dispose();
      await secondary.dispose();
      await Future<void>.delayed(const Duration(seconds: 7));
      record(
        'PASS: $seconds second dual-player AV soak positionUpdates=$changes rssGrowth=$growth',
      );
    }
    exit(0);
  } catch (error, stack) {
    record('FAIL: $error\n$stack');
    exit(1);
  }
}
