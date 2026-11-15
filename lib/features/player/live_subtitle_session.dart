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

/// Optional synchronization service. Video remains one continuous decoder;
/// caption fetches never reload media or move the playhead.
class LiveSubtitleSession {
  LiveSubtitleSession(
    this.player,
    this.selection, {
    http.Client? client,
    this.serviceEndpoint = endpoint,
  }) : _client = client ?? http.Client() {
    _position = player.stream.position.listen((position) => _render());
    SubtitlePreferences.instance.addListener(_render);
  }
  static const endpoint = String.fromEnvironment('BOBTV_SUBTITLE_SERVICE');
  final Player player;
  final NativeSubtitleSelection selection;
  final String serviceEndpoint;
  final text = ValueNotifier<String>('');
  final http.Client _client;
  StreamSubscription<Duration>? _position;
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
      final response = await _client
          .post(
            base.resolve('sessions'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'source': source,
              'language': SubtitlePreferences.instance.language.tag,
            }),
          )
          .timeout(const Duration(seconds: 3));
      if (_disposed ||
          generation != _generation ||
          response.statusCode != 200) {
        return source;
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final session = data['session'] as String;
      final playback = Uri.parse(data['playbackUrl'] as String);
      if (!ServerEgress.canConnect(playback)) return source;
      _accept(data, session, source);
      selection.external = true;
      selection.refresh();
      _poll = Timer.periodic(const Duration(milliseconds: 500), (_) async {
        // One outstanding request at a time, even on a slow service.
        if (_fetching || _disposed || generation != _generation) return;
        _fetching = true;
        try {
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
  void _accept(Map<String, dynamic> data, String session, String source) {
    final timeline = LiveSubtitleTimeline.decode(
      data,
      session: session,
      source: source,
    );
    _timeline = timeline;
    _expiry?.cancel();
    _expiry = Timer(const Duration(seconds: 3), () {
      _timeline = null;
      if (!_disposed) text.value = '';
    });
    _render();
  }

  void _render() {
    if (_disposed) return;
    final prefs = SubtitlePreferences.instance;
    text.value = !prefs.enabled || !_active
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
    text.dispose();
  }
}
