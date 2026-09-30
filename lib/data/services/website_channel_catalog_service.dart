import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/app_diagnostics.dart';
import '../datasources/local/database.dart' as db;
import 'bobtv_api_client.dart';
import 'channel_category_classifier.dart';

class WebsiteCatalogProgress {
  const WebsiteCatalogProgress({
    this.phase = '',
    this.imported = 0,
    this.total = 0,
    this.complete = false,
    this.error = false,
  });
  final String phase;
  final int imported;
  final int total;
  final bool complete;
  final bool error;
}

/// Synchronizes an immutable website snapshot without modifying user sources.
class WebsiteChannelCatalogService {
  WebsiteChannelCatalogService({required this.database, BobTvApiClient? api})
    : api = api ?? BobTvApiClient();

  static const providerId = 'bobtv-channel-catalog';
  static const _versionKey = 'bobtv_website_catalog_version_v1';

  /// The website list is the common default on every installation. Personal
  /// subscriptions remain available in advanced mode and favorites.
  static bool showInSimpleMode({
    required bool sharedCatalogAvailable,
    required bool personalCollection,
    required String providerId,
  }) =>
      !sharedCatalogAvailable ||
      personalCollection ||
      providerId == WebsiteChannelCatalogService.providerId;

  static String categoryForGroup(String? group) {
    final parts = (group ?? '').split(' / ');
    if (parts.first == '中国' && parts.length > 1) {
      return ChannelCategoryClassifier.categories.contains(parts[1])
          ? parts[1]
          : '其他';
    }
    if (parts.first == '国际') return '国际';
    return ChannelCategoryClassifier.categories.contains(parts.first)
        ? parts.first
        : '其他';
  }

  static String countryForGroup(String? group) {
    final parts = (group ?? '').split(' / ');
    if (parts.length > 1 &&
        parts.first == '国际' &&
        ChannelCategoryClassifier.internationalCountryNames.containsValue(
          parts[1],
        )) {
      return parts[1];
    }
    return '未识别地区';
  }

  final db.AppDatabase database;
  final BobTvApiClient api;
  final state = ValueNotifier(const WebsiteCatalogProgress());
  Future<int>? _running;
  bool _disposed = false;
  Object? lastError;

  Future<int> sync() =>
      _running ??= _sync().whenComplete(() => _running = null);

  Future<int> importBundled() => _running ??= _sync(
    source: _BundledCatalogApi(),
  ).whenComplete(() => _running = null);

