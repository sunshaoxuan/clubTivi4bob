import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/app_diagnostics.dart';
import '../datasources/local/database.dart' as db;
import '../../features/providers/provider_manager.dart';
import 'bobtv_api_client.dart';
import 'bobtv_log_projection.dart';
import 'client_fingerprint_service.dart';

class BobTvCatalogState {
  const BobTvCatalogState({
    this.count = 0,
    this.fresh = false,
    this.loading = false,
    this.error = false,
  });
  final int count;
  final bool fresh;
  final bool loading;
  final bool error;
}

class BobTvCommunityService {
  BobTvCommunityService(this.database, {BobTvApiClient? api})
      : api = api ?? BobTvApiClient();

  static const providerId = 'bobtv-reviewed';
  static const _feedbackKey = 'bobtv_health_feedback_enabled';
  static const _autoLogsKey = 'bobtv_auto_logs_enabled';
  static const _reportTimesKey = 'bobtv_report_times_v1';
  static const _reportInterval = Duration(minutes: 5);

  final db.AppDatabase database;
  final BobTvApiClient api;
  final state = ValueNotifier(const BobTvCatalogState());
  Map<String, BobTvReviewedSource> _sources = {};
  final Map<String, DateTime> _reportTimes = {};
  Timer? _logTimer;
  Future<void>? _refreshing;
  bool _started = false;
  bool _disposed = false;
  bool healthFeedbackEnabled = false;
  bool automaticLogsEnabled = false;
  DateTime? _reportsPausedUntil;

