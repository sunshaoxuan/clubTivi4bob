import 'package:dio/dio.dart';
import 'package:drift/drift.dart';

import '../../core/app_diagnostics.dart';
import '../datasources/local/database.dart' as db;
import '../../features/providers/provider_manager.dart';

class GitHubOriginSpec {
  final String owner;
  final String repo;
  final String ref;
  final String? path;

  const GitHubOriginSpec({
    required this.owner,
    required this.repo,
    required this.ref,
    required this.path,
  });

  static GitHubOriginSpec? fromProvider(db.Provider provider) {
    switch (provider.id) {
      case 'hotel-vbskycn-ipv4':
        return const GitHubOriginSpec(
          owner: 'vbskycn',
          repo: 'iptv',
          ref: 'master',
          path: 'tv/iptv4.m3u',
        );
      case 'hotel-iptv-org-cn':
        return const GitHubOriginSpec(
          owner: 'iptv-org',
          repo: 'iptv',
          ref: 'master',
          path: null,
        );
    }

    final uri = Uri.tryParse(provider.url ?? '');
    if (uri == null || uri.host.toLowerCase() != 'raw.githubusercontent.com') {
      return null;
    }
    final segments = uri.pathSegments;
    if (segments.length < 4) return null;

    final owner = segments[0];
    final repo = segments[1];
    if (segments.length >= 6 &&
        segments[2] == 'refs' &&
        segments[3] == 'heads') {
      return GitHubOriginSpec(
        owner: owner,
        repo: repo,
        ref: segments[4],
        path: segments.sublist(5).join('/'),
      );
    }
    return GitHubOriginSpec(
      owner: owner,
      repo: repo,
      ref: segments[2],
      path: segments.sublist(3).join('/'),
    );
  }
}

class GitHubSourceMonitor {
  static const checkInterval = Duration(hours: 6);

  final db.AppDatabase database;
  final Dio _dio;
  final bool _ownsDio;

