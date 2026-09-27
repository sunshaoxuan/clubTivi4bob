import 'dart:convert';
import 'dart:io';

import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/services/github_ai_crawler_service.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final config = OpenAiRuntimeConfig.fromEnvironment();
  test(
    'live GitHub and OpenAI crawler smoke test',
    () async {
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      await database.upsertProviderOrigin(
        db.ProviderOriginsCompanion.insert(
          providerId: 'smoke-seed',
          sourceUrl:
              'https://raw.githubusercontent.com/BurningC4/Chinese-IPTV/master/TV-IPV4.m3u',
          githubOwner: const Value('BurningC4'),
          githubRepo: const Value('Chinese-IPTV'),
          githubRef: const Value('master'),
        ),
      );
      final service = GitHubAiCrawlerService(
        database: database,
        maximumRepositoriesPerRun: 1,
        maximumDocumentsPerRepository: 2,
        maximumTreeFiles: 400,
        rethrowErrors: true,
      );
      try {
        await service.run();
        final channels = await database.getChannelsForProvider(
          GitHubAiCrawlerService.providerId,
        );
        final provenance = await database.getDiscoveredStreamSources();
        final repositories = await database.getGitHubCrawlRepositories();
        stdout.writeln(
          jsonEncode({
            'repositories': repositories.length,
            'channels': channels.length,
            'provenance': provenance.length,
            'successfulRepositories': repositories
                .where((item) => item.lastSuccessAt != null)
                .length,
            'errors': repositories
                .where((item) => item.lastError?.isNotEmpty == true)
                .length,
            'errorKinds': repositories
                .map((item) => item.lastError)
                .whereType<String>()
                .toList(),
          }),
        );
        expect(repositories, isNotEmpty);
        expect(repositories.any((item) => item.lastSuccessAt != null), isTrue);
        expect(provenance.length, channels.length);
      } finally {
        service.dispose();
        await database.close();
      }
    },
    skip: config.enabled ? false : 'Local OpenAI configuration is unavailable',
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
