import '../../core/server_egress.dart';
import '../../data/resource_package/resource_package.dart';
import '../../data/resource_package/resource_package_client.dart';
import '../../data/resource_package/resource_package_store.dart';
import 'package:uuid/uuid.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../data/datasources/local/database.dart' as db;
import '../../data/datasources/parsers/m3u_parser.dart';
import '../../data/datasources/remote/xtream_client.dart';
import '../../data/models/channel.dart' hide Provider;
import '../../data/services/logo_resolver_service.dart';
import '../../data/services/channel_category_classifier.dart';
import '../../core/feature_gate.dart';
import 'package:dio/dio.dart';

/// Manages IPTV providers: adding, refreshing, channel loading.
class ProviderManager {
  final db.AppDatabase _db;
  final M3uParser _m3uParser = M3uParser();

  ProviderManager(this._db);

  db.AppDatabase get database => _db;

  /// Check provider count against tier limit.
  Future<void> _checkProviderLimit() async {
    final existing = await _db.getAllProviders();
    if (existing.length >= FeatureGate.maxProviders) {
      throw ProviderLimitException(FeatureGate.maxProviders);
    }
  }

  Future<ResourcePackage> previewResourcePackage(String address) =>
      ResourcePackageClient().fetch(address);

  Future<void> addResourcePackage({
    required String id,
    required String address,
    required ResourcePackage package,
  }) async {
    await _checkProviderLimit();
    await ResourcePackageStore(
      _db,
    ).apply(providerId: id, package: package, address: address, create: true);
    _enrichProvider(id);
  }

  final Map<String, DateTime> _lastResourceAttempt = {};
  bool _closing = false;
  Future<void> refreshResourcePackagesDue() async {
    if (_closing) return;
    for (final provider in await _db.getAllProviders()) {
      if (_closing) return;
      if (provider.type != 'resource' ||
          !provider.enabled ||
          (provider.url?.isEmpty ?? true)) {
        continue;
      }
      final now = DateTime.now();
      final last = _lastResourceAttempt[provider.id] ?? provider.lastRefresh;
      if (last != null && now.difference(last) < const Duration(minutes: 15)) {
        continue;
      }
      _lastResourceAttempt[provider.id] = now;
      try {
        await _refreshResource(provider);
      } catch (_) {
        /* Retain last snapshot. */
      }
    }
  }

  Future<void> shutdownResourcePackages() async {
    _closing = true;
    await Future.wait(
      _resourceRefreshes.values.map((f) => f.catchError((Object _) => 0)),
    );
  }

  final Map<String, Future<int>> _resourceRefreshes = {};

  Future<int> _refreshResource(db.Provider provider) =>
      _resourceRefreshes.putIfAbsent(provider.id, () async {
        try {
          final package = await previewResourcePackage(provider.url!);
          final count = await ResourcePackageStore(_db).apply(
            providerId: provider.id,
            package: package,
            address: provider.url!,
            create: false,
          );
          _enrichProvider(provider.id);
          return count;
        } finally {
          _resourceRefreshes.remove(provider.id);
        }
      });

  void _enrichProvider(String id) async {
    try {
      final rows = await _db.getChannelsForProvider(id);
      await resolveLogosForChannels(
        rows
            .where((c) => c.streamUrl.isNotEmpty)
            .map(
              (c) => Channel(
                id: c.id,
                providerId: id,
                name: c.name,
                streamUrl: c.streamUrl,
                groupTitle: c.groupTitle,
                tvgId: c.tvgId,
                tvgLogo: c.tvgLogo,
              ),
            )
            .toList(),
      );
    } catch (_) {
      /* Enrichment never rolls back a valid import. */
    }
  }

  Future<void> addSingleRoute({
    required String name,
    required String address,
    String? category,
  }) async {
    final uri = ResourcePackage.url(address, 'stream URL', media: true);
    const providerId = 'user-manual-routes';
    await _db.transaction(() async {
      if (!(await _db.getAllProviders()).any((p) => p.id == providerId)) {
        await _checkProviderLimit();
        await _db.upsertProvider(
          db.ProvidersCompanion.insert(
            id: providerId,
            name: '手工线路',
            type: 'manual',
          ),
        );
      }
      final existing = await _db.getChannelsForProvider(providerId);
      if (existing.any((c) => c.streamUrl == uri.toString())) return;
      final group = category?.trim();
      await _db
          .into(_db.channels)
          .insertOnConflictUpdate(
            db.ChannelsCompanion.insert(
              id: const Uuid().v4(),
              providerId: providerId,
              name: name,
              streamUrl: uri.toString(),
              groupTitle: Value(
                group == null || group.isEmpty
                    ? ChannelCategoryClassifier.classify(
                        name: name,
                        streamUrl: uri.toString(),
                      )
                    : group,
              ),
            ),
          );
    });
    _enrichProvider(providerId);
  }

