import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit/src/player/native/player/real.dart' as native_player;
import 'package:media_kit_video/media_kit_video.dart';

// Isolated native regression runner. It does not load BobTV settings or data.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final file = File(Platform.environment['BOBTV_NATIVE_DISPOSAL_LOG']!);
  void record(String text) =>
      file.writeAsStringSync('$text\n', mode: FileMode.append, flush: true);
  final media = Platform.environment['BOBTV_NATIVE_DISPOSAL_MEDIA']!;
  Future<void> prepare(Player player) async {
    record('prepare native audio sink');
    await (player.platform as native_player.NativePlayer)
        .setProperty('ao', 'null')
        .timeout(const Duration(seconds: 20));
    await player.setVolume(0).timeout(const Duration(seconds: 20));
  }

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
                        pauseUponEnteringBackgroundMode: false,
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
                          pauseUponEnteringBackgroundMode: false,
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
      record('begin cycle=$cycle');
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
      visible.value = controller;
      // VideoController attaches in a post-frame callback. Mount it before
      // any Player operation that waits for that attachment to finish.
      await prepare(player);
      record('open cycle=$cycle');
      await player.open(Media(media)).timeout(const Duration(seconds: 20));
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while ((player.state.width ?? 0) == 0 &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      if ((player.state.width ?? 0) == 0)
        throw StateError('No decoded fixture frame');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      visible.value = null;
      await WidgetsBinding.instance.endOfFrame.timeout(
        const Duration(seconds: 5),
      );
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
      final configuration = VideoControllerConfiguration(
        enableHardwareAcceleration: !Platform.isMacOS,
      );
      visible.value = VideoController(primary, configuration: configuration);
      final secondaryController = VideoController(
        secondary,
        configuration: configuration,
      );
      // Attach both renderers before opening the streams, just as in the
      // teardown phase. A late libmpv VO attachment can interrupt an already
      // loaded stream. CI window focus must not pause either test player.
      preview.value = secondaryController;
      for (final player in [primary, secondary]) {
        await prepare(player);
        await player.setPlaylistMode(PlaylistMode.loop);
        await player.open(Media(media)).timeout(const Duration(seconds: 20));
      }
      final memory = <int>[];
      var changes = 0;
      var secondaryChanges = 0;
      var primaryAudioSamples = 0;
      var secondaryAudioSamples = 0;
      var primaryFrameSamples = 0;
      var secondaryFrameSamples = 0;
      var previous = Duration.zero;
      var secondaryPrevious = Duration.zero;
      for (var elapsed = 0; elapsed < seconds; elapsed++) {
        // Alternate single-player and PiP rendering without replacing cores.
        preview.value = elapsed % 60 >= 30 ? secondaryController : null;
        await Future<void>.delayed(const Duration(seconds: 1));
        if (primary.state.position != previous) changes++;
        previous = primary.state.position;
        if (secondary.state.position != secondaryPrevious) secondaryChanges++;
        secondaryPrevious = secondary.state.position;
        bool hasAudio(Player player) => player.state.tracks.audio.any(
          (track) => track.id != 'auto' && track.id != 'no',
        );
        if (hasAudio(primary)) primaryAudioSamples++;
        if (hasAudio(secondary)) secondaryAudioSamples++;
        if ((primary.state.width ?? 0) > 0) primaryFrameSamples++;
        if ((secondary.state.width ?? 0) > 0) secondaryFrameSamples++;
        if (elapsed >= 30) memory.add(ProcessInfo.currentRss);
        if (elapsed % 30 == 0)
          record(
            'soak elapsed=$elapsed rss=${ProcessInfo.currentRss} mainPosition=${primary.state.position.inMilliseconds} secondaryPosition=${secondary.state.position.inMilliseconds} preview=${preview.value != null} audioSamples=$primaryAudioSamples/$secondaryAudioSamples frameSamples=$primaryFrameSamples/$secondaryFrameSamples errors=${errors.length}',
          );
      }
      if (changes < seconds * .7 ||
          secondaryChanges < seconds * .7 ||
          errors.isNotEmpty)
        throw StateError('Soak stalled or reported decoder errors: $errors');
      // The short fixture loops every three seconds. Track lists may clear
      // while MPV reloads it, so require sustained evidence from both streams
      // instead of sampling only the final loop boundary.
      if (primaryAudioSamples < seconds * .7 ||
          secondaryAudioSamples < seconds * .7)
        throw StateError(
          'Audio coverage missing: $primaryAudioSamples/$secondaryAudioSamples',
        );
      if (primaryFrameSamples < seconds * .7 ||
          secondaryFrameSamples < seconds * .7)
        throw StateError(
          'Video coverage missing: $primaryFrameSamples/$secondaryFrameSamples',
        );
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
      await WidgetsBinding.instance.endOfFrame.timeout(
        const Duration(seconds: 5),
      );
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
      await primary.dispose().timeout(const Duration(seconds: 25));
      await secondary.dispose().timeout(const Duration(seconds: 25));
      await Future<void>.delayed(const Duration(seconds: 7));
      record(
        'PASS: $seconds second dual-player AV soak positionUpdates=$changes/$secondaryChanges audioSamples=$primaryAudioSamples/$secondaryAudioSamples frameSamples=$primaryFrameSamples/$secondaryFrameSamples rssGrowth=$growth',
      );
    }
    exit(0);
  } catch (error, stack) {
    record('FAIL: $error\n$stack');
    exit(1);
  }
}