  String? sourceIdForRoute(String? channelId, String? url) {
    if (channelId == null || url == null ||
        !channelId.startsWith('$providerId:')) return null;
    final id = channelId.substring(providerId.length + 1);
    return _sources[id]?.url == url ? id : null;
  }

  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    final prefs = await SharedPreferences.getInstance();
    healthFeedbackEnabled = prefs.getBool(_feedbackKey) ?? false;
    automaticLogsEnabled = prefs.getBool(_autoLogsKey) ?? false;
    try {
      final cached = await database.getChannelsForProvider(providerId);
      _sources = {
        for (final channel in cached)
          if (channel.id.startsWith('$providerId:'))
            channel.id.substring(providerId.length + 1): BobTvReviewedSource(
              id: channel.id.substring(providerId.length + 1),
              name: channel.name,
              url: channel.streamUrl,
            ),
      };
      state.value = BobTvCatalogState(count: _sources.length);
    } catch (error, stackTrace) {
      AppDiagnostics.instance.recordError('bobtv_catalog_cache', error, stackTrace);
    }
    try {
      final saved = jsonDecode(prefs.getString(_reportTimesKey) ?? '{}');
      if (saved is Map) {
        for (final entry in saved.entries) {
          final time = DateTime.tryParse(entry.value.toString());
          if (time != null) _reportTimes[entry.key.toString()] = time;
        }
      }
    } catch (_) {}
    // The shared website catalog owns automatic channel synchronization.
    // This legacy reviewed-source endpoint remains available on explicit refresh.
    _logTimer = Timer.periodic(const Duration(hours: 6), (_) {
      if (automaticLogsEnabled) {
        unawaited(_uploadAutomaticLogs());
      }
    });
  }

  Future<void> refreshCatalog() => _refreshing ??= _fetchAndApplyCatalog()
      .whenComplete(() => _refreshing = null);

  Future<void> _fetchAndApplyCatalog() async {
    if (_disposed) return;
    state.value = BobTvCatalogState(
      count: _sources.length, fresh: state.value.fresh, loading: true,
    );
    try {
      final received = await _retryLimited(api.fetchSources);
      if (_disposed) return;
      final existing = await database.getChannelsForProvider(providerId);
      final byId = {for (final channel in existing) channel.id: channel};
      if (received.isNotEmpty) {
        final providers = await database.getAllProviders();
        if (!providers.any((provider) => provider.id == providerId)) {
          await database.upsertProvider(db.ProvidersCompanion.insert(
            id: providerId, name: 'BobTV 已审核', type: 'reviewed',
          ));
        }
        await database.upsertChannels([
          for (final source in received)
            db.ChannelsCompanion.insert(
              id: '$providerId:${source.id}',
              providerId: providerId,
              name: source.name,
              streamUrl: source.url,
              groupTitle: const Value('BobTV 已审核'),
              favorite: Value(byId['$providerId:${source.id}']?.favorite ?? false),
              hidden: Value(byId['$providerId:${source.id}']?.hidden ?? false),
              sortOrder: Value(byId['$providerId:${source.id}']?.sortOrder ?? 0),
            ),
        ]);
      }
      await database.deleteChannelsMissingFromProvider(providerId, {
        for (final source in received) '$providerId:${source.id}',
      });
      if (_disposed) return;
      _sources = {for (final source in received) source.id: source};
      state.value = BobTvCatalogState(count: received.length, fresh: true);
      AppDiagnostics.instance.log('bobtv_catalog_loaded', {
        'count': received.length,
      });
    } catch (error, stackTrace) {
      state.value = BobTvCatalogState(count: _sources.length, error: true);
      AppDiagnostics.instance.recordError('bobtv_catalog', error, stackTrace);
    }
  }

  Future<void> setHealthFeedbackEnabled(bool value) async {
    healthFeedbackEnabled = value;
    await (await SharedPreferences.getInstance()).setBool(_feedbackKey, value);
  }

  Future<void> setAutomaticLogsEnabled(bool value) async {
    automaticLogsEnabled = value;
    await (await SharedPreferences.getInstance()).setBool(_autoLogsKey, value);
  }

  Future<void> reportPlayback({
    required String? channelId,
    required String? url,
    required bool playable,
  }) async {
    if (_disposed || !healthFeedbackEnabled) return;
    final sourceId = sourceIdForRoute(channelId, url);
    if (sourceId == null) return;
    final now = DateTime.now().toUtc();
    if (_reportsPausedUntil?.isAfter(now) ?? false) return;
    final previous = _reportTimes[sourceId];
    if (previous != null && now.difference(previous) < _reportInterval) return;
    final fingerprint = await ClientFingerprintService.instance.initialize();
    if (fingerprint == null || _disposed || !healthFeedbackEnabled) return;
    final apiFingerprint = ClientFingerprintService.instance.apiFingerprint;
    if (apiFingerprint == null) return;
    _reportTimes[sourceId] = now;
    try {
      await (await SharedPreferences.getInstance()).setString(
        _reportTimesKey,
        jsonEncode(_reportTimes.map((key, value) =>
            MapEntry(key, value.toIso8601String()))),
      );
      await api.postPlaybackReport(
        sourceId: sourceId, fingerprint: apiFingerprint, playable: playable,
      );
    } on BobTvApiException catch (error) {
      if (error.statusCode == 429 || error.statusCode == 503) {
        _reportsPausedUntil = now.add(error.retryAfter ?? const Duration(minutes: 5));
      } else if (error.statusCode == 404) {
        unawaited(refreshCatalog());
      }
      AppDiagnostics.instance.log('bobtv_report_status', {
        'status': error.statusCode,
      });
    } catch (error, stackTrace) {
      AppDiagnostics.instance.recordError('bobtv_report', error, stackTrace);
    }
  }

  Future<String> submitCandidate({
    required String name,
    required String url,
    required bool consent,
  }) async {
    if (_disposed || !consent) throw const FormatException('Consent required');
    final fingerprint = await ClientFingerprintService.instance.initialize();
    if (fingerprint == null) throw StateError('Client fingerprint unavailable');
    final device = Platform.isWindows ? 'Windows' : Platform.isAndroid
        ? 'Android' : Platform.isIOS ? 'iOS' : Platform.isMacOS
        ? 'macOS' : Platform.isLinux ? 'Linux' : 'Other';
    return _retryLimited(() => api.submitCandidate(
      name: name, url: url, device: device,
      fingerprint: ClientFingerprintService.instance.apiFingerprint!,
      consent: true,
    ));
  }

  Future<bool> uploadLogSnapshot() async {
    if (_disposed) throw StateError('Service closed');
    final directoryPath = AppDiagnostics.instance.logDirectoryPath;
    if (directoryPath == null) throw StateError('Diagnostics unavailable');
    final directory = Directory(directoryPath);
    final files = await directory.list().where((item) =>
        item is File && p.extension(item.path) == '.log').cast<File>().toList();
    files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    final lines = <String>[];
    for (final file in files.take(2)) {
      final all = await file.readAsLines();
      lines.addAll(all.length > 1000 ? all.sublist(all.length - 1000) : all);
    }
    if (lines.isEmpty) {
      lines.add(jsonEncode({
        'time': DateTime.now().toUtc().toIso8601String(),
        'event': 'diagnostic_snapshot',
        'platform': Platform.operatingSystem,
      }));
    }
    var snapshot = BobTvLogProjection.project(lines);
    if (snapshot.isEmpty) {
      snapshot = BobTvLogProjection.project([
        jsonEncode({
          'time': DateTime.now().toUtc().toIso8601String(),
          'event': 'diagnostic_snapshot',
          'platform': Platform.operatingSystem,
        }),
      ]);
    }
    return _retryLimited(() => api.uploadLogSnapshot(snapshot));
  }

  Future<void> _uploadAutomaticLogs() async {
    try {
      if (automaticLogsEnabled && !_disposed) await uploadLogSnapshot();
    } catch (error, stackTrace) {
      AppDiagnostics.instance.recordError('bobtv_auto_logs', error, stackTrace);
    }
  }

  Future<List<BobTvRelease>> fetchReleases() =>
      _retryLimited(api.fetchReleases);

  Future<File> downloadRelease(BobTvRelease release) async {
    final root = Platform.isWindows &&
            (Platform.environment['LOCALAPPDATA']?.isNotEmpty ?? false)
        ? Directory(p.join(Platform.environment['LOCALAPPDATA']!,
            'HotelTV', 'Update', 'Downloads'))
        : Directory(p.join((await getApplicationSupportDirectory()).path,
            'BobTV', 'Downloads'));
    return api.downloadRelease(release, root);
  }

  Future<T> _retryLimited<T>(Future<T> Function() operation) async {
    for (var attempt = 0; ; attempt++) {
      if (_disposed) throw StateError('Service closed');
      try {
        return await operation();
      } on BobTvApiException catch (error) {
        final status = error.statusCode;
        if (attempt >= 2 || status == null ||
            status != 429 && status != 503 && status < 500) rethrow;
        final delay = status == 429 || status == 503
            ? error.retryAfter ?? Duration(seconds: 2 << attempt)
            : Duration(seconds: 2 << attempt);
        if (delay > const Duration(seconds: 30)) rethrow;
        await Future<void>.delayed(delay);
      } on TimeoutException {
        if (attempt >= 2) rethrow;
        await Future<void>.delayed(Duration(seconds: 2 << attempt));
      } on SocketException {
        if (attempt >= 2) rethrow;
        await Future<void>.delayed(Duration(seconds: 2 << attempt));
      }
    }
  }

  void dispose() {
    _disposed = true;
    _logTimer?.cancel();
    api.close();
    state.dispose();
  }
}

final bobTvCommunityProvider = Provider<BobTvCommunityService>((ref) {
  final service = BobTvCommunityService(ref.watch(databaseProvider));
  ref.onDispose(service.dispose);
  return service;
});
