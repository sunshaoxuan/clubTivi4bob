import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'diagnostic_log_store.dart';
import 'app_version.dart';
import 'diagnostic_context.dart';

/// Durable application diagnostics for unattended desktop playback.
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
  DiagnosticLogStore? safeStore;
  Timer? _heartbeatTimer;
  Future<void> _writeQueue = Future<void>.value();
  DateTime? _startedAt;
  String? _channelName;
  String? _streamIdentity;
  bool _initialized = false;
  bool _shuttingDown = false;
  bool _collectEnvironment = true;
  Duration _incidentAfterWindow = const Duration(seconds: 30);
  final _breadcrumbs = <Map<String, Object>>[];
  DateTime? _breadcrumbEvictedAt;
  String? _incidentId;
  DateTime? _incidentUntil;
  Timer? _incidentTimer;
  final _sessionId = List.generate(
    16,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();

  final _events = StreamController<String>.broadcast();
  Stream<String> get recordedEvents => _events.stream;
  Future<void> flush() => _writeQueue;

  String? get logDirectoryPath => _logDirectory?.path;

  Future<void> initialize({
    Directory? directoryOverride,
    bool collectEnvironment = true,
    Duration incidentAfterWindow = const Duration(seconds: 30),
  }) async {
    if (_initialized) return;
    _initialized = true;
    _startedAt = DateTime.now();
    _collectEnvironment = collectEnvironment;
    _incidentAfterWindow = incidentAfterWindow;

    final directory = directoryOverride ?? await _resolveLogDirectory();
    await directory.create(recursive: true);
    _logDirectory = directory;
    safeStore = DiagnosticLogStore(
      Directory(p.join(directory.path, 'safe-diagnostics')),
      legacyDirectory: directory,
    );
    try {
      await safeStore!.initialize();
    } catch (_) {
      safeStore =
          null; // Diagnostic storage must never prevent application startup.
    }
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
    unawaited(captureEnvironment('application_start'));

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
    final recordedAt = DateTime.now().toUtc();
    _writeQueue = _writeQueue
        .then((_) => _writeEntry(event, data, recordedAt: recordedAt))
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
      ...DiagnosticFailure.describe(error, stackTrace),
      ...DiagnosticEnvironment.instance.current,
    });
    unawaited(captureEnvironment(source));
  }

  Future<void> captureEnvironment(String source, {String? requestId}) async {
    if (!_collectEnvironment || !_initialized || _shuttingDown) return;
    final snapshot = await DiagnosticEnvironment.instance.sample();
    if (_shuttingDown) return;
    log('diagnostic_environment', {
      'source': source,
      if (requestId != null) 'requestId': requestId,
      ...snapshot,
    });
  }

  void updatePlaybackContext({String? channelName, String? streamUrl}) {
    _channelName = channelName;
    _streamIdentity = streamUrl == null ? null : summarizeStreamUrl(streamUrl);
  }

  Future<void> _writeHeartbeat() async {
    log('heartbeat', {
      'uptimeSeconds': _startedAt == null
          ? null
          : DateTime.now().difference(_startedAt!).inSeconds,
      'rssBytes': ProcessInfo.currentRss,
      'maxRssBytes': ProcessInfo.maxRss,
      'channel': _channelName,
      'stream': _streamIdentity,
      ...DiagnosticEnvironment.instance.current,
    });
    await flush();
    unawaited(captureEnvironment('heartbeat'));
    await _writeSessionMarker();
  }

  Future<void> _writeSessionMarker() async {
    final marker = _sessionMarker;
    if (marker == null) return;
    try {
      await marker.writeAsString(
        jsonEncode({
          'pid': pid,
          'sessionId': _sessionId,
          if (_incidentId != null) 'incidentId': _incidentId,
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

  Future<void> _writeEntry(
    String event,
    Map<String, Object?> data, {
    DateTime? recordedAt,
  }) async {
    final file = _logFile;
    if (file == null) return;
    try {
      final now = recordedAt ?? DateTime.now().toUtc();
      final entry = <String, Object?>{
        'time': now.toIso8601String(),
        'writeDelayMs': max(
          0,
          DateTime.now().toUtc().difference(now).inMilliseconds,
        ),
        'event': event,
        'appVersion': bobTvVersion,
        'platform': Platform.operatingSystem,
        'sessionId': _sessionId,
        ...data,
      };
      if (_incidentUntil != null && now.isAfter(_incidentUntil!)) {
        _incidentId = null;
      }
      final failure =
          event == 'application_error' ||
          event.endsWith('_failed') ||
          event.endsWith('_error') ||
          event.endsWith('_timeout') ||
          event.endsWith('_missing') ||
          data['accepted'] == false;
      if (failure && _incidentId == null) {
        final incident = List.generate(
          16,
          (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join();
        _incidentId = incident;
        entry['incidentId'] = incident;
        _incidentUntil = now.add(_incidentAfterWindow);
        await _writeSessionMarker();
        // Replay safe preceding records into the same incident. Retain original
        // timestamps and mark duplicates explicitly for server-side grouping.
        for (final previous in _breadcrumbs) {
          final stamp = DateTime.parse(previous['time'] as String);
          if (now.difference(stamp) <= const Duration(seconds: 60)) {
            await safeStore?.record({
              ...previous,
              'incidentId': incident,
              'breadcrumb': true,
            });
          }
        }
        await _writeEntry('diagnostic_incident_started', {
          'incidentId': incident,
          'source': event,
          'windowBeforeMs': 60000,
          'windowAfterMs': _incidentAfterWindow.inMilliseconds,
          'breadcrumbCount': _breadcrumbs.length,
          'breadcrumbTruncated':
              _breadcrumbEvictedAt != null &&
              now.difference(_breadcrumbEvictedAt!) <
                  const Duration(seconds: 60),
        }, recordedAt: now);
        _incidentTimer?.cancel();
        final remaining = _incidentUntil!.difference(DateTime.now().toUtc());
        _incidentTimer = Timer(
          remaining.isNegative ? Duration.zero : remaining,
          () {
            if (_shuttingDown) return;
            log('diagnostic_incident_completed', {'incidentId': incident});
            unawaited(
              _writeQueue.then((_) {
                if (!_shuttingDown) _events.add('cast_incident_ready');
              }),
            );
          },
        );
      }
      if (_incidentId != null) entry['incidentId'] = _incidentId;
      try {
        await safeStore?.record(entry);
      } catch (_) {
        /* Never suppress raw local diagnostics. */
      }
      final safe = DiagnosticProjection.project(entry, now);
      if (safe != null) {
        _breadcrumbs.add(safe);
        if (_breadcrumbs.length > 500) {
          _breadcrumbEvictedAt = DateTime.parse(
            _breadcrumbs.removeAt(0)['time'] as String,
          );
        }
      }
      await file.writeAsString(
        '${jsonEncode(entry)}\n',
        mode: FileMode.append,
        flush: true,
      );
      _events.add(event);
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
    _incidentTimer?.cancel();
    if (_incidentId != null) {
      log('diagnostic_incident_interrupted', {'incidentId': _incidentId});
    }
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
