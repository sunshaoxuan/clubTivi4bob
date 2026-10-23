import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart' show mapEquals;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/app_diagnostics.dart';
import '../../core/diagnostic_log_store.dart';
import '../../core/resource_node_router.dart';
import '../../core/server_egress.dart';
import 'bobtv_api_client.dart';

/// The same consent, bounded outbox and acknowledgments on all platforms.
class DiagnosticSyncService with WidgetsBindingObserver {
  DiagnosticSyncService({
    this.logStore,
    BobTvApiClient Function()? apiFactory,
    DateTime Function()? now,
    this.observeLifecycle = true,
    this.countryResolver,
  }) : apiFactory =
           apiFactory ?? (() => BobTvApiClient(recordDiagnostics: false)),
       now = now ?? DateTime.now;
  static const consentKey = 'bobtv_diagnostics_consent_version';
  static const enabledKey = 'bobtv_diagnostics_enabled_v2';
  static const checkpointKey = 'bobtv_diagnostics_checkpoint_v2';
  static const identityKey = 'bobtv_diagnostics_installation_v2';
  static const retryKey = 'bobtv_diagnostics_next_retry_v2';
  final DiagnosticLogStore? logStore;
  final BobTvApiClient Function() apiFactory;
  final DateTime Function() now;
  final bool observeLifecycle;
  final Future<String?> Function(BobTvApiClient)? countryResolver;
  final status = ValueNotifier<String>('诊断同步默认关闭');
  bool enabled = false;
  bool _disposed = false;
  int _generation = 0;
  int _failures = 0;
  DateTime? _nextRetry;
  DateTime? _lastRun;
  Timer? _timer;
  StreamSubscription<List<ConnectivityResult>>? _network;
  BobTvApiClient? _api;
  Future<void>? _running;
  Future<void>? _starting;

  DiagnosticLogStore? get store =>
      logStore ?? AppDiagnostics.instance.safeStore;

