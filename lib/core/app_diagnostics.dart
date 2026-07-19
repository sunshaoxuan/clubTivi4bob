import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Durable application diagnostics for unattended Windows playback.
///
/// Each entry is written and flushed as one JSON line. An active-session
/// marker lets the next launch identify an earlier unclean exit even when the
/// user does not know when it happened.
class AppDiagnostics with WidgetsBindingObserver {
  AppDiagnostics._();

  static final AppDiagnostics instance = AppDiagnostics._();

  static const _heartbeatInterval = Duration(seconds: 30);
  static const _maxLogBytes = 8 * 1024 * 1024;
  static const _retainedLogFiles = 14;

  Directory? _logDirectory;
  File? _logFile;
  File? _sessionMarker;
  Timer? _heartbeatTimer;
  Future<void> _writeQueue = Future<void>.value();
  DateTime? _startedAt;
  String? _channelName;
  String? _streamIdentity;
  bool _initialized = false;
  bool _shuttingDown = false;

  String? get logDirectoryPath => _logDirectory?.path;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    _startedAt = DateTime.now();

    final directory = await _resolveLogDirectory();
    await directory.create(recursive: true);
    _logDirectory = directory;
    _logFile = await _selectLogFile(directory);
    _sessionMarker = File(p.join(directory.path, 'active_session.json'));

    await _recordPreviousSessionIfNeeded();
    await _writeEntry('application_started', {
      'pid': pid,
      'platform': Platform.operatingSystem,
      'osVersion': Platform.operatingSystemVersion,
      'executable': Platform.resolvedExecutable,
    });
    await _writeSessionMarker();
    await _pruneOldLogs();

    WidgetsBinding.instance.addObserver(this);
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) {
      unawaited(_writeHeartbeat());
    });
  }

  Future<Directory> _resolveLogDirectory() async {
    if (Platform.isWindows) {
      final localAppData = Platform.environment['LOCALAPPDATA'];
      if (localAppData != null && localAppData.isNotEmpty) {
        return Directory(p.join(localAppData, 'HotelTV', 'Logs'));
      }
    }
    try {
      final support = await getApplicationSupportDirectory();
      return Directory(p.join(support.path, 'logs'));
    } catch (_) {
      return Directory(p.join(Directory.systemTemp.path, 'clubtivi-logs'));
    }
  }

  Future<File> _selectLogFile(Directory directory) async {
    final now = DateTime.now();
    final day = _compactDate(now);
    for (var index = 0; index < 100; index++) {
      final suffix = index == 0 ? '' : '-$index';
      final file = File(p.join(directory.path, 'clubtivi-$day$suffix.log'));
      if (!await file.exists() || await file.length() < _maxLogBytes) {
        return file;
      }
    }
    return File(
      p.join(directory.path, 'clubtivi-$day-${now.millisecondsSinceEpoch}.log'),
    );
  }

  Future<void> _recordPreviousSessionIfNeeded() async {
    final marker = _sessionMarker;
    if (marker == null || !await marker.exists()) return;
    try {
      final raw = await marker.readAsString();
      final previous = jsonDecode(raw);
      await _writeEntry('previous_session_unclean', {
        if (previous is Map<String, dynamic>) ...previous,
        'detectedAt': DateTime.now().toUtc().toIso8601String(),
      });
    } catch (error, stackTrace) {
      await _writeEntry('previous_session_marker_unreadable', {
        'error': _limit(error.toString(), 2000),
        'stack': _limit(stackTrace.toString(), 8000),
      });
    }
  }

  void log(String event, [Map<String, Object?> data = const {}]) {
    if (!_initialized) return;
    _writeQueue = _writeQueue
        .then((_) => _writeEntry(event, data))
        .catchError((_) {});
  }

  void recordError(
    String source,
    Object error,
    StackTrace stackTrace, {
    bool fatal = false,
  }) {
    log('application_error', {
      'source': source,
      'fatal': fatal,
      'error': _limit(error.toString(), 4000),
      'stack': _limit(stackTrace.toString(), 16000),
    });
  }

  void updatePlaybackContext({String? channelName, String? streamUrl}) {
    _channelName = channelName;
    _streamIdentity = streamUrl == null ? null : summarizeStreamUrl(streamUrl);
  }

  Future<void> _writeHeartbeat() async {
    await _writeEntry('heartbeat', {
      'uptimeSeconds': _startedAt == null
          ? null
          : DateTime.now().difference(_startedAt!).inSeconds,
      'rssBytes': ProcessInfo.currentRss,
      'maxRssBytes': ProcessInfo.maxRss,
      'channel': _channelName,
      'stream': _streamIdentity,
    });
    await _writeSessionMarker();
  }

  Future<void> _writeSessionMarker() async {
    final marker = _sessionMarker;
    if (marker == null) return;
    try {
      await marker.writeAsString(
        jsonEncode({
          'pid': pid,
          'startedAt': _startedAt?.toUtc().toIso8601String(),
          'lastHeartbeat': DateTime.now().toUtc().toIso8601String(),
          'rssBytes': ProcessInfo.currentRss,
          'channel': _channelName,
          'stream': _streamIdentity,
        }),
        flush: true,
      );
    } catch (_) {}
  }

  Future<void> _writeEntry(String event, Map<String, Object?> data) async {
    final file = _logFile;
    if (file == null) return;
    try {
      final entry = <String, Object?>{
        'time': DateTime.now().toUtc().toIso8601String(),
        'event': event,
        ...data,
      };
      await file.writeAsString(
        '${jsonEncode(entry)}\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {}
  }

  Future<void> _pruneOldLogs() async {
    final directory = _logDirectory;
    if (directory == null) return;
    try {
      final files = await directory
          .list()
          .where((entry) => entry is File && p.extension(entry.path) == '.log')
          .cast<File>()
          .toList();
      files.sort(
        (left, right) =>
            right.lastModifiedSync().compareTo(left.lastModifiedSync()),
      );
      for (final file in files.skip(_retainedLogFiles)) {
        await file.delete();
      }
    } catch (_) {}
  }

  Future<void> shutdown({String reason = 'normal'}) async {
    if (_shuttingDown || !_initialized) return;
    _shuttingDown = true;
    _heartbeatTimer?.cancel();
    await _writeQueue;
    await _writeEntry('application_stopped', {
      'reason': reason,
      'uptimeSeconds': _startedAt == null
          ? null
          : DateTime.now().difference(_startedAt!).inSeconds,
      'rssBytes': ProcessInfo.currentRss,
    });
    try {
      if (await _sessionMarker?.exists() ?? false) {
        await _sessionMarker?.delete();
      }
    } catch (_) {}
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    log('lifecycle_changed', {'state': state.name});
    if (state == AppLifecycleState.detached) {
      unawaited(shutdown(reason: 'window_detached'));
    }
  }

  static String summarizeStreamUrl(String value) {
    final uri = Uri.tryParse(value);
    final host = uri?.host.isNotEmpty == true ? uri!.host : 'unknown';
    final scheme = uri?.scheme.isNotEmpty == true ? uri!.scheme : 'unknown';
    return '$scheme://$host/#${_fnv1a(value)}';
  }

  static String _fnv1a(String value) {
    var hash = 0x811c9dc5;
    for (final byte in utf8.encode(value)) {
      hash ^= byte;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  static String _compactDate(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}'
      '${value.month.toString().padLeft(2, '0')}'
      '${value.day.toString().padLeft(2, '0')}';

  static String _limit(String value, int length) =>
      value.length <= length ? value : value.substring(0, length);
}
