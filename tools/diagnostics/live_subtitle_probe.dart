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
import 'package:clubtivi/features/player/live_subtitle_session.dart';
import 'package:clubtivi/features/player/subtitle_preferences.dart';
import 'package:clubtivi/features/player/subtitle_programme_context.dart';
import 'package:clubtivi/features/player/subtitle_variants.dart';
import 'package:clubtivi/features/player/player_service.dart';
import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/services/channel_route_sync_service.dart';
import 'package:clubtivi/data/services/retired_route_guard.dart';
import 'package:media_kit/src/player/native/player/real.dart' as native;

enum _VariantStage {
  waitingForPreferredCaption,
  waitingForEnglishCaption,
  waitingForManualCaption,
  waitingForRestoredCaption,
  passed,
  failed,
}

/// Optional end-to-end exercise of the same session API used by the picker.
class _VariantProbe {
  _VariantProbe(Directory directory, this.preferred)
    : _trace = File('${directory.path}/variant-observations.jsonl') {
    _trace.writeAsStringSync('');
  }

  final AppLanguage preferred;
  final File _trace;
  final _preferences = SubtitlePreferences.instance;
  var _stage = _VariantStage.waitingForPreferredCaption;
  LiveSubtitleSession? _session;
  int? _scope;
  String? _originalId, _englishAutomaticId, _manualId, _restoredId;
  String? _originalLanguage, _manualCaption, _failure;
  double? _selectionPosition, _manualCaptionPosition, _restoredPosition;

  bool get passed => _stage == _VariantStage.passed;

  bool get _finished => passed || _stage == _VariantStage.failed;