  /// Add an M3U provider.
  Future<void> addM3uProvider({
    required String id,
    required String name,
    required String url,
  }) async {
    await _checkProviderLimit();
    await _db.upsertProvider(
      db.ProvidersCompanion.insert(
        id: id,
        name: name,
        type: 'm3u',
        url: Value(url),
      ),
    );
    await refreshProvider(id);
  }

  /// Add an Xtream Codes provider.
  Future<void> addXtreamProvider({
    required String id,
    required String name,
    required String url,
    required String username,
    required String password,
  }) async {
    await _checkProviderLimit();
    await _db.upsertProvider(
      db.ProvidersCompanion.insert(
        id: id,
        name: name,
        type: 'xtream',
        url: Value(url),
        username: Value(username),
        password: Value(password),
      ),
    );
    await refreshProvider(id);
  }

  /// Refresh a provider's channels from its source.
  Future<int> refreshProvider(String providerId) async {
    final providers = await _db.getAllProviders();
    final provider = providers.firstWhere((p) => p.id == providerId);

    if (provider.type == 'resource') {
      return (provider.url?.isEmpty ?? true) ? 0 : _refreshResource(provider);
    }

    List<Channel> channels;
    if (provider.type == 'm3u') {
      channels = await _refreshM3u(provider);
    } else if (provider.type == 'xtream') {
      channels = await _refreshXtream(provider);
    } else {
      return 0;
    }

    final parsedCount = channels.length;
    if (parsedCount == 0) {
      throw StateError('Provider returned no channels');
    }

    final retiredUrls = await _db.getRetiredStreamUrls(providerId);
    channels = channels
        .where(
          (channel) =>
              !retiredUrls.contains(channel.streamUrl) &&
              !ChannelCategoryClassifier.isClearlyNonTelevisionRoute(
                name: channel.name,
                groupTitle: channel.groupTitle,
                streamUrl: channel.streamUrl,
              ),
        )
        .toList();

    final existing = await _db.getChannelsForProvider(providerId);
    final existingById = {for (final channel in existing) channel.id: channel};

    // Save channels while retaining local favorite and visibility choices.
    await _db.upsertChannels(
      channels.map((c) {
        final saved = existingById[c.id];
        return db.ChannelsCompanion.insert(
          id: c.id,
          providerId: c.providerId,
          name: c.name,
          tvgId: Value(c.tvgId),
          tvgName: Value(c.tvgName),
          tvgLogo: Value(c.tvgLogo),
          groupTitle: Value(c.groupTitle),
          channelNumber: Value(c.channelNumber),
          streamUrl: c.streamUrl,
          streamType: Value(c.streamType.name),
          favorite: Value(saved?.favorite ?? false),
          hidden: Value(saved?.hidden ?? false),
          sortOrder: Value(saved?.sortOrder ?? 0),
        );
      }).toList(),
    );

    await _db.deleteChannelsMissingFromProvider(
      providerId,
      channels.map((channel) => channel.id).toSet(),
    );

    await _db.markProviderRefreshed(providerId, DateTime.now());

    // Resolve missing logos in background
    _resolveChannelLogos(channels).catchError((_) {});

    return channels.length;
  }

  Future<List<Channel>> _refreshM3u(db.Provider provider) async {
    final host = Uri.tryParse(provider.url ?? '')?.host.toLowerCase() ?? '';
    if (host == 'github.com' ||
        host == 'raw.githubusercontent.com' ||
        host == 'api.github.com' ||
        host.endsWith('.github.io')) {
      throw StateError('GitHub 公共线路由服务器统一刷新，请使用公共频道库；已有频道会保留');
    }
    final dio = ServerEgress.dio(
      BaseOptions(extra: {'egressKind': 'playlist'}),
    );
    try {
      final response = await dio.get<String>(provider.url!);
      final result = _m3uParser.parse(response.data!, providerId: provider.id);
      return result.channels;
    } finally {
      dio.close();
    }
  }

