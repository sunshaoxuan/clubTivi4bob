import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../datasources/local/database.dart' as db;
import '../models/server_epg_snapshot.dart';
import 'bobtv_api_client.dart';
import 'epg_refresh_service.dart';
import 'server_epg_binding.dart';

class ServerEpgSyncStatus {
  const ServerEpgSyncStatus({
    this.phase = 'idle',
    this.version,
    this.checkedAt,
    this.coverageEnd,
    this.nextCheckAt,
    this.error,
    this.attributions = const [],
  });
  final String phase;
  final String? version;
  final DateTime? checkedAt, coverageEnd, nextCheckAt;
  // Safe diagnostic codes only. Never contains upstream URLs or credentials.
  final String? error;
  final List<ServerEpgAttribution> attributions;
  bool expiredAt(DateTime at) =>
      coverageEnd == null || !coverageEnd!.isAfter(at);
}

/// Shared Windows/macOS/Android receiver with exact catalog identity binding.
/// Runtime lifecycle and EPG-only UI invalidation are wired by the app host.
class ServerEpgSyncService {
  ServerEpgSyncService({
    required this.database,
    BobTvApiClient? api,
    DateTime Function()? now,
    this.pollInterval = const Duration(minutes: 5),
    Future<ServerEpgSnapshot> Function(Map<String, Object>)? decode,
  }) : api = api ?? BobTvApiClient(),
       _ownsApi = api == null,
       _now = now ?? DateTime.now,
       _decode = decode ?? ((message) => compute(decodeServerEpg, message));

  final db.AppDatabase database;
  final BobTvApiClient api;
  final bool _ownsApi;
  final DateTime Function() _now;
  final Duration pollInterval;
  final Future<ServerEpgSnapshot> Function(Map<String, Object>) _decode;
  final state = ValueNotifier(const ServerEpgSyncStatus());
  Timer? _timer;
  Future<bool>? _running;
  DateTime? _retryAt, _nextCheckAt;
  bool _started = false, _disposed = false;
  bool _connectivityRetry = false, _recheckAfterReconnect = false;
  int _failures = 0;
  List<ServerEpgAttribution> _attributions = const [];

  void start() {
    if (_started || _disposed) return;
    _started = true;
    unawaited(check());
  }

  void onAppResumed() => unawaited(check(forceVersionCheck: true));
  void onNetworkRestored() {
    if (_disposed) return;
    if (_running != null) {
      _recheckAfterReconnect = true;
      return;
    }
    _clearConnectivityRetry();
    unawaited(check(forceVersionCheck: true));
  }

  void _clearConnectivityRetry() {
    // A new network can recover a failed local connection immediately. HTTP
    // Retry-After, invalid data and every non-connectivity backoff remain intact.
    if (!_connectivityRetry) return;
    _connectivityRetry = false;
    _retryAt = null;
    _nextCheckAt = null;
    _failures = 0;
  }

  Future<bool> check({bool forceVersionCheck = false}) {
    if (_disposed) return Future.value(false);
    return _running ??= _check(forceVersionCheck).whenComplete(() {
      _running = null;
      final catchUp = _recheckAfterReconnect && _connectivityRetry;
      _recheckAfterReconnect = false;
      if (catchUp && !_disposed) {
        _clearConnectivityRetry();
        unawaited(check(forceVersionCheck: true));
      } else {
        _schedule();
      }
    });
  }

  Future<ServerEpgManifest?> _installed() async {
    final row = await database
        .customSelect('SELECT manifest FROM server_epg_receipt WHERE id=1')
        .getSingleOrNull();
    return row == null
        ? null
        : ServerEpgManifest.parse(jsonDecode(row.read<String>('manifest')));
  }

