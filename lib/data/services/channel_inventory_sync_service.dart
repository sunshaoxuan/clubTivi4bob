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

  Future<void> sync() =>
      _running ??= _sync().whenComplete(() => _running = null);

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
