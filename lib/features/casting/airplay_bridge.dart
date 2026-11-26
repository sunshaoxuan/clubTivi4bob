import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logger/logger.dart';
import 'cast_diagnostics.dart';
import '../../core/diagnostic_context.dart';
import '../../core/diagnostic_log_store.dart';
import 'package:path/path.dart' as p;

/// AirPlay runs outside the UI process. Communication uses private stdio pipes.
class AirPlayBridge {
  static Map<String, Object> _nativeFields(Map<String, dynamic> message) {
    final result =
        DiagnosticProjection.project({
          ...message,
          'time': DateTime.now().toUtc().toIso8601String(),
          'event': 'native_diagnostic',
          if (message['decoderExit'] is int)
            'processExitCode': message['decoderExit'],
          if (message['status'] is int &&
              message['status'] >= 100 &&
              message['status'] <= 599)
            'httpStatus': message['status'],
        }, DateTime.now()) ??
        {};
    result.remove('time');
    result.remove('event');
    return result;
  }

  final _log = Logger(printer: SimplePrinter());
  Process? _process;
  Future<void>? _starting;
  int _nextId = 0;
  bool _disposed = false;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get events => _events.stream;

  Future<void> _start() async {
    if (_disposed) throw StateError('AirPlay 已關閉');
    if (_process != null) return;
    if (_starting != null) return _starting;
    final future = _launch();
    _starting = future;
    try {
      await future;
    } finally {
      _starting = null;
    }
  }

  Future<void> _launch() async {
    final executable = Platform.isWindows
        ? p.join(
            p.dirname(Platform.resolvedExecutable),
            'AirPlay',
            'bobtv-airplay.exe',
          )
        : Platform.isMacOS
        ? p.normalize(
            p.join(
              p.dirname(Platform.resolvedExecutable),
              '..',
              'Resources',
              'AirPlay',
              'bobtv-airplay',
              'bobtv-airplay',
            ),
          )
        : null;
    if (executable == null || !await File(executable).exists()) {
      CastDiagnostics.instance.record('airplay_helper_missing');
      throw StateError('此安裝缺少 AirPlay 組件。');
    }
    final process = await Process.start(executable, [], runInShell: false);
    if (_disposed) {
      process.kill();
      return;
    }
    _process = process;
    process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((
      line,
    ) {
      try {
        final message = jsonDecode(line) as Map<String, dynamic>;
        if (message['event'] == 'diagnostic') {
          final stage = message['stage'];
          if (stage is String) {
            CastDiagnostics.instance.record(
              'native_${stage.replaceAll('-', '_')}',
              {
                ..._nativeFields(message),
                for (final key in ['bytes', 'elapsedMs'])
                  if (message[key] is num && (message[key] as num) >= 0)
                    (key == 'elapsedMs' ? 'durationMs' : key): message[key],
              },
            );
          }
          return;
        }
        if (message.containsKey('event')) {
          if (!_events.isClosed) _events.add(message);
          return;
        }
        final completer = _pending.remove(message['id']);
        if (completer == null || completer.isCompleted) return;
        if (message['error'] != null) {
          final safe = DiagnosticProjection.project({
            ...message,
            'time': DateTime.now().toUtc().toIso8601String(),
            'event': 'native_error',
          }, DateTime.now())!;
          completer.completeError(
            DiagnosticRemoteException(
              message['error'] as String,
              code: safe['errorCode'] as String? ?? 'other',
              errorType: safe['errorType'] as String? ?? 'NativeError',
              osErrorCode: safe['osErrorCode'] as int?,
            ),
          );
        } else {
          completer.complete(
            Map<String, dynamic>.from(message['result'] as Map),
          );
        }
      } catch (_) {
        // Ignore non-protocol output; never log pairing material or stream URLs.
      }
    }, onError: (_) => _failed(process));
    final stage = RegExp(r'^BobTV AirPlay stage: ([a-z-]+)$');
    process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((line) {
          final match = stage.firstMatch(line);
          if (match != null) {
            _log.d(line);
            CastDiagnostics.instance.record(
              'airplay_${match.group(1)!.replaceAll('-', '_')}',
            );
          }
        });
    unawaited(
      process.exitCode.then((code) {
        CastDiagnostics.instance.record('airplay_process_exit', {
          'accepted': code == 0,
        });
        _failed(process);
      }),
    );
  }

  void _failed(Process process) {
    if (!identical(_process, process)) return;
    _process = null;
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('AirPlay 組件已停止，請重新搜尋設備。'));
      }
    }
    _pending.clear();
    if (!_disposed && !_events.isClosed) {
      _events.add({'event': 'error', 'message': 'AirPlay 連接已中斷，請重新搜尋設備。'});
    }
  }

  Future<Map<String, dynamic>> request(
    String action, [
    Map<String, dynamic> arguments = const {},
  ]) async {
    final clock = Stopwatch()..start();
    final requestTrace = CastDiagnostics.instance.sessionId;
    CastDiagnostics.instance.record('airplay_${action}_request', {
      'requestId': requestTrace,
    });
    await _start();
    final id = ++_nextId;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    try {
      _process!.stdin.writeln(
        jsonEncode({
          'id': id,
          'action': action,
          'requestId': requestTrace,
          ...arguments,
        }),
      );
      final result = await completer.future.timeout(
        Duration(seconds: action == 'play' ? 65 : 30),
      );
      CastDiagnostics.instance.record('airplay_${action}_response', {
        'requestId': requestTrace,
        'accepted': true,
        'durationMs': clock.elapsedMilliseconds,
      });
      if (action == 'play' && result['status'] == 'playing') {
        CastDiagnostics.instance.record('airplay_playing', {
          'requestId': requestTrace,
        });
      }
      if (action == 'play' && result['status'] == 'streaming') {
        CastDiagnostics.instance.record('airplay_frames_sent', {
          'requestId': requestTrace,
        });
      }
      return result;
    } on TimeoutException {
      CastDiagnostics.instance.record('airplay_${action}_timeout', {
        'requestId': requestTrace,
        'errorCode': 'timeout',
        'durationMs': clock.elapsedMilliseconds,
      });
      final process = _process;
      if (process != null) unawaited(_terminate(process));
      throw StateError('AirPlay 操作逾時，請重新搜尋設備。');
    } catch (error, stack) {
      CastDiagnostics.instance.record('airplay_${action}_failed', {
        'requestId': requestTrace,
        ...DiagnosticFailure.describe(error, stack),
        'durationMs': clock.elapsedMilliseconds,
      });
      rethrow;
    } finally {
      _pending.remove(id);
    }
  }

  Future<void> _terminate(Process process) async {
    if (!identical(_process, process)) return;
    if (Platform.isWindows) {
      // Include FFmpeg children if the helper is unresponsive during shutdown.
      try {
        await Process.run('taskkill.exe', [
          '/PID',
          '${process.pid}',
          '/T',
          '/F',
        ]);
      } catch (_) {
        process.kill();
      }
    } else if (Platform.isMacOS) {
      // The helper may still own an FFmpeg decoder when it is unresponsive.
      try {
        await Process.run('/usr/bin/pkill', [
          '-TERM',
          '-P',
          '${process.pid}',
        ]).timeout(const Duration(seconds: 2));
      } catch (_) {}
      process.kill(ProcessSignal.sigterm);
    } else {
      process.kill();
    }
  }

  void dispose() {
    _disposed = true;
    final process = _process;
    if (process != null) {
      process.stdin.close();
      Timer(const Duration(seconds: 3), () => unawaited(_terminate(process)));
    }
    _events.close();
  }
}