  Future<int> _sync({BobTvApiClient? source}) async {
    final client = source ?? api;
    if (_disposed) return 0;
    lastError = null;
    state.value = const WebsiteCatalogProgress(phase: '正在检查网站频道');
    try {
      final globalBlocked = await client.fetchCatalogBlockedRoutes();
      final localBlocked = await database.getBlockedStreamUrls();
      for (final url in globalBlocked) {
        if (!localBlocked.contains(url)) {
          await database.blockAndDeleteStreamUrl(
            url,
            reason: 'shared_catalog_retired',
          );
        }
      }
      final manifest = await client.fetchChannelCatalogManifest();
      if (_disposed || manifest == null) {
        state.value = const WebsiteCatalogProgress(complete: true);
        return 0;
      }
      final prefs = await SharedPreferences.getInstance();
      final installed = (await database.getChannelsForProvider(
        providerId,
      )).isNotEmpty;
      if (prefs.getString(_versionKey) == manifest.version && installed) {
        state.value = WebsiteCatalogProgress(
          phase: '网站频道已是最新',
          imported: manifest.routeCount,
          total: manifest.routeCount,
          complete: true,
        );
        return 0;
      }
      state.value = WebsiteCatalogProgress(
        phase: '正在下载网站频道',
        total: manifest.routeCount,
      );
      final bytes = await client.downloadChannelCatalog(manifest);
      if (_disposed) return 0;
      final records = await compute(_decodeCatalogFromMessage, {
        'bytes': bytes,
        'version': manifest.version,
        'channelCount': manifest.channelCount,
        'routeCount': manifest.routeCount,
      });
      if (_disposed) return 0;
      final existing = {
        for (final channel in await database.getChannelsForProvider(providerId))
          channel.id: channel,
      };
      final blockedUrls = await database.getBlockedStreamUrls();
      final existingByUrl = <String, List<db.Channel>>{};
      for (final channel in existing.values) {
        (existingByUrl[channel.streamUrl] ??= []).add(channel);
      }
      final knownChecks = await database.getStreamChecksForChannels(
        existing.values.toList(),
      );
      final knownUrls = knownChecks.map((check) => check.streamUrl).toSet();
      final keepIds = <String>{};
      var imported = 0;
      await database.transaction(() async {
        final providers = await database.getAllProviders();
        if (!providers.any((provider) => provider.id == providerId)) {
          await database.upsertProvider(
            db.ProvidersCompanion.insert(
              id: providerId,
              name: 'BobTV 网站频道',
              type: 'catalog',
            ),
          );
        }
        for (var offset = 0; offset < records.length; offset += 400) {
          if (_disposed) throw StateError('Catalog sync canceled');
          final batch = <db.ChannelsCompanion>[];
          for (final record in records.skip(offset).take(400)) {
            if (blockedUrls.contains(record['url'])) continue;
            final id = '$providerId:${record['routeId']}';
            final old = existing[id] ?? existingByUrl[record['url']]?.first;
            keepIds.add(id);
            batch.add(
              db.ChannelsCompanion.insert(
                id: id,
                providerId: providerId,
                name: record['name'] as String,
                streamUrl: record['url'] as String,
                groupTitle: Value(record['group'] as String),
                tvgId: Value(record['epgId'] as String?),
                tvgLogo: Value(record['logoUrl'] as String?),
                channelNumber: Value(record['order'] as int),
                favorite: Value(old?.favorite ?? false),
                hidden: Value(old?.hidden ?? false),
                sortOrder: Value(old?.sortOrder ?? 0),
              ),
            );
          }
          await database.upsertChannels(batch);
          for (final record in records.skip(offset).take(400)) {
            if (blockedUrls.contains(record['url'])) continue;
            final id = '$providerId:${record['routeId']}';
            for (final old in existingByUrl[record['url']] ?? <db.Channel>[]) {
              if (old.id != id) await database.copyChannelReferences(old.id, id);
            }
          }
          final verified = <db.StreamChecksCompanion>[];
          for (final record in records.skip(offset).take(400)) {
            final url = record['url'] as String;
            final success = DateTime.tryParse(
              record['lastPlayableAt'] as String? ?? '',
            );
            if (blockedUrls.contains(url) ||
                knownUrls.contains(url) ||
                success == null ||
                success.isAfter(
                  DateTime.now().add(const Duration(minutes: 5)),
                ) ||
                success.isBefore(
                  DateTime.now().subtract(const Duration(days: 7)),
                )) {
              continue;
            }
            verified.add(
              db.StreamChecksCompanion.insert(
                streamUrl: url,
                providerId: providerId,
                channelId: '$providerId:${record['routeId']}',
                lastSuccessAt: Value(success),
                lastCheckedAt: Value(success),
              ),
            );
          }
          await database.upsertStreamChecks(verified);
          imported += batch.length;
          if (!_disposed) {
            state.value = WebsiteCatalogProgress(
              phase: '正在整理网站频道',
              imported: imported,
              total: records.length,
            );
          }
        }
        await database.deleteChannelsMissingFromProvider(providerId, keepIds);
        await database.markProviderRefreshed(providerId, DateTime.now());
      });
      await prefs.setString(_versionKey, manifest.version);
      if (!_disposed) {
        state.value = WebsiteCatalogProgress(
          phase: '网站频道已同步',
          imported: imported,
          total: records.length,
          complete: true,
        );
      }
      AppDiagnostics.instance.log('website_channel_catalog_synced', {
        'version': manifest.version,
        'routes': imported,
      });
      return imported;
    } catch (error, stackTrace) {
      lastError = error;
      if (!_disposed) {
        state.value = const WebsiteCatalogProgress(
          phase: '网站频道暂不可用，继续使用本机频道',
          error: true,
        );
      }
      AppDiagnostics.instance.recordError(
        'website_channel_catalog',
        error,
        stackTrace,
      );
      return 0;
    } finally {
      source?.close();
    }
  }

  void dispose() {
    _disposed = true;
    api.close();
    state.dispose();
  }
}

class _BundledCatalogApi extends BobTvApiClient {
  late List<int> _bytes;
  @override
  Future<List<String>> fetchCatalogBlockedRoutes() async => const [];
  @override
  Future<BobTvChannelCatalogManifest?> fetchChannelCatalogManifest() async {
    final data = await rootBundle.load(
      'assets/data/channel_catalog_starter.json.gz',
    );
    _bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    final payload = jsonDecode(utf8.decode(gzip.decode(_bytes))) as Map;
    final channels = payload['channels'] as List;
    final digest = sha256.convert(_bytes).toString();
    return BobTvChannelCatalogManifest(
      version: payload['version'] as String,
      channelCount: channels.length,
      routeCount: channels.fold<int>(
        0,
        (total, row) => total + (row['routes'] as List).length,
      ),
      snapshotPath: '/api/v1/channel-catalog/snapshots/$digest.json.gz',
      compressedBytes: _bytes.length,
      sha256: digest,
    );
  }