  Future<List<Channel>> _refreshXtream(db.Provider provider) async {
    final client = XtreamClient(
      baseUrl: provider.url!,
      username: provider.username!,
      password: provider.password!,
    );
    try {
      return await client.getLiveStreams(providerId: provider.id);
    } finally {
      client.dispose();
    }
  }

  Future<void> deleteProvider(String id) async {
    final provider = (await _db.getAllProviders())
        .where((p) => p.id == id)
        .firstOrNull;
    if (provider?.type == 'resource') {
      await ResourcePackageStore(_db).remove(id);
      return;
    }
    if (provider?.type == 'manual') {
      await _db.transaction(() async {
        await _db.deleteChannelsByIds(
          (await _db.getChannelsForProvider(id)).map((c) => c.id),
        );
        await _db.deleteProvider(id);
      });
      return;
    }
    await _db.deleteProvider(id);
  }

  /// Resolve missing logos in background after provider refresh.
  Future<void> _resolveChannelLogos(List<Channel> channels) async {
    await resolveLogosForChannels(channels);
  }

  /// Resolve missing logos for a set of channels.
  /// Public so it can be called at startup for existing DB channels.
  Future<void> resolveLogosForChannels(List<Channel> channels) async {
    final needsLogo = channels
        .where((c) => c.tvgLogo == null || c.tvgLogo!.isEmpty)
        .map((c) => (id: c.id, name: c.name, tvgLogo: c.tvgLogo))
        .toList();

    if (needsLogo.isEmpty) return;
    debugPrint('[Logo] ${needsLogo.length} channels need logos');

    final resolved = <String, String>{};

    // First try EPG icons for channels that have EPG mappings
    try {
      final epgChannels = await _db.select(_db.epgChannels).get();
      final epgIconMap = <String, String>{};
      for (final ec in epgChannels) {
        if (ec.iconUrl != null && ec.iconUrl!.isNotEmpty) {
          epgIconMap[ec.displayName.toLowerCase()] = ec.iconUrl!;
          epgIconMap[ec.channelId.toLowerCase()] = ec.iconUrl!;
        }
      }
      for (final ch in needsLogo.toList()) {
        final stripped = ch.name
            .toLowerCase()
            .replaceAll(RegExp(r'^[a-z]{2}[-]?[a-z]?\|\s*'), '')
            .replaceAll(RegExp(r'^[a-z]{2}:\s+'), '')
            .replaceAll(RegExp(r'^\[?[a-z]{2}\]?\s+'), '')
            .replaceAll(RegExp(r'^[a-z]{2}\s+'), '');
        final icon = epgIconMap[ch.name.toLowerCase()] ?? epgIconMap[stripped];
        if (icon != null) {
          resolved[ch.id] = icon;
          needsLogo.removeWhere((c) => c.id == ch.id);
        }
      }
      debugPrint('[Logo] EPG icons resolved ${resolved.length} channels');
    } catch (_) {}

    // Then resolve remaining from tv-logo/tv-logos GitHub repo
    if (needsLogo.isNotEmpty) {
      debugPrint('[Logo] Resolving ${needsLogo.length} via GitHub tv-logos...');
      final ghResolved = await LogoResolverService.resolveLogosForChannels(
        needsLogo,
      );
      debugPrint('[Logo] GitHub resolved ${ghResolved.length} logos');
      resolved.addAll(ghResolved);
    }

    // Batch-write all resolved logos in a single transaction
    if (resolved.isNotEmpty) {
      await _db.updateChannelLogos(resolved);
    }
  }

  static const _logoResolvedKey = 'logo_last_resolved';
  static const _logoChannelCountKey = 'logo_channel_count';
  static const _logoCooldown = Duration(hours: 6);
  static const _logoBatchSize = 200;

