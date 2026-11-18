import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import '../../core/app_diagnostics.dart';
import '../../core/server_egress.dart';
import 'live_subtitle_timeline.dart';
import 'native_subtitle_selection.dart';
import 'subtitle_preferences.dart';
import 'subtitle_programme_context.dart';
import 'subtitle_status.dart';
import 'subtitle_media_recovery.dart';
import 'subtitle_policy.dart';
import 'hls_buffer_proxy.dart';
import 'client_audio_subtitles.dart';
import 'client_subtitle_runtime.dart';

/// Optional synchronization service. Video remains one continuous decoder;
/// caption fetches never reload media or move the playhead.
class LiveSubtitleSession {
  LiveSubtitleSession(
    this.player,
    this.selection, {
    http.Client? client,
    this.serviceEndpoint = endpoint,
    this.programmeLookup,
  }) : _client = client ?? http.Client() {
    _position = player.stream.position.listen((position) => _render());
    _buffering = player.stream.buffering.listen((_) => _render());
    _playing = player.stream.playing.listen((_) => _render());
    SubtitlePreferences.instance.addListener(_render);
    selection.selected.addListener(_render);
  }
  HlsPlaybackSegment? Function(double)? segmentAt;
  ClientAudioSubtitles? _localAudio;
  bool get usesClientAudio => _localAudio != null;
  static const endpoint = String.fromEnvironment(
    'BOBTV_SUBTITLE_SERVICE',
    defaultValue: 'https://bobtv.briconbric.com/api/v1/subtitles/',
  );
  final Player player;
  final NativeSubtitleSelection selection;
  final String serviceEndpoint;
  final SubtitleProgrammeLookup? programmeLookup;
  final text = ValueNotifier<String>('');
  final status = ValueNotifier<SubtitlePhase>(SubtitlePhase.idle);
  SubtitlePhase _phase = SubtitlePhase.idle;
  String? _remotePhase;
  List<String> _availableLanguages = const [];
  bool _mediaAttached = false;
  bool get hasAttachedMedia => _mediaAttached || usesClientAudio;
  bool get hasVerifiedLocalCaptions {
    final phase = _localAudio?.phase;
    return phase == SubtitlePhase.ready ||
        phase == SubtitlePhase.englishFallback;
  }

  bool _playbackReady = false;
  Future<void> Function()? onMediaReady;
  Future<bool> Function()? onRecoveryMediaReady;
  SubtitleMediaRecovery? _mediaRecovery;
  Timer? _retry;
  bool _autoConnecting = false;
  DateTime? _nextConnectAttempt;
  final http.Client _client;
  StreamSubscription<Duration>? _position;
  StreamSubscription<bool>? _buffering, _playing;
  Map<String, Object?>? _programme;
  bool _requiresProgramme = false;
  bool _programmeAcknowledged = false;
  Uri? _base;
  String? _session, _source;
  DateTime? _lastProgrammeCheck;
  Timer? _poll;
  Timer? _expiry;
  LiveSubtitleTimeline? _timeline;
  int _generation = 0;
  bool _disposed = false;
  bool _active = false;

