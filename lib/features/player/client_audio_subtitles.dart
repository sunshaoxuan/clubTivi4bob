import 'ios_native_media.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import '../../core/app_diagnostics.dart';
import '../../core/server_egress.dart';
import 'hls_buffer_proxy.dart';
import 'source_clock.dart';
import 'client_subtitle_runtime.dart';
import 'client_audio_window.dart';
import 'live_subtitle_timeline.dart';
import 'subtitle_policy.dart';
import 'subtitle_preferences.dart';
import 'subtitle_programme_context.dart';
import 'subtitle_status.dart';
import 'subtitle_variants.dart';
import 'offline_asr_policy.dart';

/// One local decoder tap and offline ASR worker per viewing session. Only text
/// observations cross the service boundary; video and PCM stay on the device.
class ClientAudioSubtitles {
  ClientAudioSubtitles(
    this.player,
    this.endpoint,
    this.segmentAt, {
    required this.onChanged,
    this.programmeLookup,
    required ValueNotifier<SubtitleVariantOptions> variantOptions,
  }) : _variants = SubtitleVariantSelection(
         variantOptions,
         SubtitlePreferences.instance.language.tag,
       );
  final Player player;
  final Uri endpoint;
  final HlsPlaybackSegment? Function(double) segmentAt;
  final VoidCallback onChanged;
  final SubtitleProgrammeLookup? programmeLookup;
  final SubtitleVariantSelection _variants;
  bool get hasPinnedVariant => _variants.hasPin;
  static int _nextLabel = 0;
  final label = 'bobtv_pcm_${_nextLabel++}';
  static bool get supported => ClientSubtitleRuntime.available;
  String? _workerModel;
  String? _iosRecognitionId;
  String text = '';
  SubtitlePhase phase = SubtitlePhase.searching;
  String? _source, _session;
  Map<String, dynamic>? _programme;
  bool _usesPlayerGuide = false;
  bool _playerProgrammeStale = false;
  LiveSubtitleTimeline? _timeline;
  Process? _worker;
  Directory? _directory;
  StreamSubscription<String>? _lines;
  Timer? _timer, _poll, _startupRetry, _workerRetry;
  int _workerFailures = 0;
  int _startupFailures = 0;
  final _client = http.Client();
  bool _polling = false, _queuedRefresh = false;
  Completer<Map<String, dynamic>>? _recognition;
  bool _disposed = false,
      _sampling = false,
      _recognizing = false,
      _active = false;
  bool _attached = false, _workerFailed = false, _clockAvailable = true;
  bool _transportLocked = false;
  bool _audioLanguageSupported = false;
  final _systemAsrRetry = <String, DateTime>{};
  bool _recoveryTimedOut = false;
  bool _referenceResourcesAvailable = false;
  bool _verifiedProgrammeClock = false;
  bool _coldRecognition = true, _waitingForPlaybackBuffer = false;
  double _lastClockObservation = -1;
  String? _clockSignature, _audioTrackId;
  int _epoch = 0, _nativeEpoch = -1, _sequence = -1, _serial = 0;
  String? _asset;
  bool? _ad;
  double _lastEnd = -1, _lastAnalysisEnd = -1;
  ({
    double start,
    double end,
    List<dynamic> words,
    int epoch,
    String asset,
    String? audioLanguage,
    Object? programmeKey,
  })?
  _lastSpeech;
  final _chunks = <PcmChunk>[];
  final _playbackBudget = SpeechPlaybackBudget();
  List<String> _languages = [];
  DateTime _lastResponse = DateTime(1970);
  int uploadedBytes = 0, downloadedBytes = 0;
  NativePlayer? get _native =>
      player.platform is NativePlayer ? player.platform as NativePlayer : null;
  Future<void> start(String source, Map<String, Object?>? programme) async {
    if (_disposed) return;
    _startupRetry?.cancel();
    _usesPlayerGuide =
        _usesPlayerGuide || programme?['contextKind'] == 'player-epg-v1';
    try {
      await _start(source, programme);
      _startupFailures = 0;
    } catch (_) {
      _timer?.cancel();
      _poll?.cancel();
      final worker = _worker;
      _worker = null;
      worker?.kill();
      await _lines?.cancel();
      _lines = null;
      try {
        await worker?.exitCode.timeout(const Duration(seconds: 2));
      } catch (_) {}
      try {
        await _directory?.delete(recursive: true);
      } catch (_) {}
      _directory = null;
      _session = null;
      if (_disposed) return;
      failed();
      final seconds = math.min(60, 5 * (1 << math.min(_startupFailures++, 4)));
      AppDiagnostics.instance.log('client_subtitle_start_retry', {
        'delaySeconds': seconds,
      });
      _startupRetry = Timer(Duration(seconds: seconds), () {
        unawaited(_retryStart(source));
      });
      rethrow;
    }
  }