  GitHubSourceMonitor({required this.database, Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 12),
              headers: const {
                'Accept': 'application/vnd.github+json',
                'X-GitHub-Api-Version': '2022-11-28',
                'User-Agent': 'HotelTV-source-monitor',
              },
            ),
          ),
      _ownsDio = dio == null;

  Future<void> syncOrigins(List<db.Provider> providers) async {
    final existing = {
      for (final origin in await database.getAllProviderOrigins())
        origin.providerId: origin,
    };
    for (final provider in providers) {
      final spec = GitHubOriginSpec.fromProvider(provider);
      if (spec == null) continue;
      final saved = existing[provider.id];
      await database.upsertProviderOrigin(
        db.ProviderOriginsCompanion.insert(
          providerId: provider.id,
          sourceUrl: provider.url ?? '',
          githubOwner: Value(spec.owner),
          githubRepo: Value(spec.repo),
          githubRef: Value(spec.ref),
          githubPath: Value(spec.path),
          lastVersion: Value(saved?.lastVersion),
          etag: Value(saved?.etag),
          lastCheckedAt: Value(saved?.lastCheckedAt),
          lastChangedAt: Value(saved?.lastChangedAt),
        ),
      );
    }
  }

  Future<void> scanForUpdates(ProviderManager manager) async {
    final now = DateTime.now();
    final checkBefore = now.subtract(checkInterval);
    final providerIds = {
      for (final provider in await database.getAllProviders()) provider.id,
    };
    final origins = await database.getAllProviderOrigins();
    for (final origin in origins) {
      if (!providerIds.contains(origin.providerId) ||
          origin.githubOwner == null ||
          origin.githubRepo == null ||
          origin.githubRef == null ||
          (origin.lastCheckedAt?.isAfter(checkBefore) ?? false)) {
        continue;
      }
      try {
        final snapshot = await _fetchVersion(origin);
        if (snapshot == null) continue;
        final changed =
            origin.lastVersion != null &&
            origin.lastVersion!.isNotEmpty &&
            origin.lastVersion != snapshot.version;
        if (changed) {
          await database.resetRetiredStreamChecks(origin.providerId);
          await manager.refreshProvider(origin.providerId);
        }
        await database.upsertProviderOrigin(
          db.ProviderOriginsCompanion.insert(
            providerId: origin.providerId,
            sourceUrl: snapshot.sourceUrl,
            githubOwner: Value(origin.githubOwner),
            githubRepo: Value(origin.githubRepo),
            githubRef: Value(snapshot.ref),
            githubPath: Value(snapshot.path),
            lastVersion: Value(snapshot.version),
            etag: Value(origin.etag),
            lastCheckedAt: Value(now),
            lastChangedAt: changed ? Value(now) : Value(origin.lastChangedAt),
          ),
        );
        AppDiagnostics.instance.log('github_source_checked', {
          'providerId': origin.providerId,
          'changed': changed,
          'version': snapshot.version,
          'ref': snapshot.ref,
          'path': snapshot.path,
        });
      } on DioException catch (error, stackTrace) {
        final status = error.response?.statusCode;
        AppDiagnostics.instance.recordError(
          'github_source_check_${origin.providerId}',
          error,
          stackTrace,
        );
        if (status == 403 || status == 429) break;
      } catch (error, stackTrace) {
        AppDiagnostics.instance.recordError(
          'github_source_check_${origin.providerId}',
          error,
          stackTrace,
        );
      }
    }
  }

  Future<_GitHubVersionSnapshot?> _fetchVersion(
    db.ProviderOrigin origin,
  ) async {
    final owner = origin.githubOwner!;
    final repo = origin.githubRepo!;
    final ref = origin.githubRef!;
    final path = origin.githubPath;
    if (path != null && path.isNotEmpty) {
      try {
        final response = await _dio.get<Map<String, dynamic>>(
          'https://api.github.com/repos/$owner/$repo/contents/$path',
          queryParameters: {'ref': ref},
        );
        final version = response.data?['sha'] as String?;
        if (version == null || version.isEmpty) return null;
        return _GitHubVersionSnapshot(
          version: version,
          ref: ref,
          path: path,
          sourceUrl: origin.sourceUrl,
        );
      } on DioException catch (error) {
        if (error.response?.statusCode != 404) rethrow;
        return _recoverMovedSource(origin);
      }
    }

    final response = await _dio.get<List<dynamic>>(
      'https://api.github.com/repos/$owner/$repo/commits',
      queryParameters: {'sha': ref, 'per_page': 1},
    );
    final data = response.data;
    if (data == null || data.isEmpty || data.first is! Map) return null;
    final version = (data.first as Map)['sha'] as String?;
    if (version == null || version.isEmpty) return null;
    return _GitHubVersionSnapshot(
      version: version,
      ref: ref,
      path: null,
      sourceUrl: origin.sourceUrl,
    );
  }

  Future<_GitHubVersionSnapshot?> _recoverMovedSource(
    db.ProviderOrigin origin,
  ) async {
    final owner = origin.githubOwner!;
    final repo = origin.githubRepo!;
    final repository = await _dio.get<Map<String, dynamic>>(
      'https://api.github.com/repos/$owner/$repo',
    );
    final defaultRef = repository.data?['default_branch'] as String?;
    if (defaultRef == null || defaultRef.isEmpty) return null;

    var recoveredPath = origin.githubPath!;
    Map<String, dynamic>? content;
    try {
      content = (await _dio.get<Map<String, dynamic>>(
        'https://api.github.com/repos/$owner/$repo/contents/$recoveredPath',
        queryParameters: {'ref': defaultRef},
      )).data;
    } on DioException catch (error) {
      if (error.response?.statusCode != 404) rethrow;
      final tree = await _dio.get<Map<String, dynamic>>(
        'https://api.github.com/repos/$owner/$repo/git/trees/$defaultRef',
        queryParameters: {'recursive': 1},
      );
      final basename = recoveredPath.split('/').last.toLowerCase();
      final items = tree.data?['tree'];
      if (items is! List) return null;
      final matches = items.whereType<Map>().where((item) {
        final candidate = item['path']?.toString();
        return item['type'] == 'blob' &&
            candidate != null &&
            candidate.split('/').last.toLowerCase() == basename;
      }).toList();
      if (matches.isEmpty) return null;
      recoveredPath = matches.first['path'].toString();
      content = (await _dio.get<Map<String, dynamic>>(
        'https://api.github.com/repos/$owner/$repo/contents/$recoveredPath',
        queryParameters: {'ref': defaultRef},
      )).data;
    }

    final version = content?['sha'] as String?;
    if (version == null || version.isEmpty) return null;
    var sourceUrl = origin.sourceUrl;
    final sourceUri = Uri.tryParse(sourceUrl);
    if (sourceUri?.host.toLowerCase() == 'raw.githubusercontent.com') {
      sourceUrl =
          'https://raw.githubusercontent.com/'
          '$owner/$repo/$defaultRef/$recoveredPath';
      await database.updateProviderUrl(origin.providerId, sourceUrl);
    }
    AppDiagnostics.instance.log('github_source_recovered', {
      'providerId': origin.providerId,
      'ref': defaultRef,
      'path': recoveredPath,
    });
    return _GitHubVersionSnapshot(
      version: version,
      ref: defaultRef,
      path: recoveredPath,
      sourceUrl: sourceUrl,
    );
  }

  void dispose() {
    if (_ownsDio) _dio.close(force: true);
  }
}

class _GitHubVersionSnapshot {
  final String version;
  final String ref;
  final String? path;
  final String sourceUrl;

  const _GitHubVersionSnapshot({
    required this.version,
    required this.ref,
    required this.path,
    required this.sourceUrl,
  });
}
