import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import '../../core/app_diagnostics.dart';
import '../../core/diagnostic_context.dart';

/// Only bounded, structured metadata. Never accepts payloads or error text.
class CastDiagnostics {
  static final instance = CastDiagnostics();
  String? _session;
  final _targets = <String, Map<String, Object>>{};
  String? get sessionId => _session;
  final _clock = Stopwatch();
  int _count = 0;
  String? protocol;
  String? device;
  String? stream;

  static String identity(String value) =>
      sha256.convert(utf8.encode(value)).toString().substring(0, 32);

  void begin() {
    _session = List.generate(
      16,
      (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    _targets[_session!] = {};
    if (_targets.length > 32) _targets.remove(_targets.keys.first);
    _clock.reset();
    _clock.start();
    _count = 0;
    protocol = device = stream = null;
    record('dialog_open');
    unawaited(
      AppDiagnostics.instance.captureEnvironment(
        'cast_dialog_open',
        requestId: _session,
      ),
    );
  }

  void target(String type, String id, String url) {
    if (_session == null) begin();
    protocol = type;
    device = identity(id);
    stream = identity(url);
    _targets[_session!] = {
      'castProtocol': type,
      'castDeviceId': device!,
      'castStreamId': stream!,
    };
    final uri = Uri.tryParse(url.split('|').first);
    record('target_selected', {
      'castFormat': format(url),
      'castRoute':
          uri != null &&
              (uri.host == 'localhost' ||
                  InternetAddress.tryParse(uri.host)?.isLoopback == true)
          ? 'local_relay'
          : 'remote',
      'hasHeaders': url.contains('|'),
    });
  }

  static String codec(String? value) =>
      const {
        'h264',
        'hevc',
        'av1',
        'vp8',
        'vp9',
        'mpeg2video',
        'mpeg4',
        'aac',
        'ac3',
        'eac3',
        'mp3',
        'opus',
        'vorbis',
        'flac',
      }.contains(value)
      ? value!
      : 'unknown';

  static String format(String url) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    for (final ext in ['m3u8', 'mpd', 'mp4', 'ts']) {
      if (path.endsWith('.$ext')) return ext;
    }
    return 'unknown';
  }

  static String errorCode(Object error) => DiagnosticFailure.code(error);

  Future<void> captureNetwork(String receiver, {int? port}) async {
    final session = _session;
    final targetProtocol = protocol;
    final targetDevice = device;
    final snapshot = await DiagnosticNetwork.inspect(receiver, port: port);
    AppDiagnostics.instance.log('cast_network_environment', {
      ...snapshot,
      if (session != null) 'requestId': session,
      if (targetProtocol != null) 'castProtocol': targetProtocol,
      if (targetDevice != null) 'castDeviceId': targetDevice,
    });
  }

  void record(String stage, [Map<String, Object?> data = const {}]) {
    if (_session == null || _count++ >= 1500) return;
    if (!RegExp(r'^[a-z][a-z0-9_]{0,65}$').hasMatch(stage)) return;
    final request = data['requestId'] as String? ?? _session;
    AppDiagnostics.instance.log('cast_$stage', {
      ...DiagnosticEnvironment.instance.current,
      ...?_targets[request],
      ...data,
      'requestId': request,
      'source': stage,
      'elapsedMs': _clock.elapsedMilliseconds,
    });
    if (stage.contains('failed') ||
        stage.contains('error') ||
        stage.contains('timeout')) {
      unawaited(
        AppDiagnostics.instance.captureEnvironment(stage, requestId: request),
      );
    }
  }
}