  Future<String> prepare(String source, {bool monitorOnly = false}) async {
    final wasActive = _active;
    clear();
    if (monitorOnly) {
      _active = wasActive;
    }
    _source = source;
    final generation = _generation;
    _phase = SubtitlePhase.searching;
    _render();
    Map<String, Object?>? context;
    try {
      context = await (programmeLookup ?? SubtitleProgrammeContext.lookup)
          ?.call(source)
          .timeout(const Duration(milliseconds: 500));
    } catch (_) {}
    final production = const {
      'bobtv.briconbric.com',
      'cndrp.com',
    }.contains(Uri.tryParse(serviceEndpoint)?.host);
    if (production &&
        context == null &&
        !isReviewedRakutenUkMovieSource(source)) {
      _phase = SubtitlePhase.programmeUnavailable;
      _render();
      _retryDiscovery(source, generation);
      return source;
    }
    await ClientSubtitleRuntime.initialize();
    if (_disposed || generation != _generation) return source;
    if (ClientAudioSubtitles.supported &&
        (production || isActionMoviesUk(source)) &&
        segmentAt != null) {
      final local = ClientAudioSubtitles(
        player,
        Uri.parse(serviceEndpoint).resolve('client/'),
        segmentAt!,
        onChanged: () {
          final current = _localAudio;
          if (current != null && !_disposed) {
            final requested = subtitleLanguage(
              SubtitlePreferences.instance.language.tag,
            );
            final nativePreferred = player.state.tracks.subtitle.any(
              (track) =>
                  track.id != 'no' &&
                  track.id != 'auto' &&
                  !(track.title?.toLowerCase().contains('forced') ?? false) &&
                  subtitleLanguage(track.language) == requested,
            );
            final external =
                const {
                  SubtitlePhase.ready,
                  SubtitlePhase.englishFallback,
                  SubtitlePhase.suspended,
                }.contains(current.phase) &&
                !(nativePreferred &&
                    current.phase == SubtitlePhase.englishFallback);
            text.value = external ? current.text : '';
            final native = selection.selected.value;
            status.value =
                !external &&
                    native != null &&
                    SubtitlePreferences.instance.enabled
                ? subtitleLanguage(native.language) == 'en' && requested != 'en'
                      ? SubtitlePhase.englishFallback
                      : SubtitlePhase.ready
                : current.phase;
            if (selection.external != external) {
              selection.external = external;
              selection.refresh();
            }
          }
        },
      );
      _localAudio = local;
      unawaited(
        local.start(source, context).catchError((Object error) {
          local.failed();
          AppDiagnostics.instance.log('client_subtitle_start_error', {
            'errorType': error.runtimeType.toString(),
          });
        }),
      );
      // A late EPG result needs a newly prepared local media clock. The owner
      // keeps the original decoder visible while the candidate buffers.
      if (monitorOnly && wasActive && onMediaReady != null) {
        unawaited(onMediaReady!());
      }
      return source;
    }
    if (production || isActionMoviesUk(source)) {
      // Missing local tools must not reactivate the legacy server video reader.
      _phase = SubtitlePhase.serviceUnavailable;
      _render();
      return source;
    }
    if (serviceEndpoint.isEmpty) return source;
    try {
      final base = Uri.parse(serviceEndpoint);
      // Only our API nodes and explicit local development services are allowed.
      if (!ServerEgress.canConnect(base)) {
        _phase = SubtitlePhase.serviceUnavailable;
        _render();
        _retryDiscovery(source, generation);
        return source;
      }
      final lookup = programmeLookup ?? SubtitleProgrammeContext.lookup;
      _programme = await lookup
          ?.call(source)
          .timeout(const Duration(milliseconds: 500));
      if (_disposed || generation != _generation) return source;
      final local = const {'127.0.0.1', 'localhost', '::1'}.contains(base.host);
      // External production discovery accepts only a bound public EPG route.
      if (!local && _programme == null) {
        _phase = isActionMoviesUk(source)
            ? SubtitlePhase.programmeUnavailable
            : SubtitlePhase.unavailable;
        _render();
        if (isActionMoviesUk(source)) _retryDiscovery(source, generation);
        return source;
      }
      _requiresProgramme = _programme != null;
      _lastProgrammeCheck = DateTime.now();
      final response = await _client
          .post(
            base.resolve('sessions'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'source': source,
              'features': [
                'subtitleStatusV1',
                'positionWindowV1',
                'autoConnectV1',
              ],
              'language': SubtitlePreferences.instance.language.tag,
              if (_programme != null) 'programme': _programme,
            }),
          )
          .timeout(const Duration(seconds: 3));
      if (_disposed || generation != _generation) return source;
      if (response.statusCode != 200) {
        _phase =
            const {404, 422}.contains(response.statusCode) &&
                !isActionMoviesUk(source)
            ? SubtitlePhase.unavailable
            : SubtitlePhase.serviceUnavailable;
        _render();
        _retryDiscovery(source, generation);
        return source;
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      _playbackReady = data['playbackReady'] == true;
      final session = data['session'] as String;
      final playback = Uri.parse(data['playbackUrl'] as String);
      if (!ServerEgress.canConnect(playback)) {
        _phase = SubtitlePhase.serviceUnavailable;
        _render();
        return source;
      }
      _base = base;
      _session = session;
      _source = source;
      _mediaAttached = _playbackReady && !monitorOnly;
      _accept(data, session, source);
      _startPolling(base, session, source, generation);
      return _mediaAttached ? playback.toString() : source;
    } catch (error) {
      if (!_disposed && generation == _generation) {
        _phase = SubtitlePhase.serviceUnavailable;
        _render();
        _retryDiscovery(source, generation);
        AppDiagnostics.instance.log('subtitle_session_unavailable', {
          'errorType': error.runtimeType.toString(),
        });
      }
      return source;
    }
  }

