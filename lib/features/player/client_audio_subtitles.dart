import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import '../../core/app_diagnostics.dart';
import '../../core/server_egress.dart';
import 'hls_buffer_proxy.dart';
import 'client_subtitle_runtime.dart';
import 'live_subtitle_timeline.dart';
import 'subtitle_policy.dart';
import 'subtitle_preferences.dart';
import 'subtitle_status.dart';

/// One local decoder tap and offline ASR worker per viewing session. Only text
/// observations cross the service boundary; video and PCM stay on the device.
class ClientAudioSubtitles {
  ClientAudioSubtitles(
    this.player,
    this.endpoint,
    this.segmentAt, {
    required this.onChanged,
  });
  final Player player;
  final Uri endpoint;
  final HlsPlaybackSegment? Function(double) segmentAt;
  final VoidCallback onChanged;
  static int _nextLabel = 0;
  final label = 'bobtv_pcm_${_nextLabel++}';
  static bool get supported => ClientSubtitleRuntime.available;
  String text = '';
  SubtitlePhase phase = SubtitlePhase.searching;
  String? _source, _session;
  Map<String, dynamic>? _programme;
  LiveSubtitleTimeline? _timeline;
  Process? _worker;
  Directory? _directory;
  StreamSubscription<String>? _lines;
  Timer? _timer, _poll;
  final _client = http.Client();
  bool _polling = false;
  Completer<Map<String, dynamic>>? _recognition;
  bool _disposed = false,
      _sampling = false,
      _recognizing = false,
      _active = false;
  bool _attached = false, _workerFailed = false;
  int _epoch = 0, _nativeEpoch = -1, _sequence = -1, _serial = 0;
  String? _asset;
  bool? _ad;
  double _lastEnd = -1, _lastAnalysisEnd = -1;
  final _chunks = <({double start, Uint8List bytes})>[];
  List<String> _languages = [];
  DateTime _lastResponse = DateTime(1970);
  int uploadedBytes = 0, downloadedBytes = 0;
  NativePlayer? get _native =>
      player.platform is NativePlayer ? player.platform as NativePlayer : null;
  Future<void> start(String source, Map<String, Object?>? programme) async {
    _source = source;
    final body = await _post('sessions', {
      'source': source,
      'programme': programme,
      'language': SubtitlePreferences.instance.language.tag,
      'features': ['clientClockV1'],
    });
    if (_disposed) return;
    _session = body['session'] as String;
    _accept(body);
    _directory = await Directory.systemTemp.createTemp('bobtv-client-asr-');
    if (_disposed) {
      await _directory?.delete(recursive: true);
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
          try {
            final message = jsonDecode(line) as Map<String, dynamic>;
            if (message['ready'] == true && !ready.isCompleted) {
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
      worker.exitCode.then((_) {
        if (!ready.isCompleted) {
          ready.completeError(StateError('Offline ASR worker exited'));
        }
        if (_recognition != null && !_recognition!.isCompleted) {
          _recognition!.completeError(StateError('Offline ASR worker exited'));
        }
      }),
    );
    await ready.future.timeout(const Duration(seconds: 30));
    if (_disposed) return;
    _poll = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_refresh()),
    );
    _timer = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => unawaited(_tick()),
    );
    AppDiagnostics.instance.log('client_asr_ready', {
      'engine': 'whisper.cpp-v1.8.2',
      'audioUploaded': false,
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
      throw HttpException('Subtitle response ${response.statusCode}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<void> _refresh() async {
    if (_disposed || _polling || _session == null) return;
    _polling = true;
    try {
      final response = await _client
          .get(endpoint.resolve('sessions/$_session'))
          .timeout(const Duration(seconds: 5));
      downloadedBytes += response.bodyBytes.length;
      if (_disposed) return;
      if (response.statusCode == 200) {
        _accept(jsonDecode(response.body) as Map<String, dynamic>);
      } else if (response.statusCode == 404) {
        final body = await _post('sessions', {
          'source': _source,
          'programme': null,
          'language': SubtitlePreferences.instance.language.tag,
          'features': ['clientClockV1'],
        });
        if (_disposed) return;
        _session = body['session'] as String;
        _epoch++;
        _chunks.clear();
        _timeline = null;
        _asset = null;
        _lastEnd = -1;
        _lastAnalysisEnd = -1;
        _accept(body);
      }
    } catch (_) {
    } finally {
      _polling = false;
    }
  }

  void _accept(Map<String, dynamic> body) {
    if (_disposed || body['session'] != _session && _session != null) return;
    final programme = body['programme'];
    if (programme is Map) _programme = Map<String, dynamic>.from(programme);
    final status = body['subtitleStatus'] as Map?;
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
    _timeline = LiveSubtitleTimeline.decode(
      body,
      session: _session!,
      source: _source!,
    );
    _lastResponse = DateTime.now();
    render();
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
    } else if (_workerFailed) {
      phase = SubtitlePhase.serviceUnavailable;
    } else if (segment?.ad == true) {
      phase = SubtitlePhase.suspended;
    } else if (fresh &&
        segment != null &&
        segment.movieId == _programme?['movieId']) {
      if (_active && player.state.playing && !player.state.buffering) {
        text =
            _timeline?.textAt(
              position,
              SubtitlePreferences.instance.language.tag,
            ) ??
            '';
      }
      if (_timeline?.windowAt(position)?['state'] == 'LOCKED') {
        final selected = selectSubtitle(
          _languages,
          SubtitlePreferences.instance.language.tag,
          language: (v) => v,
        );
        phase = selected == null
            ? SubtitlePhase.unavailable
            : subtitleLanguage(selected) == 'en' &&
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
    _workerFailed = true;
    _timeline = null;
    text = '';
    phase = SubtitlePhase.serviceUnavailable;
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
      if (!SubtitlePreferences.instance.enabled || _workerFailed) return;
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
      final ad = segment.ad || segment.movieId != _programme?['movieId'];
      if (_asset != segment.asset || _ad != ad || _nativeEpoch != nativeEpoch) {
        _epoch++;
        _asset = segment.asset;
        _ad = ad;
        _nativeEpoch = nativeEpoch;
        _chunks.clear();
        _lastEnd = end;
        _lastAnalysisEnd = -1;
        _timeline = null;
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
      if (ad) return;
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
      _chunks.removeWhere((c) => c.start + c.bytes.length / 32000 < end - 32);
      final duration = _chunks.isEmpty ? 0 : end - _chunks.first.start;
      if (!_recognizing && duration >= 12 && end - _lastAnalysisEnd >= 6) {
        _lastAnalysisEnd = end;
        unawaited(_recognize(_epoch, segment.asset));
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
    bool ad,
  ) async {
    if (_disposed || epoch != _epoch || _session == null) return;
    try {
      final serial = ++_serial;
      final response = await _post('sessions/$_session/observations', {
        'source': _source,
        'programme': _programme,
        'programmeKey': _programme?['key'],
        'epoch': epoch,
        'asset': asset,
        'ad': ad,
        'start': math.max(0, start),
        'end': end,
        'words': words,
        'serial': serial,
      });
      if (!_disposed && epoch == _epoch) _accept(response);
    } catch (error) {
      AppDiagnostics.instance.log('client_subtitle_observation_error', {
        'errorType': error.runtimeType.toString(),
      });
    }
  }

  Future<void> _recognize(int epoch, String asset) async {
    _recognizing = true;
    File? file;
    try {
      final chunks = _chunks.toList();
      if (chunks.isEmpty || _directory == null || _disposed) return;
      final start = chunks.first.start;
      final data = BytesBuilder(copy: false);
      for (final c in chunks) {
        data.add(c.bytes);
      }
      final bytes = data.takeBytes();
      file = File('${_directory!.path}/window.pcm');
      await file.writeAsBytes(bytes, flush: true);
      final future = _recognition = Completer<Map<String, dynamic>>();
      _worker!.stdin.writeln(jsonEncode({'path': file.path, 'id': epoch}));
      final response = await future.future.timeout(const Duration(seconds: 40));
      final words = response['words'] as List? ?? [];
      AppDiagnostics.instance.log('client_asr_window', {
        'epoch': epoch,
        'start': start,
        'end': start + bytes.length / 32000,
        'words': words.length,
        'processSeconds': response['processSeconds'],
        'error': response['error'],
      });
      if (!_disposed && epoch == _epoch && response['id'] == epoch) {
        await _observe(
          start,
          start + bytes.length / 32000,
          words,
          epoch,
          asset,
          false,
        );
      }
    } catch (error) {
      _workerFailed = true;
      _timeline = null;
      _worker?.kill();
      failed();
      AppDiagnostics.instance.log('client_asr_recognition_error', {
        'errorType': error.runtimeType.toString(),
      });
    } finally {
      _recognition = null;
      try {
        if (file != null && await file.exists()) await file.delete();
      } catch (_) {}
      _recognizing = false;
    }
  }

  Future<void> dispose() async {
    _disposed = true;
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
