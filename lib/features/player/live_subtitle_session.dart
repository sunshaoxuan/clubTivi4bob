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
  }
  static const endpoint = String.fromEnvironment(
    'BOBTV_SUBTITLE_SERVICE',
    defaultValue: 'https://bobtv.briconbric.com/api/v1/subtitles/',
  );
  final Player player;
  final NativeSubtitleSelection selection;
  final String serviceEndpoint;
  final SubtitleProgrammeLookup? programmeLookup;
  final text = ValueNotifier<String>('');
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

  Future<String> prepare(String source) async {
    clear();
    if (serviceEndpoint.isEmpty) return source;
    final generation = _generation;
    try {
      final base = Uri.parse(serviceEndpoint);
      // Only our API nodes and explicit local development services are allowed.
      if (!ServerEgress.canConnect(base)) return source;
      final lookup = programmeLookup ?? SubtitleProgrammeContext.lookup;
      _programme = await lookup
          ?.call(source)
          .timeout(const Duration(milliseconds: 500));
      if (_disposed || generation != _generation) return source;
      final local = const {'127.0.0.1', 'localhost', '::1'}.contains(base.host);
      // External production discovery accepts only a bound public EPG route.
      if (!local && _programme == null) return source;
      _requiresProgramme = _programme != null;
      _lastProgrammeCheck = DateTime.now();
      final response = await _client
          .post(
            base.resolve('sessions'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'source': source,
              'language': SubtitlePreferences.instance.language.tag,
              if (_programme != null) 'programme': _programme,
            }),
          )
          .timeout(const Duration(seconds: 3));
      if (_disposed ||
          generation != _generation ||
          response.statusCode != 200) {
        return source;
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      // Optional caption media must be ready before replacing the provider URL.
      if (data['playbackReady'] != true) return source;
      final session = data['session'] as String;
      final playback = Uri.parse(data['playbackUrl'] as String);
      if (!ServerEgress.canConnect(playback)) return source;
      _base = base;
      _session = session;
      _source = source;
      _accept(data, session, source);
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
              .get(base.resolve('sessions/${Uri.encodeComponent(session)}'))
              .timeout(const Duration(seconds: 2));
          if (!_disposed &&
              generation == _generation &&
              result.statusCode == 200) {
            _accept(
              jsonDecode(result.body) as Map<String, dynamic>,
              session,
              source,
            );
          }
        } catch (_) {
          // The short lease below clears captions if refreshes stop.
        } finally {
          _fetching = false;
        }
      });
      return playback.toString();
    } catch (error) {
      if (!_disposed && generation == _generation) {
        AppDiagnostics.instance.log('subtitle_session_unavailable', {
          'errorType': error.runtimeType.toString(),
        });
      }
      return source;
    }
  }

  bool _fetching = false;

  /// Refreshes programme discovery without reopening or seeking the decoder.
  Future<void> refreshProgramme() async {
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
    text.value = '';
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
    _timeline = timeline;
    _programmeAcknowledged = true;
    if (!selection.external) {
      selection.external = true;
      selection.refresh();
    }
    _expiry?.cancel();
    _expiry = Timer(const Duration(seconds: 3), () {
      _timeline = null;
      if (!_disposed) {
        text.value = '';
        selection.external = false;
        selection.refresh();
      }
    });
    _render();
  }

  void _render() {
    if (_disposed) return;
    final prefs = SubtitlePreferences.instance;
    text.value =
        !prefs.enabled ||
            !_active ||
            !player.state.playing ||
            player.state.buffering
        ? ''
        : _timeline?.textAt(
                player.state.position.inMicroseconds /
                    Duration.microsecondsPerSecond,
                prefs.language.tag,
              ) ??
              '';
  }

  void clear() {
    ++_generation;
    _poll?.cancel();
    _expiry?.cancel();
    _timeline = null;
    _programme = null;
    _requiresProgramme = false;
    _programmeAcknowledged = false;
    _base = null;
    _session = null;
    _source = null;
    _active = false;
    text.value = '';
    selection.external = false;
    selection.refresh();
  }

  void activate() {
    _active = true;
    _render();
  }

  Future<void> dispose() async {
    clear();
    _disposed = true;
    _client.close();
    SubtitlePreferences.instance.removeListener(_render);
    await _position?.cancel();
    await _buffering?.cancel();
    await _playing?.cancel();
    text.dispose();
  }
}