  Future<bool> _check(bool forced) async {
    final now = _now().toUtc();
    if (_retryAt?.isAfter(now) == true ||
        !forced && _nextCheckAt?.isAfter(now) == true) {
      return false;
    }
    ServerEpgManifest? installed;
    try {
      installed = await _installed();
      _attributions = List.unmodifiable(
        (await database
                .customSelect(
                  'SELECT metadata FROM server_epg_attributions ORDER BY source_id',
                )
                .get())
            .map(
              (row) => ServerEpgAttribution.parse(
                jsonDecode(row.read<String>('metadata')),
              ),
            ),
      );
      final source = (await database.getAllEpgSources())
          .where((row) => row.id == serverEpgSourceId)
          .firstOrNull;
      if (source != null && source.url != serverEpgManifestUrl) {
        throw StateError('Reserved EPG source identity collision');
      }
      if (source != null && !source.enabled) {
        await ServerEpgBinding(database).reconcile();
        _nextCheckAt = _now().toUtc().add(pollInterval);
        if (!_disposed) {
          state.value = _status('disabled', installed);
        }
        return false;
      }
      final manifest = await api.fetchEpgManifest();
      if (_disposed) return false;
      var changed = false;
      if (manifest != null) {
        if (installed != null &&
            manifest.generatedAt.isBefore(installed.generatedAt)) {
          throw const FormatException('Regressed EPG manifest');
        }
        if (installed?.version == manifest.version &&
            installed?.sha256 != manifest.sha256) {
          throw const FormatException('Mutated immutable EPG version');
        }
        if (installed?.version != manifest.version) {
          final bytes = await api.downloadEpgSnapshot(manifest);
          if (_disposed) return false;
          final snapshot = await _decode({
            'bytes': bytes,
            'manifest': manifest.json,
            'nowUtc': _now().toUtc().millisecondsSinceEpoch ~/ 1000,
          });
          if (_disposed) return false;
          // A slow download must not commit a guide that expired during I/O.
          final commitAt = _now().toUtc();
          final futureIds = <String>{};
          for (final programme in snapshot.guide.programmes) {
            if (programme.start.isAfter(commitAt)) {
              futureIds.add(programme.channelId);
            }
          }
          for (final id in snapshot.identities.keys) {
            if (!futureIds.contains(id)) {
              throw const FormatException('EPG expired before commit');
            }
          }
          await database.transaction(() async {
            final existing = (await database.getAllEpgSources())
                .where((source) => source.id == serverEpgSourceId)
                .firstOrNull;
            if (existing != null && existing.url != serverEpgManifestUrl) {
              throw StateError('Reserved EPG source identity collision');
            }
            if (existing == null) {
              await database.upsertEpgSource(
                db.EpgSourcesCompanion.insert(
                  id: serverEpgSourceId,
                  name: 'BobTV 服务器节目表',
                  url: serverEpgManifestUrl,
                ),
              );
            }
            await (database.delete(
              database.epgChannels,
            )..where((row) => row.sourceId.equals(serverEpgSourceId))).go();
            await EpgRefreshService(
              database,
            ).importParsed(serverEpgSourceId, snapshot.guide, at: commitAt);
            await database.customStatement('DELETE FROM server_epg_identities');
            for (final entry in snapshot.identities.entries) {
              await database.customStatement(
                'INSERT INTO server_epg_identities VALUES(?,?)',
                [entry.key, jsonEncode(entry.value)],
              );
            }
            await database.customStatement(
              'INSERT OR REPLACE INTO server_epg_receipt VALUES(1,?)',
              [jsonEncode(manifest.json)],
            );
            await database.customStatement(
              'DELETE FROM server_epg_attributions',
            );
            for (final credit in snapshot.attributions) {
              await database.customStatement(
                'INSERT INTO server_epg_attributions VALUES(?,?)',
                [credit.sourceId, jsonEncode(credit.json)],
              );
            }
            await ServerEpgBinding(database).reconcile();
          });
          installed = manifest;
          _attributions = snapshot.attributions;
          changed = true;
        }
      }
      if (!changed && manifest != null) {
        await ServerEpgBinding(database).reconcile();
      }
      _failures = 0;
      _connectivityRetry = false;
      _retryAt = null;
      _nextCheckAt = _now().toUtc().add(pollInterval);
      if (!_disposed) {
        state.value = _status(
          manifest == null
              ? 'unpublished'
              : changed
              ? 'updated'
              : 'unchanged',
          installed,
        );
      }
      return changed;
    } catch (error) {
      _failures++;
      _connectivityRetry =
          error is SocketException || error is TimeoutException;
      var wait = Duration(
        seconds: math.min(1800, 30 * (1 << math.min(6, _failures - 1))),
      );
      if (error is BobTvApiException &&
          error.retryAfter != null &&
          error.retryAfter! > wait) {
        wait = error.retryAfter!;
      }
      _retryAt = _now().toUtc().add(wait);
      _nextCheckAt = _retryAt;
      final code = error is BobTvApiException
          ? '${error.reason}:${error.statusCode ?? 0}'
          : error is FormatException
          ? 'invalid_epg_data'
          : 'epg_sync_failed';
      if (!_disposed) state.value = _status('failed', installed, error: code);
      return false;
    }
  }

  ServerEpgSyncStatus _status(
    String phase,
    ServerEpgManifest? installed, {
    String? error,
  }) => ServerEpgSyncStatus(
    phase: phase,
    version: installed?.version,
    checkedAt: _now().toUtc(),
    coverageEnd: installed == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            installed.coverageEndUtc * 1000,
            isUtc: true,
          ),
    nextCheckAt: _nextCheckAt,
    error: error,
    attributions: _attributions,
  );

  void _schedule() {
    _timer?.cancel();
    if (!_started || _disposed) return;
    final delay = (_nextCheckAt ?? _now().add(pollInterval)).difference(_now());
    _timer = Timer(
      delay.isNegative ? Duration.zero : delay,
      () => unawaited(check()),
    );
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    if (_ownsApi) api.close();
    state.dispose();
  }
}
