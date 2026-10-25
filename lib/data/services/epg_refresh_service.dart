import '../../core/server_egress.dart';
import 'dart:io';
import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../datasources/local/database.dart' as db;
import '../datasources/parsers/xmltv_parser.dart';
import '../models/server_epg_snapshot.dart';
import '../../features/providers/provider_manager.dart';
import 'local_epg_binding.dart';

class EpgRefreshService {
  final db.AppDatabase _db;
  final _work = <Future<void>>{};
  final _downloads = <Dio>{};
  bool _stopping = false;
  Timer? _refreshTimer;
  Future<void>? _refreshing;

  /// Keep XMLTV current while the player remains open, including fullscreen.
  /// Each check respects the refresh interval configured for that source.
  void startAutomaticRefresh({
    Duration checkEvery = const Duration(minutes: 15),
  }) {
    if (_stopping || _refreshTimer != null) return;
    if (checkEvery <= Duration.zero) throw ArgumentError.value(checkEvery);
    _refreshTimer = Timer.periodic(checkEvery, (_) {
      unawaited(
        refreshAllSources().catchError((Object error) {
          debugPrint(
            '[EPG] Automatic refresh unavailable: ${error.runtimeType}',
          );
        }),
      );
    });
  }

  bool get stopping => _stopping;

  Future<void> _track(Future<void> Function() operation) {
    if (_stopping) return Future.value();
    final work = Future<void>.sync(operation);
    _work.add(work);
    return work.whenComplete(() => _work.remove(work));
  }

  Future<void> shutdown() async {
    _stopping = true;
    _refreshTimer?.cancel();
    _refreshTimer = null;
    for (final dio in _downloads.toList()) {
      dio.close(force: true);
    }
    await Future.wait(
      _work.toList().map((work) => work.catchError((Object _) {})),
    );
  }

  static const chinaSourceId = 'hotel-cn-epg';
  static const chinaSourceName = '中国电视节目表';
  static const chinaSourceUrl = 'https://epg.zsdc.eu.org/t.xml.gz';
  static const extendedChinaSourceId = 'hotel-cn-epg-extended';
  static const extendedChinaSourceName = '中国扩展节目表';
  static const extendedChinaSourceUrl = 'https://epg.112114.xyz/pp.xml';

  EpgRefreshService(this._db);

  /// Refresh a single EPG source by ID.
  Future<void> refreshSource(String sourceId) =>
      _track(() => _refreshSource(sourceId));

  Future<void> _refreshSource(String sourceId) async {
    final sources = await _db.getAllEpgSources();
    if (_stopping) return;
    final source = sources.firstWhere((s) => s.id == sourceId);
    debugPrint('[EPG] Refreshing source: ${source.name} (${source.url})');

    // Download XMLTV data
    final dio = ServerEgress.dio(
      BaseOptions(
        extra: {'egressKind': 'epg'},
        headers: {'User-Agent': 'BobTV/1.0'},
      ),
    );
    _downloads.add(dio);
    try {
      final response = await dio.get<List<int>>(
        source.url,
        options: Options(responseType: ResponseType.bytes),
      );

      final bytes = response.data!;
      debugPrint('[EPG] Downloaded ${bytes.length} bytes');

      // Decompress + parse in background isolate to avoid ANR
      final result = await compute(
        _decompressAndParse,
        _DecompressParseArgs(bytes, sourceId),
      );
      debugPrint(
        '[EPG] Parsed ${result.channels.length} channels, ${result.programmes.length} programmes, skipped ${result.rejectedProgrammes} invalid records',
      );
      if (!_stopping) await importParsed(sourceId, result);
    } finally {
      _downloads.remove(dio);
      dio.close();
    }
  }

  /// Validate before changing cache; readers only see a complete committed guide.
  /// This importer is shared groundwork for the future server-version receiver.
  Future<void> importParsed(
    String sourceId,
    XmltvResult result, {
    DateTime? at,
  }) => _track(() => _importParsed(sourceId, result, at: at));