  @override
  Future<List<int>> downloadChannelCatalog(
    BobTvChannelCatalogManifest manifest,
  ) async => _bytes;
}

Future<List<Map<String, Object?>>> _decodeCatalogFromMessage(
  Map<String, Object> message,
) => _decodeCatalog(
  message['bytes'] as List<int>,
  message['version'] as String,
  message['channelCount'] as int,
  message['routeCount'] as int,
);

Future<List<Map<String, Object?>>> _decodeCatalog(
  List<int> compressed,
  String version,
  int channelCount,
  int routeCount,
) async {
  final raw = <int>[];
  await for (final chunk in gzip.decoder.bind(Stream.value(compressed))) {
    if (raw.length + chunk.length > 128 * 1024 * 1024) {
      throw const FormatException('Expanded catalog too large');
    }
    raw.addAll(chunk);
  }
  final decoded = jsonDecode(utf8.decode(raw));
  if (decoded is! Map ||
      decoded['schemaVersion'] != 1 ||
      decoded['version'] != version ||
      decoded['categories'] is! List ||
      decoded['channels'] is! List) {
    throw const FormatException('Invalid website channel snapshot');
  }
  final categories = <String, Map>{};
  for (final category in decoded['categories'] as List) {
    if (category is! Map ||
        category['id'] is! String ||
        category['name'] is! String ||
        categories.containsKey(category['id'])) {
      throw const FormatException('Invalid website category');
    }
    categories[category['id'] as String] = category;
  }
  final channels = decoded['channels'] as List;
  if (channels.length != channelCount) {
    throw const FormatException('Channel count mismatch');
  }
  final result = <Map<String, Object?>>[];
  final ids = <String>{};
  for (final channel in channels) {
    if (channel is! Map ||
        channel['id'] is! String ||
        channel['name'] is! String ||
        channel['routes'] is! List ||
        channel['categoryId'] is! String ||
        !ids.add('channel:${channel['id']}')) {
      throw const FormatException('Invalid website channel');
    }
    final category = categories[channel['categoryId']];
    if (category == null) throw const FormatException('Unknown category');
    final group = _catalogGroupFor(
      category,
      categories,
      channel['countryCode'] as String?,
    );
    for (final route in channel['routes'] as List) {
      if (route is! Map ||
          route['id'] is! String ||
          route['url'] is! String ||
          !ids.add('route:${route['id']}') ||
          !BobTvApiClient.isPublicCatalogUrl(route['url'] as String)) {
        throw const FormatException('Invalid website route');
      }
      final name = channel['name'] as String;
      final url = route['url'] as String;
      if (ChannelCategoryClassifier.isClearlyNonTelevisionRoute(
        name: name,
        groupTitle: group,
        streamUrl: url,
      )) {
        throw const FormatException('Non-television website route');
      }
      result.add({
        'routeId': route['id'] as String,
        'name': name,
        'url': url,
        'group': group,
        'epgId': channel['epgId'] as String?,
        'logoUrl': channel['logoUrl'] as String?,
        'order': channel['sortOrder'] is int ? channel['sortOrder'] as int : 0,
        'lastPlayableAt': route['lastPlayableAt'] as String?,
      });
      if (result.length > routeCount) {
        throw const FormatException('Too many website routes');
      }
    }
  }
  if (result.length != routeCount) {
    throw const FormatException('Route count mismatch');
  }
  return result;
}

String _catalogGroupFor(
  Map category,
  Map<String, Map> categories,
  String? countryCode,
) {
  final chain = <String>[];
  var current = category;
  final visited = <String>{};
  while (true) {
    final id = current['id'];
    final name = current['name'];
    if (id is! String ||
        name is! String ||
        name.isEmpty ||
        !visited.add(id) ||
        chain.length >= 8) {
      throw const FormatException('Invalid website category tree');
    }
    chain.insert(0, name);
    final parentId = current['parentId'];
    if (parentId == null) break;
    current =
        categories[parentId] ??
        (throw const FormatException('Missing website category parent'));
  }
  final root = chain.first;
  final leaf = chain.last;
  if (root == '中国') {
    final categoryName = ChannelCategoryClassifier.categories.contains(leaf)
        ? leaf
        : '其他';
    return '中国 / $categoryName';
  }
  if (root == '国际') return chain.join(' / ');
  if (ChannelCategoryClassifier.internationalCountryNames.containsValue(root)) {
    return '国际 / ${chain.join(' / ')}';
  }
  final country = ChannelCategoryClassifier
      .internationalCountryNames[countryCode?.toLowerCase()];
  if (country != null) return '国际 / $country / $leaf';
  return ChannelCategoryClassifier.categories.contains(leaf) ? leaf : '其他';
}
