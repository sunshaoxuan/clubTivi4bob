// Offline native integration fixture. Never claim this as a real live advert.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';
import 'package:clubtivi/core/app_diagnostics.dart';
import 'package:clubtivi/core/i18n/app_language.dart';
import 'package:clubtivi/features/player/client_audio_subtitles.dart';
import 'package:clubtivi/features/player/hls_buffer_proxy.dart';
import 'package:clubtivi/features/player/subtitle_preferences.dart';
import 'package:clubtivi/features/player/subtitle_variants.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await windowManager.ensureInitialized();
  final root = Directory(Platform.environment['BOBTV_LOCAL_ASR_FIXTURE']!);
  final fixture =
      jsonDecode(await File('${root.path}/fixture.json').readAsString()) as Map;
  await AppDiagnostics.instance.initialize(
    directoryOverride: Directory('${root.path}/client-logs'),
  );
  final errors = <String>[];
  final player = Player();
  player.stream.error.listen(errors.add);
  await player.setVolume(0);
  await (player.platform as NativePlayer).setProperty('mute', 'yes');
  SubtitlePreferences.instance.choose(AppLanguage.simplifiedChinese);
  final text = ValueNotifier<String>('');
  final status = ValueNotifier<String>('');
  final variants = ValueNotifier(const SubtitleVariantOptions());
  late ClientAudioSubtitles subtitles;
  final rows = (fixture['segments'] as List).map((raw) {
    final r = raw as Map;
    return HlsPlaybackSegment(
      sequence: r['sequence'],
      start: (r['start'] as num).toDouble(),
      end: (r['end'] as num).toDouble(),
      asset: r['asset'],
      movieId: r['movieId'],
      ad: r['ad'],
    );
  }).toList();
  subtitles = ClientAudioSubtitles(
    player,
    Uri.parse('http://127.0.0.1:18923/'),
    (position) =>
        rows.where((s) => s.start <= position && s.end > position).firstOrNull,
    variantOptions: variants,
    onChanged: () {
      text.value = subtitles.text;
      status.value = subtitles.phase.name;
    },
  );
  runApp(
    MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'BobTV offline audio alignment fixture',
                style: TextStyle(color: Colors.white),
              ),
              ValueListenableBuilder(
                valueListenable: status,
                builder: (_, s, _) =>
                    Text(s, style: const TextStyle(color: Colors.grey)),
              ),
              ValueListenableBuilder(
                valueListenable: text,
                builder: (_, s, _) => Text(
                  s,
                  style: const TextStyle(color: Colors.white, fontSize: 24),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await windowManager.setTitle('BobTV offline audio alignment fixture');
  await windowManager.show();
  await subtitles.start(
    fixture['source'],
    Map<String, Object?>.from(fixture['programme']),
  );
  subtitles.activate();
  await player.open(Media('${root.path}/fixture.wav'));
  final log = File('${root.path}/native-observations.jsonl').openWrite();
  var busy = false;
  final started = DateTime.now();
  Timer? timer;
  timer = Timer.periodic(const Duration(milliseconds: 100), (_) async {
    if (busy) return;
    busy = true;
    subtitles.render();
    log.writeln(
      jsonEncode({
        'elapsed': DateTime.now().difference(started).inMilliseconds / 1000,
        'position': player.state.position.inMicroseconds / 1e6,
        'text': subtitles.text,
        'phase': subtitles.phase.name,
        'buffering': player.state.buffering,
      }),
    );
    if (player.state.completed ||
        DateTime.now().difference(started).inSeconds > 130) {
      timer?.cancel();
      await log.close();
      await File('${root.path}/native-result.json').writeAsString(
        jsonEncode({
          'scope': 'offline native audio integration; not a live broadcast',
          'elapsed': DateTime.now().difference(started).inMilliseconds / 1000,
          'nativeMute': await (player.platform as NativePlayer).getProperty(
            'mute',
          ),
          'volume': player.state.volume,
          'errors': errors,
          'uploadedTextBytes': subtitles.uploadedBytes,
          'downloadedSubtitleBytes': subtitles.downloadedBytes,
        }),
      );
      await subtitles.dispose();
      variants.dispose();
      await player.dispose();
      exit(0);
    }
    busy = false;
  });
}
