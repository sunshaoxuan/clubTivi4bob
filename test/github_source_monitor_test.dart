import 'package:flutter_test/flutter_test.dart';
import 'package:clubtivi/data/datasources/local/database.dart';
import 'package:clubtivi/data/services/github_source_monitor.dart';
import 'package:clubtivi/features/providers/provider_manager.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';

void main() {
  test('extracts repository metadata from a raw GitHub URL', () {
    final provider = Provider(
      id: 'test',
      name: 'Test',
      type: 'm3u',
      url:
          'https://raw.githubusercontent.com/Guovin/iptv-api/gd/output/ipv4/result.m3u',
      username: null,
      password: null,
      sortOrder: 0,
      enabled: true,
      lastRefresh: null,
      createdAt: DateTime.utc(2026),
    );
    final origin = GitHubOriginSpec.fromProvider(provider)!;
    expect(origin.owner, 'Guovin');
    expect(origin.repo, 'iptv-api');
    expect(origin.ref, 'gd');
    expect(origin.path, 'output/ipv4/result.m3u');
  });

  test('extracts refs heads URLs without including refs in the path', () {
    final provider = Provider(
      id: 'test',
      name: 'Test',
      type: 'm3u',
      url:
          'https://raw.githubusercontent.com/suxuang/myIPTV/refs/heads/main/ipv4.m3u',
      username: null,
      password: null,
      sortOrder: 0,
      enabled: true,
      lastRefresh: null,
      createdAt: DateTime.utc(2026),
    );
    final origin = GitHubOriginSpec.fromProvider(provider)!;
    expect(origin.ref, 'main');
    expect(origin.path, 'ipv4.m3u');
  });

  test('maps the external vbskycn feed to its GitHub origin', () {
    final provider = Provider(
      id: 'hotel-vbskycn-ipv4',
      name: 'vbskycn',
      type: 'm3u',
      url: 'https://live.zbds.top/tv/iptv4.m3u',
      username: null,
      password: null,
      sortOrder: 0,
      enabled: true,
      lastRefresh: null,
      createdAt: DateTime.utc(2026),
    );
    final origin = GitHubOriginSpec.fromProvider(provider)!;
    expect(origin.owner, 'vbskycn');
    expect(origin.repo, 'iptv');
    expect(origin.path, 'tv/iptv4.m3u');
  });

  test('recovers a playlist when the repository default branch moves', () async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final ref = options.queryParameters['ref'];
          if (options.path.endsWith('/contents/cn_all_status.m3u8') &&
              ref == 'master') {
            handler.reject(
              DioException(
                requestOptions: options,
                response: Response(requestOptions: options, statusCode: 404),
                type: DioExceptionType.badResponse,
              ),
            );
            return;
          }
          if (options.path.endsWith('/repos/best-fan/iptv-sources')) {
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: <String, dynamic>{'default_branch': 'main'},
              ),
            );
            return;
          }
          if (options.path.endsWith('/contents/cn_all_status.m3u8') &&
              ref == 'main') {
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: <String, dynamic>{'sha': 'new-version'},
              ),
            );
            return;
          }
          handler.reject(
            DioException(
              requestOptions: options,
              error: 'Unexpected request: ${options.uri}',
            ),
          );
        },
      ),
    );
    await database.upsertProvider(
      ProvidersCompanion.insert(
        id: 'hotel-best-fan-status',
        name: 'best-fan',
        type: 'm3u',
        url: const Value(
          'https://raw.githubusercontent.com/best-fan/iptv-sources/master/cn_all_status.m3u8',
        ),
      ),
    );
    await database.upsertProviderOrigin(
      ProviderOriginsCompanion.insert(
        providerId: 'hotel-best-fan-status',
        sourceUrl:
            'https://raw.githubusercontent.com/best-fan/iptv-sources/master/cn_all_status.m3u8',
        githubOwner: const Value('best-fan'),
        githubRepo: const Value('iptv-sources'),
        githubRef: const Value('master'),
        githubPath: const Value('cn_all_status.m3u8'),
      ),
    );

    final monitor = GitHubSourceMonitor(database: database, dio: dio);
    await monitor.scanForUpdates(ProviderManager(database));

    final provider = (await database.getAllProviders()).single;
    final origin = (await database.getAllProviderOrigins()).single;
    expect(provider.url, contains('/main/cn_all_status.m3u8'));
    expect(origin.githubRef, 'main');
    expect(origin.githubPath, 'cn_all_status.m3u8');
    expect(origin.lastVersion, 'new-version');

    dio.close(force: true);
    await database.close();
  });
}
