import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/app_diagnostics.dart';
import '../datasources/local/database.dart' as db;
import 'github_ai_crawler_service.dart';

typedef SnapshotBytesLoader = Future<Uint8List> Function();

/// Imports the sanitized GitHub route snapshot shipped with a release.
///
/// The snapshot contains channel routes and their public GitHub provenance.
/// It intentionally excludes user preferences, playback history, health
/// scores, diagnostics, crash dumps, and runtime API configuration.
class BundledSourceSnapshotService {
  static const assetPath = 'assets/data/github_ai_snapshot.json.gz';
  static const _preferenceKey = 'hotel_tv_bundled_source_snapshot_id_v1';

  final db.AppDatabase database;
  final SnapshotBytesLoader _loadBytes;

  BundledSourceSnapshotService({
    required this.database,
    SnapshotBytesLoader? loadBytes,
  }) : _loadBytes = loadBytes ?? _loadAssetBytes;

  static Future<Uint8List> _loadAssetBytes() async {
    final data = await rootBundle.load(assetPath);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  Future<int> run() async {
    final bytes = await _loadBytes();
    final decoded = jsonDecode(utf8.decode(gzip.decode(bytes)));
    if (decoded is! Map<String, dynamic> || decoded['schemaVersion'] != 1) {
      throw const FormatException('Unsupported bundled source snapshot');
    }
    final snapshotId = decoded['snapshotId']?.toString().trim() ?? '';
    final rawChannels = decoded['channels'];
    if (snapshotId.isEmpty || rawChannels is! List) {
      throw const FormatException('Bundled source snapshot is incomplete');
    }

    final preferences = await SharedPreferences.getInstance();
    if (preferences.getString(_preferenceKey) == snapshotId) return 0;

    final providers = await database.getAllProviders();
    if (!providers.any(
      (provider) => provider.id == GitHubAiCrawlerService.providerId,
    )) {
      await database.upsertProvider(
        db.ProvidersCompanion.insert(
          id: GitHubAiCrawlerService.providerId,
          name: 'GitHub 智慧来源',
          type: 'crawler',
        ),
      );
    }

    final existingChannels = {
      for (final channel in await database.getChannelsForProvider(
        GitHubAiCrawlerService.providerId,
      ))
        channel.id: channel,
    };
    final existingProvenance = {
      for (final source in await database.getDiscoveredStreamSources())
        source.channelId: source,
    };
    final generatedAt =
        DateTime.tryParse(decoded['generatedAt']?.toString() ?? '') ??
        DateTime.now().toUtc();
    var imported = 0;

    for (var offset = 0; offset < rawChannels.length; offset += 400) {
      final channelEntries = <db.ChannelsCompanion>[];
      final provenanceEntries = <db.DiscoveredStreamSourcesCompanion>[];
      for (final raw in rawChannels.skip(offset).take(400)) {
        if (raw is! Map) continue;
        final id = _text(raw['id']);
        final name = _text(raw['name']);
        final streamUrl = _text(raw['streamUrl']);
        final owner = _text(raw['githubOwner']);
        final repo = _text(raw['githubRepo']);
        final ref = _text(raw['githubRef']);
        final path = _text(raw['githubPath']);
        final documentUrl = _text(raw['sourceDocumentUrl']);
        if (id.isEmpty ||
            name.isEmpty ||
            owner.isEmpty ||
            repo.isEmpty ||
            ref.isEmpty ||
            path.isEmpty ||
            documentUrl.isEmpty ||
            !isSupportedStreamUrl(streamUrl)) {
          continue;
        }
        final saved = existingChannels[id];
        final provenance = existingProvenance[id];
        channelEntries.add(
          db.ChannelsCompanion.insert(
            id: id,
            providerId: GitHubAiCrawlerService.providerId,
            name: name,
            tvgId: Value(_nullableText(raw['tvgId'])),
            tvgName: Value(_nullableText(raw['tvgName']) ?? name),
            tvgLogo: Value(_nullableText(raw['tvgLogo'])),
            groupTitle: Value(
              _nullableText(raw['groupTitle']) ?? 'GitHub 智慧发现',
            ),
            channelNumber: Value(_integer(raw['channelNumber'])),
            streamUrl: streamUrl,
            streamType: const Value('live'),
            favorite: Value(saved?.favorite ?? false),
            hidden: Value(saved?.hidden ?? false),
            sortOrder: Value(saved?.sortOrder ?? 0),
          ),
        );
        provenanceEntries.add(
          db.DiscoveredStreamSourcesCompanion.insert(
            channelId: id,
            streamUrl: streamUrl,
            githubOwner: owner,
            githubRepo: repo,
            githubRef: ref,
            githubPath: path,
            sourceDocumentUrl: documentUrl,
            confidence: Value(_confidence(raw['confidence'])),
            firstSeenAt: provenance?.firstSeenAt ?? generatedAt,
            lastSeenAt: generatedAt,
          ),
        );
      }
      await database.upsertChannels(channelEntries);
      await database.upsertDiscoveredStreamSources(provenanceEntries);
      imported += channelEntries.length;
    }

    await database.markProviderRefreshed(
      GitHubAiCrawlerService.providerId,
      DateTime.now(),
    );
    await preferences.setString(_preferenceKey, snapshotId);
    AppDiagnostics.instance.log('bundled_source_snapshot_imported', {
      'snapshotId': snapshotId,
      'routes': imported,
    });
    return imported;
  }

  static String _text(Object? value) => value?.toString().trim() ?? '';

  static String? _nullableText(Object? value) {
    final text = _text(value);
    return text.isEmpty ? null : text;
  }

  static int? _integer(Object? value) =>
      value is num ? value.toInt() : int.tryParse(value?.toString() ?? '');

  static double _confidence(Object? value) {
    final result = value is num
        ? value.toDouble()
        : double.tryParse(value?.toString() ?? '') ?? 0.0;
    return result.clamp(0.0, 1.0);
  }
}
