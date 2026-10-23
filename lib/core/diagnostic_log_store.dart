import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// The network projection has no free-form error, URL, path, channel or stack.
class DiagnosticProjection {
  static const retention = Duration(days: 30);
  static final _tag = RegExp(r'^[A-Za-z][A-Za-z0-9_]{0,79}$');
  static final _version = RegExp(r'^\d{1,4}\.\d{1,4}\.\d{1,4}\+\d{1,8}$');
  static const enums = <String, Set<String>>{
    'platform': {'android', 'windows', 'macos', 'linux', 'ios'},
    'phase': {'open', 'headers', 'body', 'complete', 'retry'},
    'node': {'origin', 'cndrp', 'local'},
    'endpoint': {
      'catalog_manifest',
      'catalog_snapshot',
      'catalog_blocked',
      'catalog_events',
      'catalog_inventory',
      'route_state',
      'network_profile',
      'route_rank',
      'epg_manifest',
      'epg_snapshot',
      'diagnostics',
      'favorites',
      'other_api',
    },
    'errorCode': {
      'timeout',
      'socket',
      'tls',
      'http',
      'format',
      'cancelled',
      'server_busy',
      'other',
    },
  };
  static const _metrics = {
    'uptimeSeconds',
    'rssBytes',
    'maxRssBytes',
    'httpStatus',
    'elapsedMs',
    'bytes',
    'attempt',
  };

  static Map<String, Object>? project(Map input, DateTime now) {
    final time = input['time'];
    final event = input['event'];
    final stamp = time is String ? DateTime.tryParse(time) : null;
    if (stamp == null ||
        event is! String ||
        !_tag.hasMatch(event) ||
        !stamp.isAfter(now.subtract(retention)) ||
        stamp.isAfter(now.add(const Duration(minutes: 5)))) {
      return null;
    }
    final result = <String, Object>{
      'time': stamp.toUtc().toIso8601String(),
      'event': event,
    };
    for (final entry in input.entries) {
      final key = entry.key;
      final value = entry.value;
      if (key == 'source' && value is String && _tag.hasMatch(value)) {
        result['source'] = value;
      }
      if (key == 'appVersion' && value is String && _version.hasMatch(value)) {
        result['appVersion'] = value;
      }
      if (key == 'requestId' &&
          value is String &&
          RegExp(r'^[a-f0-9]{32}$').hasMatch(value)) {
        result['requestId'] = value;
      }
      if (key == 'fatal' && value is bool) result['fatal'] = value;
      if (enums.containsKey(key) &&
          value is String &&
          enums[key]!.contains(value)) {
        result[key as String] = value;
      }
      if (_metrics.contains(key) &&
          value is num &&
          value.isFinite &&
          value >= 0 &&
          value <= 1000000000000000) {
        if (key == 'httpStatus' &&
            (value is! int || value < 100 || value > 599)) {
          continue;
        }
        result[key as String] = value;
      }
    }
    return result;
  }
}

class DiagnosticChunk {
  const DiagnosticChunk(this.entries, this.checkpoints);
  final List<Map<String, Object>> entries;
  final Map<String, int> checkpoints;
}