  void _record(
    String event,
    ManagedPlayer player,
    double elapsed,
    double position, {
    String? reason,
  }) {
    final session = player.liveSubtitles;
    final options = session.variantOptions.value;
    final active = options.candidates
        .where((candidate) => candidate.id == options.activeId)
        .firstOrNull;
    final row = <String, Object?>{
      'at': DateTime.now().toUtc().toIso8601String(),
      'event': event,
      'stage': _stage.name,
      'elapsed': elapsed,
      'position': position,
      'playing': player.state.playing,
      'buffering': player.state.buffering,
      'preferredLanguage': preferred.tag,
      'currentPreference': _preferences.language.tag,
      'subtitleStatus': session.status.value.name,
      'scope': options.scope,
      'candidateCount': options.candidates.length,
      'candidateIds': options.candidates
          .map((candidate) => candidate.id)
          .toList(),
      'englishCandidateIds': options.candidates
          .where((candidate) => candidate.language == 'en')
          .map((candidate) => candidate.id)
          .toList(),
      'selectedId': options.selectedId,
      'activeId': options.activeId,
      'activeLanguage': active?.language,
      'targetId': _manualId,
      'captionLength': session.text.value.trim().length,
      'reason': ?reason,
    };
    // Keep each transition visible to the external test runner during playback.
    _trace.writeAsStringSync(
      '${jsonEncode(row)}\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  void _restore(ManagedPlayer player) {
    final current = player.liveSubtitles;
    if (_preferences.language != preferred) {
      // Changing the session's language also clears its temporary pin.
      _preferences.choose(preferred);
    } else if (identical(current, _session) &&
        current.variantOptions.value.scope == _scope &&
        current.variantOptions.value.selectedId == _manualId &&
        _manualId != null) {
      current.selectVariant(null, _scope!);
    }
  }

  void step(ManagedPlayer player, double elapsed, double position) {
    if (_finished) return;
    final session = player.liveSubtitles;
    final options = session.variantOptions.value;
    if (_scope != null &&
        (!identical(session, _session) || options.scope != _scope)) {
      _fail('programme_scope_changed', player, elapsed, position);
      return;
    }
    final caption = session.text.value.trim();
    final active = options.candidates
        .where((candidate) => candidate.id == options.activeId)
        .firstOrNull;
    if (!player.state.playing ||
        player.state.buffering ||
        !session.hasVerifiedLocalCaptions ||
        caption.isEmpty ||
        active == null) {
      return;
    }
    final english = options.candidates.where(
      (candidate) => candidate.language == 'en',
    );
    final alternate = english
        .where((candidate) => candidate.id != active.id)
        .firstOrNull;
    switch (_stage) {
      case _VariantStage.waitingForPreferredCaption:
        if (english.length < 2 || options.selectedId != null) return;
        _session = session;
        _scope = options.scope;
        _originalId = active.id;
        _originalLanguage = active.language;
        _record('preferred_caption', player, elapsed, position);
        final offered = options.forLanguage(preferred.tag);
        if (active.language == 'en' &&
            alternate != null &&
            offered.any((candidate) => candidate.id == alternate.id)) {
          _select(alternate, player, elapsed, position);
        } else {
          _stage = _VariantStage.waitingForEnglishCaption;
          _preferences.choose(AppLanguage.english);
          _record('temporary_english', player, elapsed, position);
        }
      case _VariantStage.waitingForEnglishCaption:
        if (active.language == 'en' &&
            options.selectedId == null &&
            alternate != null) {
          _select(alternate, player, elapsed, position);
        }
      case _VariantStage.waitingForManualCaption:
        if (options.selectedId != _manualId ||
            active.id != _manualId ||
            position <= _selectionPosition!) {
          return;
        }
        _manualCaption = caption;
        _manualCaptionPosition = position;
        _record('manual_caption', player, elapsed, position);
        _stage = _VariantStage.waitingForRestoredCaption;
        _restore(player);
        _record('restore_automatic', player, elapsed, position);
      case _VariantStage.waitingForRestoredCaption:
        if (options.selectedId != null ||
            _preferences.language != preferred ||
            caption == _manualCaption ||
            position <= _manualCaptionPosition! ||
            (active.language != preferred.tag &&
                active.language != _originalLanguage)) {
          return;
        }
        _restoredId = active.id;
        _restoredPosition = position;
        _stage = _VariantStage.passed;
        _record('restored_caption', player, elapsed, position);
      case _VariantStage.passed:
      case _VariantStage.failed:
        break;
    }
  }

  void _select(
    SubtitleVariantCandidate alternate,
    ManagedPlayer player,
    double elapsed,
    double position,
  ) {
    final session = player.liveSubtitles;
    _englishAutomaticId = session.variantOptions.value.activeId;
    _manualId = alternate.id;
    _selectionPosition = position;
    _stage = _VariantStage.waitingForManualCaption;
    session.selectVariant(alternate.id, _scope!);
    _record('select_alternate', player, elapsed, position);
    if (session.variantOptions.value.selectedId != _manualId) {
      _fail('alternate_selection_rejected', player, elapsed, position);
    }
  }

  void _fail(
    String reason,
    ManagedPlayer player,
    double elapsed,
    double position,
  ) {
    _failure = reason;
    _stage = _VariantStage.failed;
    _record('failed', player, elapsed, position, reason: reason);
    _restore(player);
  }

  Map<String, Object?> finish(
    ManagedPlayer player,
    double elapsed,
    double position,
  ) {
    if (!_finished) {
      _fail('probe_ended_at_${_stage.name}', player, elapsed, position);
    }
    return {
      'passed': passed,
      'preferredLanguage': preferred.tag,
      'originalActiveId': _originalId,
      'originalActiveLanguage': _originalLanguage,
      'englishAutomaticId': _englishAutomaticId,
      'manualId': _manualId,
      'restoredActiveId': _restoredId,
      'selectionPosition': _selectionPosition,
      'manualCaptionPosition': _manualCaptionPosition,
      'restoredCaptionPosition': _restoredPosition,
      'failure': ?_failure,
    };
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final desktop = Platform.isWindows || Platform.isMacOS || Platform.isLinux;
  if (desktop) await windowManager.ensureInitialized();
  final directory = Directory(
    Platform.environment['BOBTV_SUBTITLE_PROBE_OUTPUT'] ??
        const String.fromEnvironment('BOBTV_SUBTITLE_PROBE_OUTPUT'),
  );
  await directory.create(recursive: true);
  await AppDiagnostics.instance.initialize(
    directoryOverride: Directory('${directory.path}/logs'),
  );
  final offline =
      Platform.environment['BOBTV_SUBTITLE_PROBE_OFFLINE'] == '1' ||
      const bool.fromEnvironment('BOBTV_SUBTITLE_PROBE_OFFLINE');
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
  final switchVariants =
      const bool.fromEnvironment('BOBTV_SUBTITLE_PROBE_SWITCH_VARIANTS') ||
      const {
        '1',
        'true',
      }.contains(Platform.environment['BOBTV_SUBTITLE_PROBE_SWITCH_VARIANTS']);
  final requestedLanguage =
      Platform.environment['BOBTV_SUBTITLE_PROBE_LANGUAGE'] ??
      (switchVariants
          ? const String.fromEnvironment('BOBTV_SUBTITLE_PROBE_LANGUAGE')
          : null);
  final preferred =
      AppLanguage.values
          .where((value) => value.tag == requestedLanguage)
          .firstOrNull ??
      AppLanguage.simplifiedChinese;
  if (switchVariants) SubtitlePreferences.instance.initialize(null);
  SubtitlePreferences.instance.choose(preferred);
  final variantProbe = switchVariants
      ? _VariantProbe(directory, preferred)
      : null;
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
  if (contextPath != null) {
    SubtitleProgrammeContext.lookup = (requested) async {
      final data = jsonDecode(await File(contextPath).readAsString()) as Map;
      return requested == data['source']
          ? Map<String, Object?>.from(data['programme'] as Map)
          : null;
    };
  } else if (offline) {
    SubtitleProgrammeContext.lookup = (_) async => null;
  }
  if (desktop) {
    await windowManager.setTitle('BobTV subtitle development probe');
    await windowManager.setSize(const Size(900, 650));
  }
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
                builder: (_, active, _) => BobtvVideo(
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
  if (desktop) await windowManager.show();
  await player.setVolume(0);
  await Future<void>.delayed(const Duration(milliseconds: 500));
  final backend = player.platform;
  if (backend is native.NativePlayer) await backend.setProperty('mute', 'yes');
  await service.play(source, channelName: 'Action Movies subtitle pilot');
  await File('${directory.path}/resolved-media.json').writeAsString(
    jsonEncode({'mediaPath': await service.getMpvProperty('path')}),
  );
  final limit = int.parse(
    Platform.environment['BOBTV_SUBTITLE_PROBE_SECONDS'] ??
        const String.fromEnvironment(
          'BOBTV_SUBTITLE_PROBE_SECONDS',
          defaultValue: '285',
        ),
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
      final variantResult = variantProbe?.finish(player, elapsed, position);
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
          'subtitleVariantProbe': ?variantResult,
        }),
      );
      await service.dispose();
      await routeSync?.shutdown();
      await guard?.dispose();
      await isolatedDatabase?.close();
      await logSubscription.cancel();
      await mpvLog.close();
      exit(errors.isEmpty && (variantProbe?.passed ?? true) ? 0 : 1);
    } else {
      variantProbe?.step(player, elapsed, position);
    }
  });
}