  void _startPolling(Uri base, String session, String source, int generation) {
    _poll = Timer.periodic(const Duration(milliseconds: 500), (_) async {
      // One outstanding request at a time, even on a slow service.
      if (_fetching || _disposed || generation != _generation) return;
      _fetching = true;
      try {
        if (DateTime.now()
                .difference(_lastProgrammeCheck ?? DateTime(1970))
                .inSeconds >=
            5) {
          await _refreshProgramme(base, session, source, generation);
        }
        final result = await _client
            .get(
              base
                  .resolve('sessions/${Uri.encodeComponent(session)}')
                  .replace(
                    queryParameters: _mediaAttached
                        ? {
                            'position':
                                (player.state.position.inMicroseconds /
                                        Duration.microsecondsPerSecond)
                                    .toStringAsFixed(3),
                          }
                        : null,
                  ),
            )
            .timeout(const Duration(seconds: 2));
        if (!_disposed &&
            generation == _generation &&
            result.statusCode == 200) {
          _accept(
            jsonDecode(result.body) as Map<String, dynamic>,
            session,
            source,
          );
        } else if (!_disposed &&
            generation == _generation &&
            const {404, 410}.contains(result.statusCode)) {
          _retryDiscovery(source, generation);
        }
      } catch (_) {
        // The short lease below clears captions if refreshes stop.
      } finally {
        _fetching = false;
      }
    });
  }

  void _retryDiscovery(String source, int generation) {
    if (_retry?.isActive ?? false) return;
    _retry = Timer(const Duration(seconds: 30), () {
      if (!_disposed && generation == _generation) {
        unawaited(prepare(source, monitorOnly: true));
      }
    });
  }

  Future<String> attachReadyMedia(String source) async {
    final base = _base, session = _session;
    if (base == null || session == null || source != _source) {
      throw const FormatException('Subtitle discovery session expired');
    }
    final wasActive = _active;
    final generation = ++_generation;
    _poll?.cancel();
    _expiry?.cancel();
    _timeline = null;
    _mediaAttached = false;
    _active = false;
    _phase = SubtitlePhase.connecting;
    _render();
    try {
      final response = await _client
          .post(
            base.resolve('sessions/${Uri.encodeComponent(session)}/connect'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'source': source, 'programme': _programme}),
          )
          .timeout(const Duration(seconds: 3));
      if (_disposed ||
          generation != _generation ||
          response.statusCode != 200) {
        throw const FormatException('Subtitle media connection unavailable');
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final playback = Uri.parse(data['playbackUrl'] as String);
      if (data['playbackReady'] != true || !ServerEgress.canConnect(playback)) {
        throw const FormatException('Subtitle media is not ready');
      }
      _mediaAttached = true;
      _accept(data, session, source);
      _startPolling(base, session, source, generation);
      return playback.toString();
    } catch (_) {
      if (!_disposed && generation == _generation) {
        _active = wasActive;
        _mediaAttached = false;
        _timeline = null;
        selection.external = false;
        selection.refresh();
        _phase = SubtitlePhase.serviceUnavailable;
        _render();
        _startPolling(base, session, source, generation);
      }
      rethrow;
    }
  }

  void mediaClockUnavailable() {
    _localAudio?.clockUnavailable();
  }

  void mediaUnavailable(String source) {
    _source = source;
    _localAudio?.clockUnavailable();
    _phase = SubtitlePhase.clockUnavailable;
    _render();
    if (onRecoveryMediaReady == null) {
      _retryDiscovery(source, _generation);
      return;
    }
    _retry?.cancel();
    final recovery = _mediaRecovery ??= SubtitleMediaRecovery(
      sample: () {
        final state = player.state;
        return (
          playing: state.playing,
          buffering: state.buffering,
          position: state.position,
        );
      },
      enabled: () =>
          _active && !_disposed && SubtitlePreferences.instance.enabled,
      warm: () async {
        final attempt = onRecoveryMediaReady;
        if (attempt == null) return false;
        AppDiagnostics.instance.log('subtitle_media_recovery_started');
        return attempt();
      },
    );
    recovery.start();
  }