class DiagnosticLogStore {
  DiagnosticLogStore(
    this.directory, {
    this.legacyDirectory,
    DateTime Function()? now,
    this.maxBytes = 32 * 1024 * 1024,
  }) : now = now ?? DateTime.now;
  final Directory directory;
  final Directory? legacyDirectory;
  final DateTime Function() now;
  final int maxBytes;
  Future<void> _tail = Future.value();
  DateTime? _captureStarted;
  DateTime? _lastPruned;
  int droppedFiles = 0;

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}).catchError((_) {});
    return result;
  }

  Future<void> initialize() => _serial(() async {
    await directory.create(recursive: true);
    final marker = File(p.join(directory.path, 'capture-start.txt'));
    if (await marker.exists()) {
      _captureStarted = DateTime.tryParse(await marker.readAsString());
    }
    _captureStarted ??= now().toUtc();
    if (!await marker.exists()) {
      await marker.writeAsString(
        _captureStarted!.toIso8601String(),
        flush: true,
      );
    }
    await _prune();
  });

  Future<void> record(Map<String, Object?> entry) => _serial(() async {
    final safe = DiagnosticProjection.project(entry, now());
    if (safe == null) return;
    await directory.create(recursive: true);
    final day = now()
        .toUtc()
        .toIso8601String()
        .substring(0, 10)
        .replaceAll('-', '');
    for (var index = 0; index < 100; index++) {
      final file = File(
        p.join(
          directory.path,
          'diagnostics-$day-${index.toString().padLeft(2, '0')}.jsonl',
        ),
      );
      if (await file.exists() && await file.length() >= 512 * 1024) continue;
      await file.writeAsString(
        '${jsonEncode(safe)}\n',
        mode: FileMode.append,
        flush: true,
      );
      break;
    }
    if (_lastPruned == null ||
        now().difference(_lastPruned!) >= const Duration(minutes: 10)) {
      await _prune();
    }
  });

  Future<List<File>> _files(Directory folder, Pattern pattern) async {
    if (!await folder.exists()) return [];
    final result = <File>[];
    await for (final entity in folder.list(followLinks: false)) {
      if (entity is File &&
          RegExp(pattern.toString()).hasMatch(p.basename(entity.path))) {
        result.add(entity);
      }
    }
    result.sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
    return result;
  }

  Future<void> _prune() async {
    final files = await _files(directory, r'^diagnostics-\d{8}-\d{2}\.jsonl$');
    final remaining = <File>[];
    var size = 0;
    for (final file in files) {
      final date = p.basename(file.path).substring(12, 20);
      final stamp = DateTime.tryParse(
        '${date.substring(0, 4)}-${date.substring(4, 6)}-${date.substring(6)}T00:00:00Z',
      );
      if (stamp == null ||
          stamp.add(const Duration(days: 31)).isBefore(now())) {
        await file.delete();
      } else {
        remaining.add(file);
        size += await file.length();
      }
    }
    for (final file in remaining) {
      if (size <= maxBytes) break;
      size -= await file.length();
      await file.delete();
      droppedFiles++;
    }
    _lastPruned = now();
  }

  /// Stable byte offsets are committed only after origin acknowledgment.
  /// Legacy files are projected locally and never uploaded verbatim.
  Future<DiagnosticChunk> readChunk(
    Map<String, int> checkpoint,
  ) => _serial(() async {
    await _prune();
    final next = Map<String, int>.from(checkpoint);
    final sources = <(String, File, bool)>[
      if (legacyDirectory != null)
        for (final file in await _files(
          legacyDirectory!,
          r'^clubtivi-\d{8}(?:-\d+)?\.log$',
        ))
          ('legacy:${p.basename(file.path)}', file, true),
      for (final file in await _files(
        directory,
        r'^diagnostics-\d{8}-\d{2}\.jsonl$',
      ))
        ('safe:${p.basename(file.path)}', file, false),
    ];
    final entries = <Map<String, Object>>[];
    var bytes = 0;
    for (final (key, file, legacy) in sources) {
      if (await file.length() > 9 * 1024 * 1024) continue;
      final raw = await file.readAsBytes();
      var offset = next[key] ?? 0;
      if (offset < 0 || offset > raw.length) offset = 0;
      while (offset < raw.length) {
        final end = raw.indexOf(10, offset);
        if (end < 0) {
          break; // Incomplete concurrent append is retried next time.
        }
        Map<String, Object>? safe;
        if (end - offset <= 65536) {
          try {
            final decoded = jsonDecode(utf8.decode(raw.sublist(offset, end)));
            if (decoded is Map) {
              final stamp = DateTime.tryParse(
                decoded['time']?.toString() ?? '',
              );
              if (!legacy ||
                  (stamp != null &&
                      _captureStarted != null &&
                      stamp.isBefore(_captureStarted!))) {
                safe = DiagnosticProjection.project(decoded, now());
              }
            }
          } catch (_) {}
        }
        final length = safe == null
            ? 0
            : utf8.encode(jsonEncode(safe)).length + 2;
        if (safe != null &&
            (entries.length >= 500 || bytes + length > 120 * 1024)) {
          return DiagnosticChunk(entries, next);
        }
        next[key] = offset = end + 1;
        if (safe != null) {
          entries.add(safe);
          bytes += length;
        }
      }
    }
    // Drop checkpoints for files removed by retention, keeping preferences bounded.
    final keys = sources.map((source) => source.$1).toSet();
    next.removeWhere((key, _) => !keys.contains(key));
    return DiagnosticChunk(entries, next);
  });
}
