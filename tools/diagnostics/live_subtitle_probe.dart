// Isolated native fixture: no catalogue, user preferences or installed app data.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';
import 'package:clubtivi/core/player_resources.dart';
import 'package:clubtivi/core/i18n/app_language.dart';
import 'package:clubtivi/core/app_diagnostics.dart';
import 'package:clubtivi/features/player/bobtv_video.dart';
import 'package:clubtivi/features/player/subtitle_preferences.dart';
import 'package:clubtivi/features/player/subtitle_programme_context.dart';
import 'package:clubtivi/features/player/player_service.dart';
import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/services/channel_route_sync_service.dart';
import 'package:clubtivi/data/services/retired_route_guard.dart';
import 'package:media_kit/src/player/native/player/real.dart' as native;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await windowManager.ensureInitialized();
  final directory = Directory(
    Platform.environment['BOBTV_SUBTITLE_PROBE_OUTPUT'] ??
        const String.fromEnvironment('BOBTV_SUBTITLE_PROBE_OUTPUT'),
  );
  await directory.create(recursive: true);
  await AppDiagnostics.instance.initialize(
    directoryOverride: Directory('${directory.path}/logs'),
  );
  final offline = Platform.environment['BOBTV_SUBTITLE_PROBE_OFFLINE'] == '1';
  final isolatedDatabase = offline
      ? db.AppDatabase.forTesting(NativeDatabase.memory())
      : null;
  var syncFetches = 0;
  final routeSync = isolatedDatabase == null
      ? null
      : ChannelRouteSyncService(
          database: isolatedDatabase,
          fetch: (_) async {
            syncFetches++;
            throw const SocketException('offline acceptance fixture');
          },
        );
  final guard = isolatedDatabase == null
      ? null
      : RetiredRouteGuard(
          read: isolatedDatabase.getBlockedStreamUrls,
          updates: const Stream<Set<String>>.empty(),
          beforeOpen: routeSync!.beforeOpen,
        );
  final service = PlayerService(retirementGuard: guard);
  var player = service.player as ManagedPlayer;
  final video = service.videoController;
  player.stream.buffering.listen(service.onBufferingChanged);
  final layout = ValueNotifier<int>(0);
  final output = File('${directory.path}/observations.jsonl').openWrite();
  SubtitlePreferences.instance.choose(AppLanguage.simplifiedChinese);
  final mpvLog = File('${directory.path}/mpv.jsonl').openWrite();
  var logSubscription = player.stream.log.listen(
    (entry) => mpvLog.writeln(
      jsonEncode({
        'at': DateTime.now().toUtc().toIso8601String(),
        'level': entry.level,
        'prefix': entry.prefix,
        'text': entry.text,
      }),
    ),
  );
  final errors = <String>[];
  player.stream.error.listen(errors.add);
  final samples = <Map<String, Object?>>[];
  final started = DateTime.now();
  final source =
      Platform.environment['BOBTV_SUBTITLE_PROBE_SOURCE'] ??
      const String.fromEnvironment('BOBTV_SUBTITLE_PROBE_SOURCE');
  final contextPath = Platform.environment['BOBTV_SUBTITLE_PROBE_CONTEXT'];
  if (offline) {
    SubtitleProgrammeContext.lookup = (_) async => null;
  } else if (contextPath != null) {
    SubtitleProgrammeContext.lookup = (requested) async {
      final data = jsonDecode(await File(contextPath).readAsString()) as Map;
      return requested == data['source']
          ? Map<String, Object?>.from(data['programme'] as Map)
          : null;
    };
  }
  await windowManager.setTitle('BobTV subtitle development probe');
  await windowManager.setSize(const Size(900, 650));
  runApp(
    MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.black,
        body: ValueListenableBuilder<int>(
          valueListenable: layout,
          builder: (context, value, _) => Align(
            alignment: [
              Alignment.center,
              Alignment.topRight,
              Alignment.bottomLeft,
            ][value],
            child: SizedBox(
              width: [850.0, 420.0, 280.0][value],
              height: [580.0, 315.0, 210.0][value],
              child: ValueListenableBuilder<VideoController?>(
                valueListenable: service.activeVideoController,
                builder: (_, active, __) => BobtvVideo(
                  controller: active ?? video,
                  controls: NoVideoControls,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await windowManager.show();
  await player.setVolume(0);
  await Future<void>.delayed(const Duration(milliseconds: 500));
  final backend = player.platform;
  if (backend is native.NativePlayer) await backend.setProperty('mute', 'yes');
  await service.play(source, channelName: 'Action Movies subtitle pilot');
  await File('${directory.path}/resolved-media.json').writeAsString(
    jsonEncode({'mediaPath': await service.getMpvProperty('path')}),
  );
  final limit = int.parse(
    Platform.environment['BOBTV_SUBTITLE_PROBE_SECONDS'] ?? '285',
  );
  final nativeClock = File('${directory.path}/native-clock.jsonl').openWrite();
  var nativePollBusy = false;
  final nativePoll = Timer.periodic(const Duration(seconds: 1), (_) async {
    if (nativePollBusy) return;
    nativePollBusy = true;
    try {
      final row = <String, Object?>{
        'at': DateTime.now().toUtc().toIso8601String(),
      };
      for (final key in [
        'time-pos',
        'demuxer-start-time',
        'audio-pts',
        'video-pts',
        'avsync',
        'demuxer-cache-duration',
        'paused-for-cache',
        'cache-on-disk',
        'demuxer-lavf-linearize-timestamps',
      ]) {
        row[key] = await service.getMpvProperty(key);
      }
      nativeClock.writeln(jsonEncode(row));
    } finally {
      nativePollBusy = false;
    }
  });
  Timer? timer;
  timer = Timer.periodic(const Duration(milliseconds: 50), (_) async {
    final elapsed = DateTime.now().difference(started).inMilliseconds / 1000;
    player = service.player as ManagedPlayer;
    final position = player.state.position.inMicroseconds / 1000000;
    final next = (position ~/ 30) % 3;
    if (layout.value != next) layout.value = next;
    final sample = <String, Object?>{
      'at': DateTime.now().toUtc().toIso8601String(),
      'elapsed': elapsed,
      'position': position,
      'buffering': player.state.buffering,
      'playing': player.state.playing,
      'text': player.liveSubtitles.text.value,
      'subtitleStatus': player.liveSubtitles.status.value.name,
      'layout': layout.value,
    };
    output.writeln(jsonEncode(sample));
    samples.add(sample);
    if (elapsed >= limit ||
        File('${directory.path}/STOP').existsSync() ||
        (position > 260 && player.state.completed)) {
      timer?.cancel();
      nativePoll.cancel();
      while (nativePollBusy) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await nativeClock.close();
      await output.close();
      await File('${directory.path}/result.json').writeAsString(
        jsonEncode({
          'source': source,
          'samples': samples.length,
          'errors': errors,
          'lastPosition': position,
          'elapsed': elapsed,
          'bufferingSamplesAfterStartup': samples
              .where(
                (s) => (s['elapsed'] as num) > 10 && s['buffering'] == true,
              )
              .length,
          'lavfOptions': await service.getMpvProperty('demuxer-lavf-o'),
          'cachePauseInitial': await service.getMpvProperty(
            'cache-pause-initial',
          ),
          'cachePauseWait': await service.getMpvProperty('cache-pause-wait'),
          'cacheSeconds': await service.getMpvProperty(
            'demuxer-cache-duration',
          ),
          'pipeline': 'PlayerService and AdaptiveBufferManager',
          'scope': 'native Flutter development fixture, not production release',
          'simulatedRouteApiOffline': offline,
          'routeSyncFetches': syncFetches,
          'subtitleStatus': player.liveSubtitles.status.value.name,
          'subtitleMediaAutoOpens': player.subtitleMediaAutoOpens,
          'subtitleMediaPromotions': service.subtitleMediaPromotions,
          'finalMediaPath': await service.getMpvProperty('path'),
          'videoWidth': await service.getMpvProperty('video-params/w'),
          'videoHeight': await service.getMpvProperty('video-params/h'),
          'nativeMute': await service.getMpvProperty('mute'),
          'nativeVolume': await service.getMpvProperty('volume'),
        }),
      );
      await service.dispose();
      await routeSync?.shutdown();
      await guard?.dispose();
      await isolatedDatabase?.close();
      await logSubscription.cancel();
      await mpvLog.close();
      exit(errors.isEmpty ? 0 : 1);
    }
  });
}
