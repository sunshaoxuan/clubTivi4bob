import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/app_diagnostics.dart';
import '../datasources/local/database.dart' as db;
import 'bobtv_api_client.dart';
import 'device_favorites_identity.dart';
import 'app_credential_store.dart';
import 'device_favorites_privacy.dart';
import 'device_favorites_store.dart';
import 'website_channel_catalog_service.dart';

/// Device-private backup runs independently of public catalog work. Local
/// favorites are immediate; network failures never undo a user's selection.
class DeviceFavoritesSyncService {
  DeviceFavoritesSyncService({
    required db.AppDatabase database,
    BobTvApiClient? api,
    Future<DeviceFavoritesCredential?> Function()? credentialLoader,
    Future<bool> Function()? backupEnabled,
    DateTime Function()? now,
  }) : store = DeviceFavoritesStore(database),
       api = api ?? BobTvApiClient(),
       credentialLoader = credentialLoader ?? DeviceFavoritesIdentity().load,
       backupEnabled = backupEnabled ?? DeviceFavoritesPrivacy.enabled,
       now = now ?? DateTime.now;
  final DeviceFavoritesStore store;
  final BobTvApiClient api;
  final Future<DeviceFavoritesCredential?> Function() credentialLoader;
  final Future<bool> Function() backupEnabled;
  final DateTime Function() now;
  final state = ValueNotifier(const WebsiteCatalogProgress());
  Future<void>? _running;
  bool _disposed = false;
  bool _needFreshRead = false;
  DateTime? _lastPull;
  DateTime? _retryAt;

  Future<void> sync({bool force = false}) {
    if (_disposed || (!force && _retryAt?.isAfter(now()) == true)) {
      return Future.value();
    }
    return _running ??= _sync().whenComplete(() => _running = null);
  }

  Future<void> _sync() async {
    try {
      if (!await backupEnabled()) {
        if (!_disposed) {
          state.value = const WebsiteCatalogProgress(
            phase: '收藏仅保存在本机，在线备份已关闭',
            complete: true,
          );
        }
        return;
      }
      await store.initialize();
      if (_disposed) return;
      final credential = await credentialLoader();
      if (_disposed || !await backupEnabled()) return;
      if (credential == null) {
        throw StateError('Private favorite device identity unavailable');
      }
      await store.bindOwner(credential.localOwner);
      await store.resolvePending();
      var captured = await store.read();
      final dirty =
          !captured.initialized || captured.revision != captured.acknowledged;
      final currentDigest = favoriteSnapshotDigest(captured.snapshot);
      final pull =
          !captured.initialized ||
          _needFreshRead ||
          _lastPull == null ||
          now().difference(_lastPull!) >= const Duration(minutes: 1);
      if (!dirty && !pull) return;
      if (dirty &&
          captured.initialized &&
          currentDigest == captured.digest &&
          !pull) {
        await store.acknowledge(
          credential.localOwner,
          captured,
          captured.remoteRevision,
        );
        return;
      }
      state.value = const WebsiteCatalogProgress(phase: '正在备份本机收藏');
      var revision = captured.remoteRevision;
      var missing = false;
      if (pull) {
        if (!await backupEnabled() || _disposed) return;
        final remote = await api.fetchDeviceFavorites(
          credential: credential,
          ifRevision: captured.initialized && !_needFreshRead ? revision : null,
        );
        if (_disposed || !await backupEnabled()) return;
        _lastPull = now();
        _needFreshRead = false;
        revision = remote?.revision ?? 0;
        missing = remote == null;
        final mayRestore =
            (!captured.initialized &&
                captured.snapshot.isEmpty &&
                captured.revision == 0) ||
            (captured.initialized &&
                !dirty &&
                revision > captured.remoteRevision);
        if (mayRestore && remote?.snapshot != null) {
          final applied = await store.restore(
            remote!.snapshot!,
            owner: credential.localOwner,
            expectedRevision: captured.revision,
            remoteRevision: revision,
          );
          if (applied) {
            state.value = const WebsiteCatalogProgress(
              phase: '已恢复本机收藏，仅此设备可取回',
              complete: true,
            );
            _retryAt = null;
            return;
          }
          // A user clicked while the request was in flight. Preserve that
          // immediate local change and upload it against the fetched revision.
          captured = await store.read();
        }
      }
      if (!captured.initialized &&
          captured.snapshot.isEmpty &&
          missing &&
          captured.revision == 0) {
        await store.acknowledge(credential.localOwner, captured, 0);
      } else if (missing ||
          !captured.initialized ||
          favoriteSnapshotDigest(captured.snapshot) != captured.digest) {
        if (!await backupEnabled() || _disposed) return;
        revision = await api.saveDeviceFavorites(
          credential: credential,
          snapshot: captured.snapshot,
          baseRevision: revision,
        );
        if (_disposed) return;
        await store.acknowledge(credential.localOwner, captured, revision);
      } else {
        await store.acknowledge(credential.localOwner, captured, revision);
      }
      if (!_disposed) {
        final latest = await store.read();
        final waiting = latest.revision != latest.acknowledged;
        state.value = WebsiteCatalogProgress(
          phase: waiting
              ? '本机收藏已保存，等待后台备份'
              : latest.snapshot.isEmpty && revision == 0
              ? '暂无收藏，添加后仅备份到原设备'
              : '本机收藏已备份，不与其他设备共享',
          complete: !waiting,
        );
      }
      _retryAt = null;
    } on CredentialAccessPaused {
      if (!_disposed) {
        state.value = const WebsiteCatalogProgress(
          phase: '收藏备份已暂停，请在设置中重新授权，本机收藏已保留',
          complete: true,
        );
      }
    } catch (error) {
      if (_disposed) return;
      if (error is BobTvApiException && error.statusCode == 409) {
        _needFreshRead = true;
      }
      _retryAt = now().add(
        error is BobTvApiException && error.retryAfter != null
            ? error.retryAfter!
            : const Duration(seconds: 30),
      );
      state.value = const WebsiteCatalogProgress(
        phase: '收藏备份待重试，本机收藏已保留',
        error: true,
      );
      // Do not place credentials or favorite contents in logs or diagnostics.
      AppDiagnostics.instance.log('private_favorites_sync_failed', {
        'type': error.runtimeType.toString(),
        if (error is BobTvApiException) 'status': error.statusCode,
      });
    }
  }

  /// Stop scheduling work and join every operation that can still use the DB.
  Future<void> shutdown() async {
    dispose();
    await Future.wait<Object?>([?_running]);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    api.close();
    state.dispose();
  }
}