  void _maybeConnect() {
    if (_disposed ||
        !_active ||
        !player.state.playing ||
        _mediaAttached ||
        !_playbackReady ||
        _remotePhase != 'matched' ||
        !_hasUsableLanguage ||
        !SubtitlePreferences.instance.enabled ||
        _autoConnecting ||
        onMediaReady == null ||
        (_nextConnectAttempt?.isAfter(DateTime.now()) ?? false)) {
      return;
    }
    _autoConnecting = true;
    _nextConnectAttempt = DateTime.now().add(const Duration(seconds: 15));
    final generation = _generation;
    Future<void>.microtask(() async {
      try {
        if (!_disposed && generation == _generation) await onMediaReady?.call();
      } catch (_) {
        // The provider remains in use; the status lease and poll drive retries.
      } finally {
        _autoConnecting = false;
      }
    });
  }

  bool _fetching = false;

  /// Refreshes programme discovery without reopening or seeking the decoder.
  Future<void> refreshProgramme() async {
    if (!_disposed &&
        !_fetching &&
        _source != null &&
        (_base == null || _session == null)) {
      await prepare(_source!, monitorOnly: true);
      return;
    }
    if (_fetching ||
        _disposed ||
        _base == null ||
        _session == null ||
        _source == null) {
      return;
    }
    _fetching = true;
    try {
      await _refreshProgramme(_base!, _session!, _source!, _generation);
    } catch (_) {
      // A stale programme acknowledgement keeps captions empty.
    } finally {
      _fetching = false;
    }
  }

