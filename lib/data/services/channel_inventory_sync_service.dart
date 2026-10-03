import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/app_diagnostics.dart';
import '../datasources/local/database.dart' as db;
import 'bobtv_api_client.dart';
import 'channel_category_classifier.dart';
import 'channel_category_ai_service.dart';
import 'channel_country_ai_service.dart';
import 'client_fingerprint_service.dart';
import 'public_inventory_policy.dart';
import 'website_channel_catalog_service.dart';
import 'manual_channel_category.dart';

/// Uploads public television metadata in bounded pages. Server verification
/// gates publication; a client success alone never publishes a route.
class ChannelInventorySyncService {
  ChannelInventorySyncService({
    required this.database,
    BobTvApiClient? api,
    this.fingerprintOverride,
  }) : api = api ?? BobTvApiClient();
  final db.AppDatabase database;
  final BobTvApiClient api;
  final String? fingerprintOverride;
  final state = ValueNotifier(const WebsiteCatalogProgress());
  Future<void>? _running;
  bool _disposed = false;
  bool _refreshAfterRunning = false;
  Future<int>? _eventsRunning;

  Future<int> flushEvents() => _eventsRunning ??= _flushEvents().whenComplete(
    () => _eventsRunning = null,
  );

  Future<int> _flushEvents() async {
    if (_disposed) return 0;
    var acknowledged = 0;
    try {
      if (fingerprintOverride == null)
        await ClientFingerprintService.instance.initialize();
      final fingerprint =
          fingerprintOverride ??
          ClientFingerprintService.instance.apiFingerprint;
      if (fingerprint == null) return 0;
      for (var page = 0; page < 20 && !_disposed; page++) {
        final pending = await database.pendingSharedEvents();
        if (pending.isEmpty) break;
        final batch = <Map<String, Object?>>[];
        for (final row in pending) {
          final url = row['url'] as String;
          if (row['kind'] == 'classify' &&
              batch.any((e) => e['url'] == url && e['kind'] == 'upsert'))
            continue;
          if (!BobTvApiClient.isPublicCatalogUrl(url)) {
            await database.acknowledgeSharedEvent(row['id'] as String);
            continue;
          }
          final payload = Map<String, Object?>.from(row['payload'] as Map);
          if (row['kind'] == 'upsert') {
            final group = payload['group'] as String? ?? '其他';
            if (!group.startsWith('中国 / ') && !group.startsWith('国际 / ')) {
              final category = ChannelCategoryClassifier.classify(
                name: payload['name'] as String,
                groupTitle: group,
                streamUrl: url,
              );
              payload['group'] = category == '国际'
                  ? '国际 / ${ChannelCategoryClassifier.internationalCountryFor(name: payload['name'] as String, groupTitle: group)}'
                  : category == '其他'
                  ? '其他'
                  : '中国 / $category';
            }
          }
          batch.add({
            'id': row['id'],
            'url': url,
            'kind': row['kind'],
            if (row['kind'] == 'upsert') ...{
              'metadata': payload,
              'baseRevision': await database.sharedRouteRevision(url),
            } else
              ...payload,
          });
        }
        if (batch.isEmpty) continue;
        if (!_disposed)
          state.value = WebsiteCatalogProgress(
            phase: '正在同步频道变更',
            total: pending.length,
            imported: acknowledged,
          );
        final receipts = await api.uploadChannelEvents(
          fingerprint: fingerprint,
          events: batch,
        );
        var completed = 0;
        final receivedIds = <Object?>{};
        for (final receipt in receipts) {
          final matches = batch.where((e) => e['id'] == receipt['id']).toList();
          if (!receivedIds.add(receipt['id']) ||
              matches.length != 1 ||
              ![
                'applied',
                'conflict',
                'rejected',
                'retry',
              ].contains(receipt['status']) ||
              receipt['revision'] is! int ||
              (receipt['revision'] as int) < 0)
            throw const FormatException('Invalid sync event receipt');
          final event = matches.single;
          if (receipt['status'] == 'retry') continue;
          await database.transaction(() async {
            if (receipt['status'] == 'applied' &&
                (event['kind'] == 'classify' || event['kind'] == 'upsert')) {
              await database.advanceQueuedCategoryRevision(
                event['url'] as String,
                event['baseRevision'] as int,
                receipt['revision'] as int,
              );
            }
            await database.setSharedRouteState(
              event['url'] as String,
              receipt['revision'] as int,
            );
            await database.acknowledgeSharedEvent(event['id'] as String);
          });
          if (receipt['status'] != 'applied')
            AppDiagnostics.instance.log('channel_sync_${receipt['status']}', {
              'eventId': event['id'],
              'kind': event['kind'],
            });
          completed++;
        }
        acknowledged += completed;
        if (completed == 0) break;
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      if (!_disposed)
        state.value = WebsiteCatalogProgress(
          phase: '频道变更已同步',
          imported: acknowledged,
          complete: true,
        );
    } catch (error, stack) {
      if (!_disposed)
        state.value = const WebsiteCatalogProgress(
          phase: '同步待重试，本机修改已保存',
          error: true,
        );
      AppDiagnostics.instance.recordError('channel_events_sync', error, stack);
    }
    return acknowledged;
  }

  Future<void> sync({bool refreshAfterRunning = false}) {
    if (_running != null) {
      _refreshAfterRunning |= refreshAfterRunning;
      return _running!;
    }
    return _running = _drainSyncRequests().whenComplete(() => _running = null);
  }

  Future<void> _drainSyncRequests() async {
    do {
      _refreshAfterRunning = false;
      await _sync();
    } while (_refreshAfterRunning && !_disposed);
  }

  Future<void> _sync() async {
    if (_disposed) return;
    try {
      if (fingerprintOverride == null) {
        await ClientFingerprintService.instance.initialize();
      }
      final fingerprint =
          fingerprintOverride ??
          ClientFingerprintService.instance.apiFingerprint;
      if (fingerprint == null) return;
      final categories = await ChannelCategoryAiService().cachedCategories();
      final manualCategories = await ManualChannelCategory.load();
      final countries = await ChannelCountryAiService().cachedCountries();
      final blocked = await database.getSharedBlockedStreamUrls();
      final eligibleProviders = {
        for (final provider in await database.getAllProviders())
          if (isSharedInventoryProvider(
            id: provider.id,
            type: provider.type,
            url: provider.url,
            username: provider.username,
            password: provider.password,
          ))
            provider.id,
      };
      final prefs = await SharedPreferences.getInstance();
      var uploaded = 0;
      var cursor = '';
      final seen = <String>{};
      while (!_disposed) {
        final page = await database.getChannelInventoryPage(cursor);
        if (page.isEmpty) break;
        final checks = await database.getStreamChecksForChannels(page);
        final byUrl = {for (final check in checks) check.streamUrl: check};
        final batch = <Map<String, Object?>>[];
        for (final channel in page) {
          if (channel.streamType != 'live' ||
              !eligibleProviders.contains(channel.providerId) ||
              !seen.add(channel.streamUrl) ||
              !BobTvApiClient.isPublicCatalogUrl(channel.streamUrl) ||
              ChannelCategoryClassifier.isClearlyNonTelevisionRoute(
                name: channel.name,
                groupTitle: channel.groupTitle,
                streamUrl: channel.streamUrl,
              )) {
            continue;
          }
          final key = CategoryNameInput(
            id: channel.id,
            name: channel.name,
            groupTitle: channel.groupTitle,
            tvgId: channel.tvgId,
          ).key;
          final category =
              categories[key] ??
              ChannelCategoryClassifier.classify(
                name: channel.name,
                groupTitle: channel.groupTitle,
                tvgId: channel.tvgId,
                streamUrl: channel.streamUrl,
              );
          var group = category == '国际'
              ? '国际 / ${countries[CountryNameInput(channel.name, channel.groupTitle).key] ?? ChannelCategoryClassifier.internationalCountryFor(name: channel.name, groupTitle: channel.groupTitle, tvgId: channel.tvgId)}'
              : category == '其他'
              ? '其他'
              : '中国 / $category';
          if (channel.providerId == WebsiteChannelCatalogService.providerId) {
            group = channel.groupTitle ?? group;
          }
          group = manualCategories[channel.streamUrl]?.group ?? group;
          final success = byUrl[channel.streamUrl]?.lastSuccessAt;
          batch.add({
            'name': channel.name,
            'url': channel.streamUrl,
            'group': group,
            'source': channel.providerId,
            'epgId': channel.tvgId,
            'logoUrl':
                channel.tvgLogo != null &&
                    BobTvApiClient.isPublicCatalogUrl(channel.tvgLogo!)
                ? channel.tvgLogo
                : null,
            'playableAt': success == null
                ? null
                : success.millisecondsSinceEpoch ~/ 1000,
            'blocked': blocked.contains(channel.streamUrl),
          });
        }
        if (batch.isNotEmpty) {
          final digest = sha256
              .convert(utf8.encode(jsonEncode(batch)))
              .toString();
          final checkpoint = 'bobtv_inventory_page_v1_${page.first.id}';
          if (prefs.getString(checkpoint) != digest) {
            uploaded += await api.uploadChannelInventory(
              fingerprint: fingerprint,
              routes: batch,
            );
            await prefs.setString(checkpoint, digest);
          }
        }
        cursor = page.last.id;
        if (!_disposed) {
          state.value = WebsiteCatalogProgress(
            phase: '正在上报共享频道',
            imported: uploaded,
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      // Retired routes may have been removed from the channel table already.
      final tombstones = blocked
          .where(
            (url) =>
                !seen.contains(url) && BobTvApiClient.isPublicCatalogUrl(url),
          )
          .toList();
      for (var i = 0; i < tombstones.length && !_disposed; i += 200) {
        uploaded += await api.uploadChannelInventory(
          fingerprint: fingerprint,
          routes: tombstones
              .skip(i)
              .take(200)
              .map(
                (url) => <String, Object?>{
                  'name': '已淘汰线路',
                  'url': url,
                  'group': '其他',
                  'source': 'BobTV 用户淘汰',
                  'blocked': true,
                },
              )
              .toList(),
        );
      }
      await flushEvents();
      if (!_disposed) {
        state.value = WebsiteCatalogProgress(
          phase: '频道上报完成，等待网站验证',
          imported: uploaded,
          complete: true,
        );
      }
    } catch (error, stack) {
      if (!_disposed) {
        state.value = const WebsiteCatalogProgress(
          phase: '频道上报暂未完成，将自动重试',
          error: true,
        );
      }
      AppDiagnostics.instance.recordError(
        'channel_inventory_sync',
        error,
        stack,
      );
    }
  }

  Future<void> reportRetirement(String url) async {
    if (_disposed || !BobTvApiClient.isPublicCatalogUrl(url)) return;
    try {
      if (!(await database.getSharedBlockedStreamUrls()).contains(url)) return;
      if (fingerprintOverride == null) {
        await ClientFingerprintService.instance.initialize();
      }
      final fingerprint =
          fingerprintOverride ??
          ClientFingerprintService.instance.apiFingerprint;
      if (fingerprint == null || _disposed) return;
      await api.uploadChannelInventory(
        fingerprint: fingerprint,
        routes: [
          {
            'name': '已淘汰线路',
            'url': url,
            'group': '其他',
            'source': 'BobTV 用户淘汰',
            'blocked': true,
          },
        ],
      );
      await flushEvents();
    } catch (error, stack) {
      AppDiagnostics.instance.recordError(
        'channel_retirement_upload',
        error,
        stack,
      );
      // The local tombstone remains durable and is retried by the next sync.
    }
  }

  void dispose() {
    _disposed = true;
    api.close();
    state.dispose();
  }
}
