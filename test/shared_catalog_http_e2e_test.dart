import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/services/bobtv_api_client.dart';
import 'package:clubtivi/data/services/channel_inventory_sync_service.dart';
import 'package:clubtivi/data/services/manual_channel_category.dart';
import 'package:clubtivi/data/services/website_channel_catalog_service.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final python = Platform.environment['BOBTV_SYNC_E2E_PYTHON'];
  test(
    'real API: independent clients exchange metadata, weights and deletions',
    () async {
      final overrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = overrides);
      SharedPreferences.setMockInitialValues({});
      final temporary = await Directory.systemTemp.createTemp(
        'bobtv-http-sync-',
      );
      final site = '${Directory.current.path}/website';
      final env = {'BOBTV_DATA_DIR': temporary.path};
      Future<void> runPython(String code) async {
        final result = await Process.run(
          python!,
          ['-c', code],
          workingDirectory: site,
          environment: env,
        );
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
      }

      const url = 'https://media.example.org/news.m3u8';
      await runPython(
        "from catalog_inventory import ingest; from process_channel_inventory import process; ingest([{'name':'NRBTV','url':'$url','group':'国际 / 美国 / 新闻','source':'test','blocked':False}],'a'*64); process(verifier=lambda _:True)",
      );
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();
      final server = await Process.start(
        python!,
        ['-m', 'uvicorn', 'app:app', '--host', '127.0.0.1', '--port', '$port'],
        workingDirectory: site,
        environment: env,
      );
      final messages = StringBuffer();
      server.stdout.transform(utf8.decoder).listen(messages.write);
      server.stderr.transform(utf8.decoder).listen(messages.write);
      addTearDown(() async {
        server.kill();
        await server.exitCode;
        await temporary.delete(recursive: true);
      });
      final uri = Uri.parse('http://127.0.0.1:$port');
      final probe = BobTvApiClient(baseUri: uri);
      addTearDown(probe.close);
      for (var attempt = 0; attempt < 50; attempt++) {
        try {
          if (await probe.fetchChannelCatalogManifest() != null) break;
        } catch (_) {}
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      final first = db.AppDatabase.forTesting(NativeDatabase.memory());
      final second = db.AppDatabase.forTesting(NativeDatabase.memory());
      final firstCatalog = WebsiteChannelCatalogService(
        database: first,
        api: BobTvApiClient(baseUri: uri),
      );
      final secondCatalog = WebsiteChannelCatalogService(
        database: second,
        api: BobTvApiClient(baseUri: uri),
      );
      final uploader = ChannelInventorySyncService(
        database: first,
        api: BobTvApiClient(baseUri: uri),
        fingerprintOverride: 'b' * 64,
      );
      addTearDown(() async {
        firstCatalog.dispose();
        secondCatalog.dispose();
        uploader.dispose();
        await first.close();
        await second.close();
      });
      expect(
        await firstCatalog.sync(),
        1,
        reason: '${firstCatalog.lastError}\n$messages',
      );
      expect(await secondCatalog.sync(), 1);
      expect(await first.pendingSharedEvents(), isEmpty);
      await first.setManualChannelCategory([
        url,
      ], ChannelCategoryDestination(['美国', '宗教']));
      await first.queueSharedEvent(url, 'health', {'success': 2, 'failure': 0});
      await first.queueSharedEvent(url, 'health', {'success': 0, 'failure': 1});
      expect(await uploader.flushEvents(), 3);
      for (var attempt = 0; attempt < 30; attempt++) {
        await secondCatalog.sync();
        if ((await second.getAllChannels()).single.groupTitle == '国际 / 美国 / 宗教')
          break;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect((await second.getAllChannels()).single.groupTitle, '国际 / 美国 / 宗教');
      expect(await second.sharedRouteRevision(url), 1);
      expect(await second.pendingSharedEvents(), isEmpty);
      await probe.uploadChannelInventory(
        fingerprint: 'c' * 64,
        routes: [
          {
            'url': url,
            'name': 'NRBTV',
            'group': '中国 / 北京',
            'source': 'old-client',
            'blocked': false,
          },
        ],
      );
      await runPython(
        'from process_channel_inventory import process; process(limit=0)',
      );
      await secondCatalog.sync();
      expect((await second.getAllChannels()).single.groupTitle, '国际 / 美国 / 宗教');
      const added = 'https://media.example.org/second.m3u8';
      await first.upsertChannels([
        db.ChannelsCompanion.insert(
          id: 'added',
          providerId: WebsiteChannelCatalogService.providerId,
          name: 'New TV',
          streamUrl: added,
        ),
      ]);
      expect(await uploader.flushEvents(), 1);
      await runPython(
        'from process_channel_inventory import process; process(verifier=lambda _:True)',
      );
      await secondCatalog.sync();
      expect(
        (await second.getAllChannels()).map((c) => c.streamUrl),
        contains(added),
      );
      final fresh = db.AppDatabase.forTesting(NativeDatabase.memory());
      Map<String, double>? scores;
      final freshCatalog = WebsiteChannelCatalogService(
        database: fresh,
        api: BobTvApiClient(baseUri: uri),
        onSharedScores: (values) async {
          scores = values;
        },
      );
      addTearDown(() async {
        freshCatalog.dispose();
        await fresh.close();
      });
      await freshCatalog.sync();
      expect(scores![url], lessThan(.8));
      await first.deleteChannelsByIds(
        (await first.getAllChannels()).map((c) => c.id),
      );
      expect(await uploader.flushEvents(), 2);
      for (var attempt = 0; attempt < 30; attempt++) {
        await secondCatalog.sync();
        if ((await second.getAllChannels()).isEmpty) break;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(await second.getAllChannels(), isEmpty);
      await freshCatalog.sync();
      expect(await fresh.getAllChannels(), isEmpty);
      expect(await second.pendingSharedEvents(), isEmpty);
    },
    skip: python == null
        ? 'Set BOBTV_SYNC_E2E_PYTHON to a Python runtime with website dependencies'
        : false,
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
