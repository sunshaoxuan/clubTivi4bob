import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;

import '../datasources/local/database.dart' as db;
import 'github_ai_crawler_service.dart';

/// Small, keyless fallback for a current public GitHub playlist. Every route
/// must pass a media probe and an actual muted video decode before insertion.
class GitHubCctv5PlusRecovery {
  GitHubCctv5PlusRecovery(this.database);

  final db.AppDatabase database;
  static final _rawUri = Uri.parse(
      'https://raw.githubusercontent.com/CCSH/IPTV/main/live_lite.txt');
  static const _documentUrl =
      'https://github.com/CCSH/IPTV/blob/main/live_lite.txt';

  static List<String> extractCandidates(String document) {
    final result = <String>[];
    final seen = <String>{};
    final namePattern = RegExp(r'^CCTV[- ]?5\+\s*$', caseSensitive: false);
    for (final rawLine in const LineSplitter().convert(document)) {
      final comma = rawLine.indexOf(',');
      if (comma < 0 || !namePattern.hasMatch(
          rawLine.substring(0, comma).trim())) continue;
      final url = rawLine.substring(comma + 1).trim();
      if (_isPublicHttpUrl(url) && seen.add(url)) result.add(url);
    }
    return result;
  }

  static bool _isPublicHttpUrl(String url) {
    if (url.isEmpty || url.length > 2048 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(url)) return false;
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasAuthority ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty || uri.userInfo.isNotEmpty || uri.hasFragment) {
      return false;
    }
    if (uri.host.endsWith('.local') ||
        uri.host.endsWith('.internal') ||
        uri.host.endsWith('.localhost') ||
        uri.host == 'localhost') return false;
    final address = InternetAddress.tryParse(uri.host);
    if (address == null) return uri.host.contains('.');
    if (address.type != InternetAddressType.IPv4) return false;
    final octets = address.rawAddress;
    final a = octets[0];
    final b = octets[1];
    return a != 0 && a != 10 && a != 127 && a < 224 &&
        !(a == 100 && b >= 64 && b <= 127) &&
        !(a == 169 && b == 254) &&
        !(a == 172 && b >= 16 && b <= 31) &&
        !(a == 192 && b == 168);
  }

  Future<int> recover({
    required Future<bool> Function(String url) probeRoute,
    required Future<bool> Function(String url) verifyVideo,
    void Function(int checked, int total)? onProgress,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await client.getUrl(_rawUri)
          .timeout(const Duration(seconds: 8));
      request.followRedirects = false;
      final response = await request.close()
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return 0;
      final body = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 10))) {
        if (body.length + chunk.length > 1024 * 1024) return 0;
        body.addAll(chunk);
      }
      final candidates = extractCandidates(
          utf8.decode(body, allowMalformed: true));
      candidates.sort((left, right) {
        const recentlyResponsiveHost = '223.112.114.228';
        final leftPreferred = Uri.parse(left).host == recentlyResponsiveHost;
        final rightPreferred = Uri.parse(right).host == recentlyResponsiveHost;
        if (leftPreferred == rightPreferred) return 0;
        return leftPreferred ? -1 : 1;
      });
      final deadline = DateTime.now().add(const Duration(minutes: 2));
      var imported = 0;
      var checked = 0;
      final total = candidates.length;
      for (final url in candidates) {
        if (imported >= 3 || DateTime.now().isAfter(deadline)) break;
        checked++;
        onProgress?.call(checked, total);
        if (await database.isStreamUrlBlocked(url)) continue;
        final id = discoveredChannelId(
          owner: 'CCSH', repo: 'IPTV', path: 'live_lite.txt',
          name: 'CCTV5+', url: url,
        );
        if ((await database.getChannelsByIds({id})).isNotEmpty) continue;
        bool usable;
        try {
          usable = await probeRoute(url) && await verifyVideo(url);
        } catch (_) {
          usable = false;
        }
        if (!usable) continue;
        final providers = await database.getAllProviders();
        if (!providers.any((item) =>
            item.id == GitHubAiCrawlerService.providerId)) {
          await database.upsertProvider(db.ProvidersCompanion.insert(
            id: GitHubAiCrawlerService.providerId,
            name: 'GitHub 智慧来源', type: 'crawler',
          ));
        }
        await database.upsertChannels([db.ChannelsCompanion.insert(
          id: id,
          providerId: GitHubAiCrawlerService.providerId,
          name: 'CCTV5+',
          tvgId: const Value('CCTV5Plus.cn'),
          groupTitle: const Value('央视'),
          streamUrl: url,
        )]);
        if ((await database.getChannelsByIds({id})).isEmpty) continue;
        final now = DateTime.now();
        await database.upsertDiscoveredStreamSources([
          db.DiscoveredStreamSourcesCompanion.insert(
            channelId: id,
            streamUrl: url,
            githubOwner: 'CCSH',
            githubRepo: 'IPTV',
            githubRef: 'main',
            githubPath: 'live_lite.txt',
            sourceDocumentUrl: _documentUrl,
            confidence: const Value(0.65),
            firstSeenAt: now,
            lastSeenAt: now,
          ),
        ]);
        await database.upsertStreamChecks([
          db.StreamChecksCompanion.insert(
            streamUrl: url,
            providerId: GitHubAiCrawlerService.providerId,
            channelId: id,
            consecutiveFailures: const Value(0),
            lastCheckedAt: Value(now),
            lastSuccessAt: Value(now),
            retired: const Value(false),
          ),
        ]);
        imported++;
      }
      return imported;
    } finally {
      client.close(force: true);
    }
  }
}