  Future<void> start() => _starting ??= _start();
  Future<void> _start() async {
    final prefs = await SharedPreferences.getInstance();
    if (_disposed) return;
    enabled =
        prefs.getInt(consentKey) == 2 && prefs.getBool(enabledKey) == true;
    _nextRetry = DateTime.tryParse(prefs.getString(retryKey) ?? '');
    status.value = enabled ? '等待同步最近 30 天的脱敏诊断' : '诊断同步默认关闭，需首次同意';
    _timer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => unawaited(sync()),
    );
    if (observeLifecycle) {
      WidgetsBinding.instance.addObserver(this);
      _network = Connectivity().onConnectivityChanged.listen(
        (values) {
          if (values.any((value) => value != ConnectivityResult.none)) {
            unawaited(sync());
          }
        },
        onError: (_) {
          /* Timer and lifecycle checks remain available. */
        },
      );
    }
    if (enabled) unawaited(sync());
  }

  /// Caller must display and obtain the v2 first-use consent before enabling.
  Future<void> setEnabled(bool value) async {
    await start();
    if (_disposed) return;
    enabled = value;
    _generation++;
    if (!value) {
      _api?.close();
      _api = null;
      status.value = '诊断同步已关闭';
    }
    final prefs = await SharedPreferences.getInstance();
    if (value) await prefs.setInt(consentKey, 2);
    await prefs.setBool(enabledKey, value);
    if (!value) {
      final pending = _pendingFile;
      if (pending != null && await pending.exists()) await pending.delete();
      return;
    }
    _nextRetry = null;
    await prefs.remove(retryKey);
    unawaited(sync());
  }

  File? get _pendingFile => store == null
      ? null
      : File(p.join(store!.directory.path, 'pending-upload.json'));
  bool _allowed(int generation) =>
      enabled && !_disposed && generation == _generation;

  Future<void> _savePending(File file, Map<String, dynamic> value) async {
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(value), flush: true);
    await temporary.rename(file.path);
  }

  Future<Map<String, dynamic>?> _loadPending(File file) async {
    if (!await file.exists()) return null;
    try {
      if (await file.length() > 512 * 1024) {
        throw const FormatException('Pending diagnostic limit');
      }
      final value = jsonDecode(await file.readAsString());
      if (value is! Map<String, dynamic> ||
          value['body'] is! String ||
          value['checkpoints'] is! Map ||
          !{'cndrp', 'origin'}.contains(value['node'])) {
        throw const FormatException('Invalid pending diagnostic envelope');
      }
      final body = jsonDecode(value['body'] as String);
      if (body is! Map ||
          body['entries'] is! List ||
          body['installationId'] is! String ||
          !RegExp(
            r'^[a-f0-9]{32}$',
          ).hasMatch(body['installationId'] as String)) {
        throw const FormatException('Invalid pending diagnostic body');
      }
      return value;
    } on FormatException {
      // Only the task-owned pending copy is discarded. Unacknowledged source
      // files and checkpoints remain intact and rebuild the same safe entries.
      await file.delete();
      return null;
    }
  }

  Future<void> sync() {
    if (_disposed ||
        !enabled ||
        store == null ||
        (_nextRetry?.isAfter(now()) ?? false)) {
      return Future.value();
    }
    return _running ??= _sync().whenComplete(() => _running = null);
  }

  Future<void> _sync() async {
    final generation = _generation;
    final prefs = await SharedPreferences.getInstance();
    if (!_allowed(generation)) return;
    _lastRun = now();
    final api = apiFactory();
    _api = api;
    try {
      var installation = prefs.getString(identityKey);
      if (installation == null ||
          !RegExp(r'^[a-f0-9]{32}$').hasMatch(installation)) {
        final random = Random.secure();
        installation = List.generate(
          16,
          (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join();
        await prefs.setString(identityKey, installation);
      }
      var node = ResourceNodeRouter.primary;
      var domesticSafe = true;
      try {
        final country =
            await (countryResolver?.call(api) ??
                api.fetchNetworkProfile().then(
                  (value) => value['countryCode'] as String?,
                ));
        if (!_allowed(generation)) return;
        domesticSafe = country == null || country == 'ZZ' || country == 'CN';
        node = country == 'CN'
            ? ResourceNodeRouter.relay
            : ServerEgress.nodes.selected;
        if (domesticSafe) node = ResourceNodeRouter.relay;
      } catch (_) {
        if (!_allowed(generation)) return;
        // An unknown geography uses the domestic-safe relay path. No log body
        // falls back to a cross-border direct upload when that relay is down.
        node = ResourceNodeRouter.relay;
      }
      for (var batch = 0; batch < 4 && _allowed(generation); batch++) {
        Map<String, dynamic>? pending;
        final file = _pendingFile!;
        pending = await _loadPending(file);
        if (!_allowed(generation)) return;
        if (pending == null) {
          final saved =
              jsonDecode(prefs.getString(checkpointKey) ?? '{}') as Map;
          final checkpoint = <String, int>{
            for (final item in saved.entries)
              if (item.key is String && item.value is int)
                item.key as String: item.value as int,
          };
          final chunk = await store!.readChunk(checkpoint);
          if (!_allowed(generation)) return;
          if (chunk.entries.isEmpty) {
            await prefs.setString(checkpointKey, jsonEncode(chunk.checkpoints));
            status.value = store!.droppedFiles > 0
                ? '已同步可用诊断；本机容量保护曾清理旧文件'
                : '最近 30 天可用脱敏诊断已同步';
            _failures = 0;
            await _defer(prefs, const Duration(minutes: 15));
            return;
          }
          final body = jsonEncode({
            'schemaVersion': 2,
            'consentVersion': 2,
            'installationId': installation,
            'entries': chunk.entries,
          });
          pending = {
            'body': body,
            'checkpoints': chunk.checkpoints,
            'node': node == ResourceNodeRouter.relay ? 'cndrp' : 'origin',
          };
          await _savePending(file, pending);
        }
        if (!_allowed(generation)) return;
        final body = utf8.encode(pending['body'] as String);
        final parsed = jsonDecode(pending['body'] as String) as Map;
        final entries = parsed['entries'] as List;
        if (parsed.keys.toSet().difference({
              'schemaVersion',
              'consentVersion',
              'installationId',
              'entries',
            }).isNotEmpty ||
            parsed['schemaVersion'] != 2 ||
            parsed['consentVersion'] != 2 ||
            entries.any(
              (entry) =>
                  entry is! Map ||
                  !mapEquals(entry, DiagnosticProjection.project(entry, now())),
            )) {
          // Expired pending entries must never be sent after a long offline gap.
          await file.delete();
          continue;
        }
        if (domesticSafe) pending['node'] = 'cndrp';
        final pinned = pending['node'] == 'cndrp'
            ? ResourceNodeRouter.relay
            : ResourceNodeRouter.primary;
        status.value = pinned == ResourceNodeRouter.relay
            ? '正在经 cndrp 同步脱敏诊断'
            : '正在同步脱敏诊断';
        Map<String, dynamic>? receipt;
        if (pending['submitted'] == true) {
          receipt = await api.diagnosticReceipt(
            sha256.convert(body).toString(),
            node: pinned,
          );
        }
        receipt ??= await api.uploadDiagnosticBatch(body, node: pinned);
        if (!_allowed(generation)) return;
        if (receipt['state'] == 'origin_accepted') {
          await prefs.setString(
            checkpointKey,
            jsonEncode(pending['checkpoints']),
          );
          await file.delete();
          _failures = 0;
        } else if (receipt['state'] == 'relay_stored') {
          pending['submitted'] = true;
          await _savePending(file, pending);
          status.value = 'cndrp 已暂存，等待主节点接收回执';
          await _defer(prefs, const Duration(minutes: 1));
          return;
        } else {
          throw const FormatException('Diagnostic batch rejected');
        }
      }
      if (_allowed(generation)) {
        status.value = '本批诊断已同步，剩余部分稍后继续';
        await _defer(prefs, const Duration(minutes: 1));
      }
    } catch (error) {
      if (!_allowed(generation)) return;
      _failures++;
      var delay = Duration(seconds: min(21600, 30 * (1 << min(_failures, 9))));
      if (error is BobTvApiException &&
          error.retryAfter != null &&
          error.retryAfter! > delay) {
        delay = error.retryAfter!;
      }
      status.value = '诊断同步待重试，本机日志已保留';
      await _defer(prefs, delay);
    } finally {
      api.close();
      if (identical(_api, api)) _api = null;
    }
  }

  Future<void> _defer(SharedPreferences prefs, Duration delay) async {
    _nextRetry = now().add(delay);
    await prefs.setString(retryKey, _nextRetry!.toUtc().toIso8601String());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && enabled) {
      // Honor Retry-After and avoid repeated whole-history reads on focus changes.
      if (_lastRun == null ||
          now().difference(_lastRun!) >= const Duration(minutes: 1)) {
        unawaited(sync());
      }
    }
  }

  void dispose() {
    _disposed = true;
    _generation++;
    _api?.close();
    _timer?.cancel();
    unawaited(_network?.cancel() ?? Future.value());
    if (observeLifecycle) WidgetsBinding.instance.removeObserver(this);
    status.dispose();
  }
}
