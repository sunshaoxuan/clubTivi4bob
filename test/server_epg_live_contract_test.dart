import 'dart:convert';
import 'dart:io';

import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/models/server_epg_snapshot.dart';
import 'package:clubtivi/data/models/catalog_epg_identity.dart';
import 'package:clubtivi/data/services/bobtv_api_client.dart';
import 'package:clubtivi/data/services/server_epg_binding.dart';
import 'package:clubtivi/data/services/server_epg_sync_service.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

// Read-only capture from both production nodes. No synthetic schedules and no
// production database/app access. All imports use a temporary in-memory DB.
class CapturedApi extends BobTvApiClient {
  CapturedApi(this.capture);
  Map<String, dynamic> capture;
  int downloads = 0;
  bool offline = false;
  @override
  Future<ServerEpgManifest?> fetchEpgManifest() async {
    if (offline) throw const SocketException('offline regression check');
    return ServerEpgManifest.parse(capture['manifest']);
  }

  @override
  Future<List<int>> downloadEpgSnapshot(ServerEpgManifest manifest) async {
    downloads++;
    return base64Decode(capture['snapshotBase64'] as String);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final path = Platform.environment['BOBTV_LIVE_EPG_CAPTURE'];
  test(
    'actual licensed public snapshot imports, is idempotent and survives offline',
    () async {
      final capture =
          jsonDecode(await File(path!).readAsString()) as Map<String, dynamic>;
      final manifest = ServerEpgManifest.parse(capture['manifest'])!;
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      final api = CapturedApi(capture);
      // Replay at the independently verified capture time. Programme dates and
      // publication timestamps remain exactly as observed on both public nodes.
      var clock = DateTime.fromMillisecondsSinceEpoch(
        (capture['verifiedAtUtc'] as int) * 1000,
        isUtc: true,
      );
      final service = ServerEpgSyncService(
        database: database,
        api: api,
        now: () => clock,
        decode: decodeServerEpg,
      );
      try {
        final targets = capture['catalogTargets'] as List?;
        if (targets != null) {
          await database.upsertProvider(
            db.ProvidersCompanion.insert(
              id: publicCatalogProviderId,
              name: 'BobTV public catalogue',
              type: 'm3u',
            ),
          );
          final identities = <Map<String, Object?>>[];
          for (final target in targets) {
            final channel = target['channel'] as Map<String, dynamic>;
            for (final route in channel['routes'] as List) {
              await database.upsertChannels([
                db.ChannelsCompanion.insert(
                  id: '$publicCatalogProviderId:${route['id']}',
                  providerId: publicCatalogProviderId,
                  name: channel['name'],
                  streamUrl: route['url'],
                  tvgId: Value(channel['epgId']),
                  groupTitle: Value(target['group'] as String),
                ),
              ]);
              identities.add({
                'routeId': route['id'],
                'catalogChannelId': channel['id'],
                'catalogIdentityHash': catalogEpgIdentityHash(channel),
                'name': channel['name'],
                'epgId': channel['epgId'],
                'group': target['group'],
              });
            }
          }
          await ServerEpgBinding(database).replaceCatalogIdentities(
            (capture['catalogManifest'] as Map)['version'] as String,
            identities,
          );
        }
        expect(await service.check(), isTrue);
        expect(service.state.value.version, manifest.version);
        final rows = await database.select(database.epgProgrammes).get();
        expect(rows.length, manifest.programmeCount);
        expect(
          rows.map((row) => row.epgChannelId).toSet(),
          hasLength(manifest.channelCount),
        );
        if (targets != null) {
          final mappings = await database.getAllMappings();
          expect(mappings.length, manifest.channelCount);
          for (final mapping in mappings) {
            expect(mapping.epgSourceId, serverEpgSourceId);
            final upcoming = await database.getUpcomingProgrammes(
              epgChannelId: mapping.epgChannelId,
              at: clock,
              limit: 3,
            );
            expect(upcoming.length, 3);
            final current = rows.where(
              (row) =>
                  row.epgChannelId == mapping.epgChannelId &&
                  !row.start.isAfter(clock) &&
                  row.stop.isAfter(clock),
            );
            expect(current.length, lessThanOrEqualTo(1));
            expect(upcoming.first.start.isAfter(clock), current.isEmpty);
            expect(upcoming.first.stop.isAfter(clock), isTrue);
            expect(
              upcoming.skip(1).every((row) => row.start.isAfter(clock)),
              isTrue,
            );
          }
        }
        expect(
          service.state.value.attributions.single.dataLicense,
          'Open Government Data License 1.0',
        );
        expect(
          service.state.value.attributions.single.shareAlikeRequired,
          isFalse,
        );
        expect(await service.check(forceVersionCheck: true), isFalse);
        expect(api.downloads, 1);
        api.offline = true;
        expect(await service.check(forceVersionCheck: true), isFalse);
        expect(
          (await database.select(database.epgProgrammes).get()).length,
          rows.length,
        );
        expect(service.state.value.version, manifest.version);
        final clockPath =
            Platform.environment['BOBTV_LIVE_EPG_AFTER_CLOCK_CAPTURE'];
        if (clockPath != null) {
          expect(Platform.environment['BOBTV_LIVE_EPG_SECOND_CAPTURE'], isNull);
          final after =
              jsonDecode(await File(clockPath).readAsString())
                  as Map<String, dynamic>;
          final afterManifest = ServerEpgManifest.parse(after['manifest'])!;
          final changedVersion = afterManifest.version != manifest.version;
          if (!changedVersion) {
            expect(afterManifest.sha256, manifest.sha256);
            expect(after['snapshotBase64'], capture['snapshotBase64']);
          }
          final currentBefore = rows
              .where(
                (row) => !row.start.isAfter(clock) && row.stop.isAfter(clock),
              )
              .map((row) => row.epgChannelId)
              .toSet();
          expect(currentBefore, hasLength(1));
          final afterClock = DateTime.fromMillisecondsSinceEpoch(
            (after['verifiedAtUtc'] as int) * 1000,
            isUtc: true,
          );
          expect(afterClock.isAfter(clock), isTrue);
          clock = afterClock;
          // Existing real schedules become current even while disconnected.
          // The publisher may normally prune history between captures; do not
          // assume that the active version remains unchanged across the hour.
          expect(api.offline, isTrue);
          expect(await service.check(forceVersionCheck: true), isFalse);
          expect(api.downloads, 1);
          expect(service.state.value.version, manifest.version);
          expect(
            (await database.select(database.epgProgrammes).get()).length,
            rows.length,
          );
          final currentAfter = rows
              .where(
                (row) => !row.start.isAfter(clock) && row.stop.isAfter(clock),
              )
              .map((row) => row.epgChannelId)
              .toSet();
          expect(currentAfter, hasLength(2));
          for (final mapping in await database.getAllMappings()) {
            final upcoming = await database.getUpcomingProgrammes(
              epgChannelId: mapping.epgChannelId,
              at: clock,
              limit: 3,
            );
            expect(upcoming, hasLength(3));
            expect(upcoming.first.start.isAfter(clock), isFalse);
            expect(upcoming.first.stop.isAfter(clock), isTrue);
          }
          api.offline = false;
          api.capture = after;
          service.onNetworkRestored();
          expect(await service.check(), changedVersion);
          expect(service.state.value.version, afterManifest.version);
          expect(api.downloads, changedVersion ? 2 : 1);
          expect(
            (await database.select(database.epgProgrammes).get()).length,
            afterManifest.programmeCount,
          );
          expect(await service.check(forceVersionCheck: true), isFalse);
          expect(api.downloads, changedVersion ? 2 : 1);
        }
        final nextPath = Platform.environment['BOBTV_LIVE_EPG_SECOND_CAPTURE'];
        if (nextPath != null) {
          final next =
              jsonDecode(await File(nextPath).readAsString())
                  as Map<String, dynamic>;
          final nextManifest = ServerEpgManifest.parse(next['manifest'])!;
          expect(nextManifest.version, isNot(manifest.version));
          expect(
            nextManifest.generatedAt.isAfter(manifest.generatedAt),
            isTrue,
          );
          clock = DateTime.fromMillisecondsSinceEpoch(
            (next['verifiedAtUtc'] as int) * 1000,
            isUtc: true,
          );
          api.offline = false;
          api.capture = next;
          service.onNetworkRestored();
          expect(await service.check(), isTrue);
          expect(service.state.value.version, nextManifest.version);
          expect(
            (await database.select(database.epgProgrammes).get()).length,
            nextManifest.programmeCount,
          );
          expect(api.downloads, 2);
          expect(await service.check(forceVersionCheck: true), isFalse);
          expect(api.downloads, 2);
          expect(
            (await database.getAllMappings()).length,
            nextManifest.channelCount,
          );
          if (Platform.environment['BOBTV_LIVE_EXPECT_CURRENT_GAP'] == '1') {
            final imported = await database
                .select(database.epgProgrammes)
                .get();
            final currentIds = imported
                .where(
                  (row) => !row.start.isAfter(clock) && row.stop.isAfter(clock),
                )
                .map((row) => row.epgChannelId)
                .toSet();
            final futureIds = imported
                .where((row) => row.start.isAfter(clock))
                .map((row) => row.epgChannelId)
                .toSet();
            expect(currentIds, hasLength(1));
            expect(futureIds, hasLength(2));
          }
          for (final mapping in await database.getAllMappings()) {
            expect(
              await database.getUpcomingProgrammes(
                epgChannelId: mapping.epgChannelId,
                at: clock,
                limit: 3,
              ),
              hasLength(3),
            );
          }
        }
      } finally {
        service.dispose();
        api.close();
        await database.close();
      }
    },
    skip: path == null
        ? 'Requires a freshly verified real production capture'
        : false,
  );
}
