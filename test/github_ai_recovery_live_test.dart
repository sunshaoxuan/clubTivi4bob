import 'dart:convert';
import 'dart:io';

import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/services/github_ai_crawler_service.dart';
import 'package:clubtivi/data/services/source_maintenance_service.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final config = OpenAiRuntimeConfig.fromEnvironment();
  test('live targeted CCTV5+ GitHub search and network probe', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    final maintenance = SourceMaintenanceService(database: database);
    final progress = <Map<String, Object>>[];
    final crawler = GitHubAiCrawlerService(
      database: database,
      maximumRepositoriesPerRun: 2,
      maximumDocumentsPerRepository: 4,
      maximumTreeFiles: 800,
      rethrowErrors: true,
      onTargetedProgress: (stage, counts) {
        progress.add({'stage': stage, ...counts});
        stdout.writeln(jsonEncode({'stage': stage, ...counts}));
      },
    );
    try {
      final imported = await crawler.recoverChannel(
        'CCTV5+',
        verifyRoute: maintenance.probeRoute,
      );
      final channels = await database.getChannelsForProvider(
        GitHubAiCrawlerService.providerId,
      );
      final sources = await database.getDiscoveredStreamSources();
      stdout.writeln(jsonEncode({
        'networkVerified': imported,
        'catalogueRoutes': channels.length,
        'provenanceRows': sources.length,
        'repositories': sources.map((source) =>
            '${source.githubOwner}/${source.githubRepo}').toSet().toList(),
        'progress': progress,
      }));
      expect(channels.length, imported);
      expect(sources.length, imported);
    } finally {
      crawler.dispose();
      maintenance.dispose();
      await database.close();
    }
  },
      skip: config.enabled ? false : 'Local AI endpoint is unavailable',
      timeout: const Timeout(Duration(minutes: 5)));
}