  Future<Map<String, Object?>?> _currentPlayerProgramme(String source) async {
    try {
      return await programmeLookup
          ?.call(source)
          .timeout(const Duration(milliseconds: 500));
    } catch (_) {
      return null;
    }
  }

  Future<void> _retryStart(String source) async {
    final programme = _usesPlayerGuide
        ? await _currentPlayerProgramme(source)
        : null;
    if (_disposed) return;
    try {
      await start(source, programme);
    } catch (_) {
      // The next retry retains the same playback and obtains a fresh mapping.
    }
  }

  Future<void> _start(String source, Map<String, Object?>? programme) async {
    _source = source;
    final request = _variants.request;
    final body = await _post('sessions', {
      'source': source,
      'programme': programme,
      'language': request.query['language'],
      'features': ['clientClockV1'],
    });
    if (_disposed) return;
    _session = body['session'] as String;
    _accept(body, request, acknowledgesRequest: !_variants.hasPin);
    if (_variants.pending) unawaited(_refresh());
    if (_clockAvailable) await _launchWorker();
    _poll = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_refresh()),
    );
    _timer = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => unawaited(_tick()),
    );
    AppDiagnostics.instance.log('client_asr_ready', {
      'engine': Platform.isIOS ? 'apple-on-device' : 'whisper.cpp-v1.8.2',
      'model': _workerModel,
      'cpuVariant': (ClientSubtitleRuntime.asr?.contains('avx2') ?? false)
          ? 'avx2'
          : 'baseline',
      'audioUploaded': false,
    });
  }

  Future<void> _launchWorker() async {
    _coldRecognition = true;
    _directory = await Directory.systemTemp.createTemp('bobtv-client-asr-');
    if (_disposed) {
      await _directory?.delete(recursive: true);
      return;
    }
    if (Platform.isIOS) {
      _workerModel = 'AppleOnDeviceSpeech';
      return;
    }
    final ready = Completer<void>();
    final worker = await Process.start(ClientSubtitleRuntime.asr!, [
      ClientSubtitleRuntime.model!,
    ]);
    if (_disposed) {
      worker.kill();
      return;
    }
    _worker = worker;
    _lines = worker.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (!identical(_worker, worker)) return;
          try {
            final message = jsonDecode(line) as Map<String, dynamic>;
            if (message['ready'] == true && !ready.isCompleted) {
              _workerModel = message['model'] as String?;
              ready.complete();
            } else if (_recognition != null && !_recognition!.isCompleted) {
              _recognition!.complete(message);
            }
          } catch (_) {
            /* A malformed worker response cannot affect playback. */
          }
        });
    unawaited(worker.stderr.drain<void>());
    unawaited(
      worker.exitCode.then((code) {
        AppDiagnostics.instance.log('client_asr_exit', {
          'code': code,
          'current': identical(_worker, worker),
        });
        if (!ready.isCompleted) {
          ready.completeError(StateError('Offline ASR worker exited'));
        }
        if (identical(_worker, worker)) {
          if (_recognition != null && !_recognition!.isCompleted) {
            _recognition!.completeError(
              StateError('Offline ASR worker exited'),
            );
          }
          if (_timer?.isActive == true && !_disposed) {
            _workerFailed = true;
            if (!_transportLocked) _timeline = null;
            failed();
            _scheduleWorkerRetry();
          }
        }
      }),
    );
    await ready.future.timeout(const Duration(seconds: 30));
    if (_disposed) return;
  }

  void _scheduleWorkerRetry() {
    if (_disposed ||
        !_clockAvailable ||
        _session == null ||
        _workerRetry?.isActive == true) {
      return;
    }
    final delay = math.min(60, 5 * (1 << math.min(_workerFailures++, 4)));
    AppDiagnostics.instance.log('client_asr_restart_scheduled', {
      'delaySeconds': delay,
    });
    _workerRetry = Timer(Duration(seconds: delay), () async {
      _workerRetry = null;
      if (_disposed || !_clockAvailable) return;
      final previous = _worker;
      _worker = null;
      previous?.kill();
      await _lines?.cancel();
      _lines = null;
      try {
        await previous?.exitCode.timeout(const Duration(seconds: 2));
      } catch (_) {}
      try {
        await _directory?.delete(recursive: true);
      } catch (_) {}
      _directory = null;
      _chunks.clear();
      _lastEnd = -1;
      _lastAnalysisEnd = -1;
      _sequence = -1;
      try {
        await _launchWorker();
        if (_disposed || !_clockAvailable) {
          _worker?.kill();
          return;
        }
        _workerFailed = false;
        _recoveryTimedOut = false;
        AppDiagnostics.instance.log('client_asr_restarted', {
          'epoch': _epoch,
          'playbackRestarted': false,
        });
      } catch (_) {
        _scheduleWorkerRetry();
      }
    });
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, Object?> body,
  ) async {
    final uri = endpoint.resolve(path);
    if (!ServerEgress.canConnect(uri)) {
      throw const FormatException('Unreviewed subtitle endpoint');
    }
    final encoded = jsonEncode(body);
    uploadedBytes += utf8.encode(encoded).length;
    final response = await _client
        .post(uri, headers: {'Content-Type': 'application/json'}, body: encoded)
        .timeout(const Duration(seconds: 8));
    downloadedBytes += response.bodyBytes.length;
    if (response.statusCode != 200) {
      AppDiagnostics.instance.log('client_subtitle_http_error', {
        'status': response.statusCode,
        'operation': path.contains('observations') ? 'observations' : 'session',
      });
      throw HttpException('Subtitle response ${response.statusCode}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  void preferencesChanged() {
    if (_variants.setLanguage(SubtitlePreferences.instance.language.tag)) {
      _selectionChanged();
    } else {
      render();
    }
  }

  void selectVariant(String? id, int scope) {
    if (!_disposed && _variants.select(id, scope)) _selectionChanged();
  }

  Future<bool> retrySearch(String language) async {
    final session = _session;
    final programme = _programme;
    if (_disposed || session == null || programme == null) return false;
    try {
      await _post('sessions/$session/search', {
        'source': _source,
        'programme': programme,
        'programmeKey': programme['key'],
        'language': language,
      });
      if (_disposed || session != _session) return false;
      unawaited(_refresh());
      return true;
    } catch (_) {
      return false;
    }
  }

  void _selectionChanged() {
    _timeline = null;
    _transportLocked = false;
    _lastAnalysisEnd = double.negativeInfinity;
    phase = SubtitlePhase.synchronizing;
    render();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    final session = _session;
    if (_disposed || session == null) return;
    if (_polling) {
      _queuedRefresh = true;
      return;
    }
    _polling = true;
    final request = _variants.request;
    try {
      if (_usesPlayerGuide && _source != null) {
        final next = await _currentPlayerProgramme(_source!);
        if (_disposed || session != _session) return;
        if (next?['key'] != _programme?['key']) {
          _playerProgrammeStale = true;
          _timeline = null;
          _transportLocked = false;
          phase = SubtitlePhase.programmeUnavailable;
          render();
          if (next != null) await _renewProgramme(session, next);
          return;
        }
        _playerProgrammeStale = false;
      }
      final response = await _client
          .get(
            endpoint
                .resolve('sessions/$session')
                .replace(queryParameters: request.query),
          )
          .timeout(const Duration(seconds: 5));
      downloadedBytes += response.bodyBytes.length;
      if (_disposed || session != _session || !_variants.isCurrent(request)) {
        return;
      }
      if (response.statusCode == 200) {
        _accept(
          jsonDecode(response.body) as Map<String, dynamic>,
          request,
          acknowledgesRequest: true,
        );
      } else if (response.statusCode == 404) {
        final next = _usesPlayerGuide && _source != null
            ? await _currentPlayerProgramme(_source!)
            : null;
        if (!_usesPlayerGuide || next != null) {
          await _renewProgramme(session, next);
        }
      }
    } catch (_) {
    } finally {
      _polling = false;
      if (_queuedRefresh && !_disposed) {
        _queuedRefresh = false;
        unawaited(_refresh());
      }
    }
  }

  Future<void> _renewProgramme(
    String session,
    Map<String, Object?>? next,
  ) async {
    if (_disposed || session != _session) return;
    _variants.renewSession();
    final replacement = _variants.request;
    final body = await _post('sessions', {
      'source': _source,
      'programme': next,
      'language': replacement.query['language'],
      'features': ['clientClockV1'],
    });
    if (_disposed || session != _session) return;
    _session = body['session'] as String;
    _playerProgrammeStale = false;
    _epoch++;
    _chunks.clear();
    _timeline = null;
    _asset = null;
    _lastEnd = -1;
    _lastAnalysisEnd = -1;
    _accept(body, replacement, acknowledgesRequest: !_variants.hasPin);
    _queuedRefresh = _queuedRefresh || _variants.pending;
  }

  void _accept(
    Map<String, dynamic> body,
    SubtitleVariantRequest request, {
    required bool acknowledgesRequest,
  }) {
    if (_disposed ||
        _playerProgrammeStale ||
        (body['session'] != _session && _session != null) ||
        !_variants.isCurrent(request)) {
      return;
    }
    _audioLanguageSupported = body['audioLanguageV1'] == true;
    final programme = body['programme'];
    if (programme is Map &&
        _programme != null &&
        programme['key'] != _programme!['key']) {
      _verifiedProgrammeClock = false;
    }
    if (programme is Map) _programme = Map<String, dynamic>.from(programme);
    final status = body['subtitleStatus'] as Map?;
    final awaitingSelection = _variants.awaitingRefresh;
    final variants = _variants.accept(
      body['programmeKey'] ?? _programme?['key'],
      status,
      acknowledgesRequest: acknowledgesRequest,
    );
    if (awaitingSelection && !_variants.awaitingRefresh) {
      _lastAnalysisEnd = double.negativeInfinity;
      final sample = _lastSpeech;
      if (_variants.pending &&
          sample != null &&
          !_disposed &&
          _ad == false &&
          sample.epoch == _epoch &&
          sample.asset == _asset &&
          sample.programmeKey == _programme?['key'] &&
          (_lastEnd - sample.end).abs() < 16) {
        unawaited(
          _observe(
            sample.start,
            sample.end,
            sample.words,
            sample.epoch,
            sample.asset,
            false,
            audioLanguage: sample.audioLanguage,
          ),
        );
      }
    }
    _referenceResourcesAvailable = (status?['candidateCount'] as num? ?? 0) > 0;
    _transportLocked =
        variants.render && body['transportClockVerified'] == true;
    if (_transportLocked) _verifiedProgrammeClock = true;
    _languages = (status?['availableLanguages'] as List? ?? [])
        .whereType<String>()
        .toList();
    phase = switch (status?['phase']) {
      'searching' => SubtitlePhase.searching,
      'unavailable' => SubtitlePhase.unavailable,
      'programme_unavailable' => SubtitlePhase.programmeUnavailable,
      'service_unavailable' => SubtitlePhase.serviceUnavailable,
      _ => SubtitlePhase.synchronizing,
    };
    _timeline = variants.render
        ? LiveSubtitleTimeline.decode(
            body,
            session: _session!,
            source: _source!,
          )
        : null;
    _lastResponse = DateTime.now();
    render();
    if (variants.refresh) unawaited(_refresh());
  }

  void failed() {
    phase = SubtitlePhase.serviceUnavailable;
    onChanged();
  }

  void activate() {
    _active = true;
    render();
  }

  void render() {
    if (_disposed) return;
    final position = player.state.position.inMicroseconds / 1e6;
    final segment = segmentAt(position);
    final enabled = SubtitlePreferences.instance.enabled;
    final fresh = DateTime.now().difference(_lastResponse).inSeconds <= 15;
    text = '';
    if (!enabled) {
      phase = SubtitlePhase.idle;
    } else if (_playerProgrammeStale ||
        (_usesPlayerGuide &&
            _programme?['stopUtc'] is int &&
            (_programme!['stopUtc'] as int) <=
                DateTime.now().millisecondsSinceEpoch ~/ 1000)) {
      phase = SubtitlePhase.programmeUnavailable;
    } else if (!_clockAvailable) {
      phase = SubtitlePhase.clockUnavailable;
    } else if (segment?.ad == true ||
        sourceBoundaryBeforeAdvert(
          segmentAt(position + .25)?.sourceClock,
          position,
          advertWithinLookahead: segmentAt(position + 30)?.ad == true,
        )) {
      phase = SubtitlePhase.suspended;
    } else if (_workerFailed && !_transportLocked) {
      phase = _recoveryTimedOut
          ? SubtitlePhase.synchronizing
          : SubtitlePhase.serviceUnavailable;
    } else if (_variants.pending &&
        fresh &&
        phase != SubtitlePhase.serviceUnavailable &&
        phase != SubtitlePhase.programmeUnavailable) {
      phase = SubtitlePhase.synchronizing;
    } else if (fresh &&
        segment != null &&
        (segment.movieId == null ||
            segment.movieId == _programme?['movieId'])) {
      if (_active && player.state.playing && !player.state.buffering) {
        text =
            _timeline?.textAt(
              position,
              SubtitlePreferences.instance.language.tag,
              variantId: _variants.pinnedId,
            ) ??
            '';
      }
      if (_timeline?.windowAt(position)?['state'] == 'LOCKED') {
        final pinned = _variants.pinnedId;
        final selected = pinned == null
            ? selectSubtitle(
                _languages,
                SubtitlePreferences.instance.language.tag,
                language: (v) => v,
              )
            : _timeline!.variantLanguageAt(position, pinned);
        phase = selected == null
            ? pinned == null
                  ? SubtitlePhase.unavailable
                  : SubtitlePhase.synchronizing
            : pinned == null &&
                  subtitleLanguage(selected) == 'en' &&
                  subtitleLanguage(SubtitlePreferences.instance.language.tag) !=
                      'en'
            ? SubtitlePhase.englishFallback
            : SubtitlePhase.ready;
      }
    } else if (!fresh) {
      phase = SubtitlePhase.serviceUnavailable;
    }
    onChanged();
  }

  void clockUnavailable() {
    _clockAvailable = false;
    _transportLocked = false;
    _workerRetry?.cancel();
    _workerFailed = true;
    _timeline = null;
    text = '';
    phase = SubtitlePhase.clockUnavailable;
    onChanged();
  }

  Future<void> _tick() async {
    if (_disposed || _sampling || !_active) return;
    _sampling = true;
    try {
      final native = _native;
      if (native == null) return;
      if (!_attached) {
        await native.command([
          'af',
          'add',
          '@$label:lavfi=[bobtv_pcm]:o=[threads=1]',
        ]);
        final filters = await native.getProperty('af');
        if (!filters.contains(label)) {
          throw StateError('Decoded audio tap unavailable');
        }
        _attached = true;
      }
      render();
      if (!_clockAvailable || !SubtitlePreferences.instance.enabled) return;
      if (_usesPlayerGuide && phase == SubtitlePhase.programmeUnavailable) {
        return;
      }
      // Keep polling for programme/resource changes without spending CPU on
      // alignment when discovery has confirmed no usable reference subtitle.
      if (phase == SubtitlePhase.unavailable && !_referenceResourcesAvailable) {
        return;
      }
      if (!player.state.playing || player.state.buffering) return;
      final raw = await native.getProperty('af-metadata/$label');
      if (_disposed || raw.isEmpty) return;
      final metadata = jsonDecode(raw) as Map;
      final sequence = int.tryParse('${metadata['lavfi.bobtv_pcm.sequence']}');
      if (sequence == null || sequence == _sequence) return;
      _sequence = sequence;
      final start = double.parse('${metadata['lavfi.bobtv_pcm.start']}');
      final end = double.parse('${metadata['lavfi.bobtv_pcm.end']}');
      final nativeEpoch = int.parse('${metadata['lavfi.bobtv_pcm.epoch']}');
      final segment = segmentAt(math.max(0, end - .01));
      if (segment == null) return;
      // The same packet boundary that clears the renderer must also stop
      // movie observations before a lagging manifest labels the advert.
      if (!segment.ad &&
          sourceBoundaryBeforeAdvert(
            segment.sourceClock,
            end - .01,
            advertWithinLookahead: segmentAt(end + 30)?.ad == true,
          )) {
        return;
      }
      final ad =
          segment.ad ||
          segment.movieId != null && segment.movieId != _programme?['movieId'];
      final clock = segment.sourceClock;
      final signature = clock == null
          ? null
          : jsonEncode([
              clock['epoch'],
              clock['audioRemoved'],
              clock['videoRemoved'],
            ]);
      if (_transportLocked &&
          !ad &&
          _ad == false &&
          _asset == segment.asset &&
          signature != _clockSignature) {
        _transportLocked = false;
        _timeline = null;
        text = '';
      }
      _clockSignature = signature;
      final audioTrackId = player.state.track.audio.id;
      if (_asset != segment.asset ||
          _ad != ad ||
          _nativeEpoch != nativeEpoch ||
          _audioTrackId != audioTrackId) {
        _epoch++;
        _asset = segment.asset;
        _ad = ad;
        _nativeEpoch = nativeEpoch;
        _audioTrackId = audioTrackId;
        _chunks.clear();
        _lastEnd = end;
        _lastAnalysisEnd = -1;
        _lastClockObservation = -1;
        _transportLocked = false;
        _timeline = null;
        text = '';
        AppDiagnostics.instance.log('client_subtitle_boundary', {
          'epoch': _epoch,
          'asset': segment.asset,
          'ad': ad,
          'position': player.state.position.inMicroseconds / 1e6,
          'audioEnd': end,
          'sequence': segment.sequence,
          'segmentStart': segment.start,
          'segmentEnd': segment.end,
        });
        unawaited(
          _observe(
            math.max(0, segment.start),
            math.min(end, segment.end),
            [],
            _epoch,
            segment.asset,
            ad,
          ),
        );
        return;
      }
      if (!ad && end - _lastClockObservation >= 3) {
        _lastClockObservation = end;
        unawaited(
          _observe(
            math.max(segment.start, end - .05),
            end,
            [],
            _epoch,
            segment.asset,
            false,
          ),
        );
      }
      if (ad || _workerFailed) return;
      final bytes = base64Decode(metadata['lavfi.bobtv_pcm.pcm'] as String);
      if (bytes.length > 64000 ||
          bytes.length.isOdd ||
          !start.isFinite ||
          !end.isFinite ||
          end < start) {
        return;
      }
      final begin = math.max(start, _lastEnd);
      final skip =
          ((begin - start) * 16000).round().clamp(0, bytes.length ~/ 2) * 2;
      if (skip < bytes.length) {
        _chunks.add((
          start: start + skip / 32000,
          bytes: Uint8List.sublistView(bytes, skip),
        ));
      }
      _lastEnd = end;
      // Bound decoder work on mobile while retaining overlapping dialogue.
      final reacquiring =
          (_verifiedProgrammeClock || _variants.pending) && !_transportLocked;
      // Try after six seconds, then grow the same PCM history naturally.
      // Fixed short recovery windows lose complete sentences and cue onsets.
      retainPcmContext(
        _chunks,
        end,
        mobile: Platform.isAndroid || Platform.isIOS,
      );
      final duration = _chunks.isEmpty ? 0.0 : end - _chunks.first.start;
      if (!_recognizing &&
          !_variants.awaitingRefresh &&
          duration >= (reacquiring ? 6 : 12) &&
          end - _lastAnalysisEnd >=
              (_transportLocked || phase == SubtitlePhase.unavailable
                  ? 30
                  : (reacquiring ? 2 : 6))) {
        if (Platform.isAndroid || Platform.isIOS) {
          final buffered = double.tryParse(
            await native.getProperty('demuxer-cache-duration'),
          );
          final minimum = _playbackBudget.minimumSeconds(
            duration,
            cold: _coldRecognition,
          );
          final ready =
              buffered != null && buffered.isFinite && buffered >= minimum;
          if (_waitingForPlaybackBuffer == ready) {
            AppDiagnostics.instance.log('client_asr_playback_budget', {
              'deferred': !ready,
              'bufferSeconds': buffered,
              'minimumSeconds': minimum,
            });
          }
          _waitingForPlaybackBuffer = !ready;
          if (!ready) return;
        }
        _lastAnalysisEnd = end;
        unawaited(_recognize(_epoch, segment.asset, reacquiring: reacquiring));
      }
    } catch (error) {
      AppDiagnostics.instance.log('client_asr_sample_error', {
        'errorType': error.runtimeType.toString(),
      });
      phase = SubtitlePhase.serviceUnavailable;
      onChanged();
    } finally {
      _sampling = false;
    }
  }

  Future<void> _observe(
    double start,
    double end,
    List<dynamic> words,
    int epoch,
    String asset,
    bool ad, {
    String? audioLanguage,
  }) async {
    if (_disposed ||
        epoch != _epoch ||
        _session == null ||
        _variants.awaitingRefresh) {
      return;
    }
    try {
      final serial = ++_serial;
      final request = _variants.request;
      final response = await _post('sessions/$_session/observations', {
        'source': _source,
        'programme': _programme,
        'programmeKey': _programme?['key'],
        'language': request.query['language'],
        'sourceClock': segmentAt(math.max(0, end - .01))?.sourceClock,
        'epoch': epoch,
        'asset': asset,
        'ad': ad,
        'start': math.max(0, start),
        'end': end,
        'position': player.state.position.inMicroseconds / 1e6,
        'words': words,
        if (audioLanguage != null && _audioLanguageSupported)
          'audioLanguage': audioLanguage,
        'serial': serial,
      });
      if (!_disposed && epoch == _epoch) {
        _accept(response, request, acknowledgesRequest: false);
      }
    } catch (error) {
      AppDiagnostics.instance.log('client_subtitle_observation_error', {
        'errorType': error.runtimeType.toString(),
      });
    }
  }

  Future<Map<String, dynamic>?> _recognizeWithSystem(
    OfflineAsrRequest request,
    int epoch,
  ) async {
    final executable = ClientSubtitleRuntime.systemAsr;
    final locale = request.audioLocale;
    if (executable == null || locale == null) return null;
    if (_systemAsrRetry[locale]?.isAfter(DateTime.now()) ?? false) return null;
    Process? process;
    try {
      process = await Process.start(executable, [request.pcmPath, locale]);
      final stdout = process.stdout.transform(utf8.decoder).join();
      final stderr = process.stderr.drain<void>();
      final code = await process.exitCode.timeout(const Duration(seconds: 3));
      await stderr;
      final output = await stdout;
      if (code == 0 && output.isNotEmpty) {
        final result = jsonDecode(output) as Map<String, dynamic>;
        final words = result['words'] as List;
        if (words.any((word) => (word['probability'] as num) >= .65)) {
          return {'id': epoch, 'words': words, 'audioLanguage': locale};
        }
      }
    } catch (_) {
      if (process != null) {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode;
      }
    }
    _systemAsrRetry[locale] = DateTime.now().add(const Duration(seconds: 30));
    return null;
  }

  Future<void> _recognize(
    int epoch,
    String asset, {
    required bool reacquiring,
  }) async {
    _recognizing = true;
    File? file;
    try {
      final chunks = _chunks.toList();
      if (chunks.isEmpty || _directory == null || _disposed) return;
      final window = buildPcmWindow(chunks);
      if (window == null || window.bytes.isEmpty) return;
      final start = window.start;
      final bytes = window.bytes;
      final directory = _directory!;
      await directory.create(recursive: true);
      if (_disposed) return;
      file = File('${directory.path}/window.pcm');
      final input = prepareRecognitionPcm(bytes);
      await file.writeAsBytes(input.bytes, flush: true);
      final hint = subtitleLanguage(player.state.track.audio.language);
      final trackId = player.state.track.audio.id;
      final timeout = reacquiring
          ? _playbackBudget.recoveryTimeoutSeconds(window.duration)
          : 40.0;
      final response = Platform.isIOS
          ? <String, dynamic>{
              ...await IosNativeMedia.recognize(
                file.path,
                hint,
                id: _iosRecognitionId =
                    '$label-$epoch-${DateTime.now().microsecondsSinceEpoch}',
              ),
              'id': epoch,
            }
          : await recognizeOffline<Map<String, dynamic>>(
              (pcmPath: file.path, audioLocale: hint),
              isCurrent: () =>
                  !_disposed &&
                  epoch == _epoch &&
                  player.state.track.audio.id == trackId,
              system: (request) => _recognizeWithSystem(request, epoch),
              whisper: (request) {
                final future = _recognition = Completer<Map<String, dynamic>>();
                final legacy =
                    ClientSubtitleRuntime.model?.endsWith('.en-q5_1.bin') ==
                    true;
                final workerLanguage = legacy
                    ? null
                    : request.audioLocale?.split('-').first;
                _worker!.stdin.writeln(
                  jsonEncode({
                    'path': request.pcmPath,
                    'id': epoch,
                    'audioLanguage': ?workerLanguage,
                  }),
                );
                return future.future.timeout(
                  Duration(milliseconds: (timeout * 1000).ceil()),
                );
              },
            );
      if (response == null ||
          _disposed ||
          epoch != _epoch ||
          player.state.track.audio.id != trackId)
        return;
      final words = response['words'] as List? ?? [];
      final seconds = response['processSeconds'];
      if (seconds is num) {
        _playbackBudget.record(window.duration, seconds.toDouble());
      }
      _workerFailures = 0;
      if (words.isNotEmpty) _coldRecognition = false;
      AppDiagnostics.instance.log('client_asr_window', {
        'epoch': epoch,
        'start': start,
        'end': start + bytes.length / 32000,
        'words': words.length,
        'processSeconds': response['processSeconds'],
        'captureGapSeconds': window.gapSeconds,
        'inputGain': input.gain,
        'error': response['error'],
      });
      final detected =
          response['audioLanguage'] ??
          (ClientSubtitleRuntime.model?.endsWith('.en-q5_1.bin') == true &&
                  (hint == null || hint == 'en')
              ? 'en'
              : null);
      final audioLanguage = detected == 'zh'
          ? (hint == 'zh-TW' ? 'zh-TW' : 'zh-CN')
          : subtitleLanguage(detected is String ? detected : null);
      if (!_disposed &&
          epoch == _epoch &&
          response['id'] == epoch &&
          (words.isEmpty ||
              audioLanguage == 'en' ||
              (_audioLanguageSupported && audioLanguage != null))) {
        final end = start + bytes.length / 32000;
        final reliableWords = words.where((word) {
          final confidence = (word as Map)['probability'];
          return confidence is num && confidence >= .65;
        });
        if (reliableWords.length >= 4 && _ad == false && asset == _asset) {
          _lastSpeech = (
            start: start,
            end: end,
            words: words,
            epoch: epoch,
            asset: asset,
            audioLanguage: audioLanguage,
            programmeKey: _programme?['key'],
          );
        }
        await _observe(
          start,
          end,
          words,
          epoch,
          asset,
          false,
          audioLanguage: audioLanguage,
        );
      }
    } catch (error) {
      _workerFailed = true;
      _recoveryTimedOut = reacquiring && error is TimeoutException;
      if (!_transportLocked) _timeline = null;
      _worker?.kill();
      render();
      _scheduleWorkerRetry();
      AppDiagnostics.instance.log('client_asr_recognition_error', {
        'errorType': error.runtimeType.toString(),
      });
    } finally {
      _recognition = null;
      _iosRecognitionId = null;
      try {
        if (file != null && await file.exists()) await file.delete();
      } catch (_) {}
      _recognizing = false;
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    final iosId = _iosRecognitionId;
    if (Platform.isIOS && iosId != null) {
      await IosNativeMedia.channel.invokeMethod<void>('cancelRecognition', {
        'id': iosId,
      });
    }
    _startupRetry?.cancel();
    _workerRetry?.cancel();
    _timer?.cancel();
    _poll?.cancel();
    _client.close();
    _worker?.kill();
    await _lines?.cancel();
    if (_attached) {
      try {
        await _native?.command(['af', 'remove', '@$label']);
      } catch (_) {}
    }
    try {
      await _directory?.delete(recursive: true);
    } catch (_) {}
    AppDiagnostics.instance.log('client_subtitle_traffic', {
      'uploadedTextBytes': uploadedBytes,
      'downloadedSubtitleBytes': downloadedBytes,
      'uploadedAudioBytes': 0,
      'serverVideoBytes': 0,
    });
  }
}
