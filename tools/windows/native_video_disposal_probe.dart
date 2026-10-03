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
  runApp(
    MaterialApp(
      home: ValueListenableBuilder<VideoController?>(
        valueListenable: visible,
        builder: (_, controller, __) => controller == null
            ? const ColoredBox(color: Colors.black)
            : Video(
                key: ValueKey(controller),
                controller: controller,
                controls: NoVideoControls,
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
          enableHardwareAcceleration: cycle.isEven,
        ),
      );
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
      record('disposed cycle=$cycle hardware=${cycle.isEven}');
    }
    // media_kit destroys native cores five seconds after Player.dispose.
    await Future<void>.delayed(const Duration(seconds: 7));
    record(
      'PASS: 30 real video create/render/dispose cycles, including duplicate releases',
    );
    exit(0);
  } catch (error, stack) {
    record('FAIL: $error\n$stack');
    exit(1);
  }
}