  Future<void> _refreshProgramme(
    Uri base,
    String session,
    String source,
    int generation,
  ) async {
    final lookup = programmeLookup ?? SubtitleProgrammeContext.lookup;
    _lastProgrammeCheck = DateTime.now();
    if (lookup == null) return;
    final next = await lookup(
      source,
    ).timeout(const Duration(milliseconds: 500));
    if (_disposed || generation != _generation) return;
    if (next?['key'] == _programme?['key'] && _programmeAcknowledged) return;
    _programmeAcknowledged = false;
    _programme = next;
    _requiresProgramme = _requiresProgramme || next != null;
    _timeline = null;
    _phase = SubtitlePhase.programmeUnavailable;
    _remotePhase = null;
    _availableLanguages = const [];
    _render();
    final response = await _client
        .post(
          base.resolve('sessions/${Uri.encodeComponent(session)}/programme'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'source': source, 'programme': next}),
        )
        .timeout(const Duration(seconds: 2));
    if (!_disposed && generation == _generation && response.statusCode == 200) {
      _accept(
        jsonDecode(response.body) as Map<String, dynamic>,
        session,
        source,
      );
    }
  }

  void _accept(Map<String, dynamic> data, String session, String source) {
    if (_requiresProgramme &&
        (_programme == null || data['programmeKey'] != _programme!['key'])) {
      throw const FormatException('Subtitle programme requires reacquisition');
    }
    final timeline = LiveSubtitleTimeline.decode(
      data,
      session: session,
      source: source,
    );
    _timeline = _mediaAttached ? timeline : null;
    _playbackReady = data['playbackReady'] == true;
    final metadata = data['subtitleStatus'];
    _remotePhase = metadata is Map ? metadata['phase'] as String? : null;
    final languages = metadata is Map ? metadata['availableLanguages'] : null;
    _availableLanguages = languages is List
        ? languages.whereType<String>().toList()
        : const [];
    _phase = switch (_remotePhase) {
      'unavailable' => SubtitlePhase.unavailable,
      'service_unavailable' => SubtitlePhase.serviceUnavailable,
      'programme_unavailable' => SubtitlePhase.programmeUnavailable,
      'searching' => SubtitlePhase.searching,
      _ => _playbackReady ? SubtitlePhase.synchronizing : SubtitlePhase.warming,
    };
    if (!_mediaAttached && _playbackReady && _remotePhase == 'matched') {
      _phase = _hasUsableLanguage
          ? SubtitlePhase.connecting
          : SubtitlePhase.unavailable;
    }
    _programmeAcknowledged = true;
    if (_mediaAttached && !selection.external) {
      selection.external = true;
      selection.refresh();
    }
    _expiry?.cancel();
    _expiry = Timer(const Duration(seconds: 3), () {
      _timeline = null;
      if (!_disposed) {
        _phase = SubtitlePhase.serviceUnavailable;
        _remotePhase = null;
        _availableLanguages = const [];
        _render();
        selection.external = false;
        selection.refresh();
      }
    });
    _render();
  }

  bool get _hasUsableLanguage =>
      selectSubtitle(
        _availableLanguages,
        SubtitlePreferences.instance.language.tag,
        language: (language) => language,
      ) !=
      null;

  void _render() {
    if (_disposed) return;
    if (_localAudio != null) {
      _localAudio!.render();
      return;
    }
    final prefs = SubtitlePreferences.instance;
    final position =
        player.state.position.inMicroseconds / Duration.microsecondsPerSecond;
    text.value =
        !prefs.enabled ||
            !_active ||
            !_mediaAttached ||
            !player.state.playing ||
            player.state.buffering
        ? ''
        : _timeline?.textAt(position, prefs.language.tag) ?? '';
    var phase = _phase;
    if (!prefs.enabled) {
      phase = SubtitlePhase.idle;
    } else if (!selection.external && selection.selected.value != null) {
      phase =
          subtitleLanguage(selection.selected.value!.language) == 'en' &&
              subtitleLanguage(prefs.language.tag) != 'en'
          ? SubtitlePhase.englishFallback
          : SubtitlePhase.ready;
    } else if (_mediaAttached && _timeline != null && _active) {
      final window = _timeline!.windowAt(position);
      if (window?['state'] == 'SUSPENDED' &&
          !const {
            SubtitlePhase.unavailable,
            SubtitlePhase.serviceUnavailable,
            SubtitlePhase.programmeUnavailable,
            SubtitlePhase.searching,
          }.contains(_phase)) {
        phase = SubtitlePhase.suspended;
      } else if (window?['state'] == 'LOCKED') {
        final tracks = (window?['tracks'] as List? ?? const [])
            .whereType<Map>()
            .where((t) => t['verified'] == true)
            .map((t) => t['language'])
            .whereType<String>();
        final languages = {..._availableLanguages, ...tracks};
        final selected = selectSubtitle(
          languages,
          prefs.language.tag,
          language: (language) => language,
        );
        if (selected != null) {
          phase =
              subtitleLanguage(selected) == 'en' &&
                  subtitleLanguage(prefs.language.tag) != 'en'
              ? SubtitlePhase.englishFallback
              : SubtitlePhase.ready;
        } else if (_remotePhase == 'matched') {
          phase = SubtitlePhase.unavailable;
        }
      }
    } else if (!_mediaAttached && _playbackReady && _remotePhase == 'matched') {
      phase = _hasUsableLanguage
          ? SubtitlePhase.connecting
          : SubtitlePhase.unavailable;
    }
    status.value = phase;
    _maybeConnect();
  }

  void clear() {
    final audio = _localAudio;
    _localAudio = null;
    if (audio != null) unawaited(audio.dispose());
    ++_generation;
    _poll?.cancel();
    _expiry?.cancel();
    _retry?.cancel();
    _nextConnectAttempt = null;
    _mediaRecovery?.cancel();
    _mediaRecovery = null;
    _timeline = null;
    _programme = null;
    _requiresProgramme = false;
    _programmeAcknowledged = false;
    _base = null;
    _session = null;
    _source = null;
    _active = false;
    _mediaAttached = false;
    _playbackReady = false;
    _phase = SubtitlePhase.idle;
    _remotePhase = null;
    _availableLanguages = const [];
    status.value = SubtitlePhase.idle;
    text.value = '';
    selection.external = false;
    selection.refresh();
  }

  void activate() {
    _localAudio?.activate();
    _active = true;
    _render();
  }

  Future<void> dispose() async {
    clear();
    _disposed = true;
    _client.close();
    SubtitlePreferences.instance.removeListener(_render);
    selection.selected.removeListener(_render);
    await _position?.cancel();
    await _buffering?.cancel();
    await _playing?.cancel();
    text.dispose();
    status.dispose();
  }
}