  Future<void> _importParsed(
    String sourceId,
    XmltvResult result, {
    DateTime? at,
  }) async {
    final now = at ?? DateTime.now();
    if (result.channels.isEmpty ||
        result.programmes.isEmpty ||
        !result.programmes.any((p) => p.stop.isAfter(now))) {
      throw const FormatException(
        'EPG is empty or contains only expired programmes',
      );
    }
    final channelIds = result.channels.map((c) => c.id).toSet();
    if (result.channels.any((c) => c.sourceId != sourceId || c.id.isEmpty) ||
        result.programmes.any(
          (p) =>
              p.sourceId != sourceId ||
              !channelIds.contains(p.channelId) ||
              p.title.trim().isEmpty ||
              !p.stop.isAfter(p.start),
        )) {
      throw const FormatException(
        'EPG source or programme identity is invalid',
      );
    }
    await _db.transaction(() async {
      if (!(await _db.getAllEpgSources()).any(
        (source) => source.id == sourceId,
      )) {
        throw StateError('EPG source no longer exists');
      }
      final channelCompanions = result.channels.map((c) {
        return db.EpgChannelsCompanion.insert(
          id: '${sourceId}_${c.id}',
          sourceId: sourceId,
          channelId: c.id,
          displayName: c.primaryName,
          iconUrl: Value(c.iconUrl),
        );
      }).toList();
      await _db.upsertEpgChannels(channelCompanions);

      // Replacing programmes, channel metadata and refresh time is one commit.
      await _db.deleteEpgProgrammesForSource(sourceId);
      final programmeCompanions = result.programmes.map((p) {
        return db.EpgProgrammesCompanion.insert(
          epgChannelId: '${sourceId}_${p.channelId}',
          sourceId: sourceId,
          title: p.title,
          description: Value(p.description),
          category: Value(p.category),
          subtitle: Value(p.subtitle),
          episodeNum: Value(p.episodeNum),
          start: p.start,
          stop: p.stop,
        );
      }).toList();
      if (programmeCompanions.isNotEmpty) {
        // Insert in batches of 5000 to avoid blocking the main thread
        for (var i = 0; i < programmeCompanions.length; i += 5000) {
          final end = (i + 5000).clamp(0, programmeCompanions.length);
          await _db.insertEpgProgrammes(programmeCompanions.sublist(i, end));
          // Yield to the event loop between batches
          await Future<void>.delayed(Duration.zero);
        }
      }

      await _db.updateEpgSourceRefreshTime(sourceId);
      await LocalEpgBinding(_db).reconcile(at: now);
    });
  }

  /// Refresh all enabled XMLTV sources according to their configured interval.
  Future<void> refreshAllSources({bool force = false}) =>
      _refreshing ??= _track(
        () => _refreshAllSources(force: force),
      ).whenComplete(() => _refreshing = null);

  Future<void> _refreshAllSources({bool force = false}) async {
    final sources = await _db.getAllEpgSources();
    final now = DateTime.now();
    for (final source in sources.where((s) => s.enabled)) {
      // This source is version-driven; it must never enter the XMLTV/4h path.
      if (source.id == serverEpgSourceId) continue;
      if (!force &&
          source.lastRefresh != null &&
          now.difference(source.lastRefresh!) <
              Duration(hours: source.refreshIntervalHours.clamp(1, 168))) {
        debugPrint(
          '[EPG] Skipping ${source.name} — refreshed ${now.difference(source.lastRefresh!).inMinutes}m ago',
        );
        continue;
      }
      try {
        await refreshSource(source.id);
      } catch (e) {
        debugPrint('[EPG] Error refreshing ${source.name}: $e');
      }
    }
    if (!_stopping) await LocalEpgBinding(_db).reconcile();
  }

  /// Ensure the hotel TV build has a Chinese XMLTV source.
  Future<void> addDefaultSources() => _track(_addDefaultSources);

  Future<void> _addDefaultSources() async {
    final existing = await _db.getAllEpgSources();
    // Seed only an unconfigured installation. Existing global, custom and
    // disabled sources belong to the user and must remain unchanged.
    if (existing.any((source) => source.id != serverEpgSourceId)) return;

    final existingUrls = existing.map((source) => source.url).toSet();
    if (!existingUrls.contains(chinaSourceUrl)) {
      await _insertSource(
        id: chinaSourceId,
        name: chinaSourceName,
        url: chinaSourceUrl,
      );
    }
    if (!existingUrls.contains(extendedChinaSourceUrl)) {
      await _insertSource(
        id: extendedChinaSourceId,
        name: extendedChinaSourceName,
        url: extendedChinaSourceUrl,
      );
    }
  }

  /// Delete all existing sources and re-add defaults.
  Future<void> resetToDefaultSources() async {
    final existing = await _db.getAllEpgSources();
    for (final s in existing) {
      await _db.deleteEpgSource(s.id);
    }
    await _insertDefaults();
  }

  Future<void> _insertDefaults() async {
    await _insertSource(
      id: chinaSourceId,
      name: chinaSourceName,
      url: chinaSourceUrl,
    );
    await _insertSource(
      id: extendedChinaSourceId,
      name: extendedChinaSourceName,
      url: extendedChinaSourceUrl,
    );
  }

  Future<void> _insertSource({
    required String id,
    required String name,
    required String url,
  }) async {
    await _db.upsertEpgSource(
      db.EpgSourcesCompanion.insert(
        id: id,
        name: name,
        url: url,
        enabled: const Value(true),
        refreshIntervalHours: const Value(4),
      ),
    );
  }
}

final epgRefreshServiceProvider = Provider<EpgRefreshService>((ref) {
  final service = EpgRefreshService(ref.watch(databaseProvider));
  service.startAutomaticRefresh();
  ref.onDispose(() => unawaited(service.shutdown()));
  return service;
});

/// Args for the background isolate (must be serializable).
class _DecompressParseArgs {
  final List<int> bytes;
  final String sourceId;
  const _DecompressParseArgs(this.bytes, this.sourceId);
}

/// Top-level function for compute() — runs decompression + XML parsing off the main thread.
XmltvResult _decompressAndParse(_DecompressParseArgs args) {
  List<int> decompressed;
  try {
    decompressed = gzip.decode(args.bytes);
  } catch (_) {
    decompressed = args.bytes;
  }
  final xmlContent = utf8.decode(decompressed, allowMalformed: true);
  return XmltvParser().parse(xmlContent, sourceId: args.sourceId);
}