  /// Resolve missing logos progressively: favorites first, then the rest
  /// in small batches so the UI stays responsive.
  /// Skips entirely if resolved recently and channel count hasn't changed.
  Future<void> resolveAllMissingLogos() async {
    final prefs = await SharedPreferences.getInstance();
    final lastResolved = prefs.getInt(_logoResolvedKey) ?? 0;
    final lastCount = prefs.getInt(_logoChannelCountKey) ?? 0;
    final age = DateTime.now().millisecondsSinceEpoch - lastResolved;

    final allChannels = await _db.getAllChannels();

    // Skip if resolved recently AND no new channels were added
    if (age < _logoCooldown.inMilliseconds && allChannels.length == lastCount) {
      return;
    }

    final needsLogo = allChannels
        .where((c) => c.tvgLogo == null || c.tvgLogo!.isEmpty)
        .map((c) => (id: c.id, name: c.name, tvgLogo: c.tvgLogo))
        .toList();

    if (needsLogo.isEmpty) {
      await prefs.setInt(
        _logoResolvedKey,
        DateTime.now().millisecondsSinceEpoch,
      );
      await prefs.setInt(_logoChannelCountKey, allChannels.length);
      return;
    }

    // Build lookup maps once
    final epgIconMap = await _buildEpgIconMap();
    await LogoResolverService.ensureIndex(); // pre-load GitHub index

    // Partition: favorites first, then the rest
    final favIds = await _db.getAllFavoritedChannelIds();
    final favorites = needsLogo.where((c) => favIds.contains(c.id)).toList();
    final rest = needsLogo.where((c) => !favIds.contains(c.id)).toList();

    debugPrint(
      '[Logo] ${needsLogo.length} missing (${favorites.length} favorites, ${rest.length} other)',
    );

    // Resolve favorites immediately
    if (favorites.isNotEmpty) {
      final resolved = await _resolveLogoBatch(favorites, epgIconMap);
      if (resolved.isNotEmpty) {
        await _db.updateChannelLogos(resolved);
        debugPrint('[Logo] Favorites: resolved ${resolved.length} logos');
      }
    }

    // Resolve rest in small batches with yields between
    for (var i = 0; i < rest.length; i += _logoBatchSize) {
      final batch = rest.sublist(i, (i + _logoBatchSize).clamp(0, rest.length));
      final resolved = await _resolveLogoBatch(batch, epgIconMap);
      if (resolved.isNotEmpty) {
        await _db.updateChannelLogos(resolved);
      }
      // Yield to UI between batches
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    debugPrint('[Logo] Resolution complete');
    await prefs.setInt(_logoResolvedKey, DateTime.now().millisecondsSinceEpoch);
    await prefs.setInt(_logoChannelCountKey, allChannels.length);
  }

  /// Build EPG icon lookup map (display name / channel ID → icon URL).
  Future<Map<String, String>> _buildEpgIconMap() async {
    final map = <String, String>{};
    try {
      final epgChannels = await _db.select(_db.epgChannels).get();
      for (final ec in epgChannels) {
        if (ec.iconUrl != null && ec.iconUrl!.isNotEmpty) {
          map[ec.displayName.toLowerCase()] = ec.iconUrl!;
          map[ec.channelId.toLowerCase()] = ec.iconUrl!;
        }
      }
    } catch (_) {}
    return map;
  }

  /// Resolve logos for a batch of channels using EPG icons + GitHub tv-logos.
  Future<Map<String, String>> _resolveLogoBatch(
    List<({String id, String name, String? tvgLogo})> channels,
    Map<String, String> epgIconMap,
  ) async {
    final resolved = <String, String>{};
    final remaining = <({String id, String name, String? tvgLogo})>[];

    for (final ch in channels) {
      final stripped = ch.name
          .toLowerCase()
          .replaceAll(RegExp(r'^[a-z]{2}[-]?[a-z]?\|\s*'), '')
          .replaceAll(RegExp(r'^[a-z]{2}:\s+'), '')
          .replaceAll(RegExp(r'^\[?[a-z]{2}\]?\s+'), '')
          .replaceAll(RegExp(r'^[a-z]{2}\s+'), '');
      final icon = epgIconMap[ch.name.toLowerCase()] ?? epgIconMap[stripped];
      if (icon != null) {
        resolved[ch.id] = icon;
      } else {
        remaining.add(ch);
      }
    }

    if (remaining.isNotEmpty) {
      final ghResolved = await LogoResolverService.resolveLogosForChannels(
        remaining,
      );
      resolved.addAll(ghResolved);
    }

    return resolved;
  }
}

class ProviderLimitException implements Exception {
  final int limit;
  const ProviderLimitException(this.limit);

  @override
  String toString() =>
      'Provider limit reached ($limit). Upgrade to Pro for unlimited providers.';
}

/// Riverpod provider for the database.
final databaseProvider = Provider<db.AppDatabase>((ref) {
  final database = db.AppDatabase();
  ref.onDispose(() => database.close());
  return database;
});

/// Riverpod provider for the provider manager.
final providerManagerProvider = Provider<ProviderManager>((ref) {
  return ProviderManager(ref.watch(databaseProvider));
});
