import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// AirPlay runs outside the UI process. Communication uses private stdio pipes.
class AirPlayBridge {
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
    final executable = p.join(
      p.dirname(Platform.resolvedExecutable),
      'AirPlay',
      'bobtv-airplay.exe',
    );
    if (!Platform.isWindows || !await File(executable).exists()) {
      throw StateError('此安裝缺少 AirPlay 組件，請使用包含 AirPlay 的 Windows 版本。');
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
        if (message.containsKey('event')) {
          if (!_events.isClosed) _events.add(message);
          return;
        }
        final completer = _pending.remove(message['id']);
        if (completer == null || completer.isCompleted) return;
        if (message['error'] != null) {
          completer.completeError(StateError(message['error'] as String));
        } else {
          completer.complete(
            Map<String, dynamic>.from(message['result'] as Map),
          );
        }
      } catch (_) {
        // Ignore non-protocol output; never log pairing material or stream URLs.
      }
    }, onError: (_) => _failed(process));
    process.stderr.drain<void>();
    unawaited(process.exitCode.then((_) => _failed(process)));
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
    await _start();
    final id = ++_nextId;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    try {
      _process!.stdin.writeln(
        jsonEncode({'id': id, 'action': action, ...arguments}),
      );
      return await completer.future.timeout(const Duration(seconds: 30));
    } on TimeoutException {
      final process = _process;
      if (process != null) unawaited(_terminate(process));
      throw StateError('AirPlay 操作逾時，請重新搜尋設備。');
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
