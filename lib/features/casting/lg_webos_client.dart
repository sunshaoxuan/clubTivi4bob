import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logger/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _log = Logger(printer: SimplePrinter());

/// Client for LG WebOS TV SSAP protocol over WebSocket (port 3000).
/// Handles pairing, media playback, and basic controls.
class LgWebOsClient {
  final String host;
  final int port;
  WebSocket? _ws;
  String? _clientKey;
  int _msgId = 0;
  final _responses = <String, Completer<Map<String, dynamic>>>{};
  bool _paired = false;
  StreamSubscription? _listenSub;
  static const _registrationId = 'register_0';

  static const _prefKeyPrefix = 'lg_webos_key_';

  LgWebOsClient({required this.host, this.port = 3000});

  bool get isConnected => _ws != null && _paired;

  /// Connect to the TV and perform pairing handshake.
  /// Returns true if successfully paired.
  /// The TV will show a pairing prompt on first connection.
  Future<bool> connect({Duration timeout = const Duration(seconds: 15)}) async {
    try {
      await disconnect();
      // Load saved client key for this TV
      final prefs = await SharedPreferences.getInstance();
      _clientKey = prefs.getString('$_prefKeyPrefix$host');

      _ws = await WebSocket.connect('ws://$host:$port').timeout(timeout);

      _listenSub = _ws!.listen(
        _onMessage,
        onError: (e) {
          _log.e('WebOS WS error: $e');
          _connectionClosed();
        },
        onDone: () {
          _connectionClosed();
        },
      );

      // Send registration/pairing request
      final paired = await _register().timeout(timeout);
      _paired = paired;
      if (!paired) await disconnect();
      return paired;
    } catch (e) {
      _log.e('WebOS connect failed: $e');
      await disconnect();
      return false;
    }
  }

  Future<bool> _register() async {
    const regId = _registrationId;

    final payload = {
      'type': 'register',
      'id': regId,
      'payload': {
        'pairingType': 'PROMPT',
        if (_clientKey != null) 'client-key': _clientKey,
        'manifest': {
          'appVersion': '1.0',
          'signed': {},
          'permissions': [
            'LAUNCH',
            'LAUNCH_WEBAPP',
            'CONTROL_AUDIO',
            'CONTROL_INPUT_MEDIA_PLAYBACK',
            'READ_RUNNING_APPS',
            'READ_INSTALLED_APPS',
          ],
        },
      },
    };

    final completer = Completer<Map<String, dynamic>>();
    _responses[regId] = completer;

    _ws!.add(jsonEncode(payload));

    try {
      final response = await completer.future;
      final key = response['client-key'] as String?;
      if (key != null && key.isNotEmpty) {
        _clientKey = key;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('$_prefKeyPrefix$host', key);
        _log.i('WebOS paired with $host (key saved)');
      }
      return true;
    } catch (e) {
      _log.e('WebOS registration timeout or error: $e');
      return false;
    }
  }

  void _onMessage(dynamic data) {
    try {
      final msg = jsonDecode(data as String) as Map<String, dynamic>;
      final id = msg['id'] as String?;
      final type = msg['type'] as String?;

      // Handle registration responses
      if (type == 'registered' || type == 'response') {
        final payload = msg['payload'] as Map<String, dynamic>? ?? {};
        if (id == _registrationId &&
            type != 'registered' &&
            payload['returnValue'] != false)
          return;
        if (id != null && _responses.containsKey(id)) {
          final completer = _responses.remove(id)!;
          if (payload['returnValue'] == false) {
            completer.completeError(StateError('WebOS request rejected'));
          } else {
            completer.complete(payload);
          }
        }
      } else if (type == 'error') {
        if (id != null && _responses.containsKey(id)) {
          _responses[id]!.completeError(
            Exception(msg['error'] ?? 'Unknown WebOS error'),
          );
          _responses.remove(id);
        }
      }
    } catch (e) {
      _log.e('WebOS parse error: $e');
    }
  }

  void _connectionClosed() {
    _paired = false;
    _ws = null;
    final pending = _responses.values.toList();
    _responses.clear();
    for (final completer in pending) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('WebOS connection closed'));
      }
    }
  }

  /// Send an SSAP request and return the response payload.
  Future<Map<String, dynamic>> _request(
    String uri, [
    Map<String, dynamic>? payload,
  ]) async {
    if (_ws == null) throw Exception('Not connected to WebOS TV');

    final id = 'msg_${++_msgId}';
    final msg = {
      'type': 'request',
      'id': id,
      'uri': uri,
      if (payload != null) 'payload': payload,
    };

    final completer = Completer<Map<String, dynamic>>();
    _responses[id] = completer;
    _ws!.add(jsonEncode(msg));

    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        _responses.remove(id);
        throw TimeoutException('WebOS request timed out: $uri');
      },
    );
  }

  /// Open a video URL in the TV's browser (most reliable method).
  Future<void> openInBrowser(String url) async {
    await _request('ssap://system.launcher/open', {'target': url});
  }

  /// Play a video URL using the TV's media viewer (better for direct streams).
  Future<void> playMedia(
    String url, {
    String title = '',
    String? mediaType,
  }) async {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    final mime =
        mediaType ??
        (path.endsWith('.m3u8')
            ? 'application/vnd.apple.mpegurl'
            : path.endsWith('.mpd')
            ? 'application/dash+xml'
            : path.endsWith('.ts')
            ? 'video/mp2t'
            : path.endsWith('.mp4')
            ? 'video/mp4'
            : null);
    await _request('ssap://media.viewer/open', {
      'target': url,
      'title': title,
      'description': '',
      if (mime != null) 'mimeType': mime,
      'loop': false,
    });
  }

  /// Pause playback.
  Future<void> pause() async {
    await _request('ssap://media.controls/pause');
  }

  /// Resume playback.
  Future<void> play() async {
    await _request('ssap://media.controls/play');
  }

  /// Stop playback.
  Future<void> stop() async {
    await _request('ssap://media.controls/stop');
  }

  /// Set volume (0-100).
  Future<void> setVolume(int vol) async {
    await _request('ssap://audio/setVolume', {'volume': vol.clamp(0, 100)});
  }

  /// Get current volume.
  Future<int> getVolume() async {
    final res = await _request('ssap://audio/getVolume');
    return res['volume'] as int? ?? 0;
  }

  /// Mute/unmute.
  Future<void> setMute(bool mute) async {
    await _request('ssap://audio/setMute', {'mute': mute});
  }

  /// Get TV info (model, name).
  Future<Map<String, dynamic>> getSystemInfo() async {
    return _request('ssap://system/getSystemInfo');
  }

  /// Disconnect from the TV.
  Future<void> disconnect() async {
    await _listenSub?.cancel();
    _listenSub = null;
    await _ws?.close();
    _connectionClosed();
  }

  /// Probe a host to check if it's an LG WebOS TV (tries WS on port 3000).
  static Future<bool> probe(
    String host, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    try {
      final ws = await WebSocket.connect('ws://$host:3000').timeout(timeout);
      await ws.close();
      return true;
    } catch (_) {
      return false;
    }
  }
}
