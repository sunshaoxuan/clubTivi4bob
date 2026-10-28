import 'dart:async';

import 'route_identity.dart';

class RecoveryRoute {
  const RecoveryRoute(this.localId, this.url);
  final String localId;
  final String url;
}

enum RecoveryRetryMode { none, preserveActive, restart }

RecoveryRetryMode recoveryRetryMode({
  required String intendedChannelId,
  required String? activeChannelId,
  required bool activeChanged,
  required bool hasActiveUrl,
  required bool playbackAdvancing,
}) {
  if (activeChanged) return RecoveryRetryMode.none;
  if (!hasActiveUrl) return RecoveryRetryMode.restart;
  if (activeChannelId == intendedChannelId) {
    return playbackAdvancing
        ? RecoveryRetryMode.none
        : RecoveryRetryMode.restart;
  }
  return RecoveryRetryMode.preserveActive;
}

/// Clients request one public identity, then consume BobTV's catalog only.
/// Server backoff survives app exits; changing playback intent cancels local
/// retries without cancelling the independent server research job.
class ChannelRouteRecoveryService {
  ChannelRouteRecoveryService({
    required this.submit,
    required this.result,
    required this.syncCatalog,
    required this.readRoutes,
    required this.onAvailable,
    this.onStatus,
    DateTime Function()? now,
    this.automaticPolling = true,
  }) : now = now ?? DateTime.now;

  final Future<Map<String, dynamic>> Function(
    String channelId,
    String failedUrl,
  )
  submit;
  final Future<Map<String, dynamic>> Function(String id) result;
  final Future<void> Function() syncCatalog;
  final Future<List<RecoveryRoute>> Function(String channelId) readRoutes;
  final Future<void> Function(String channelId, List<RecoveryRoute> routes)
  onAvailable;
  final void Function(String state, DateTime? nextRetry)? onStatus;
  final DateTime Function() now;
  final bool automaticPolling;
  final Map<String, DateTime> _requested = {};
  final Set<String> _known = {};
  int _generation = 0;
  String? _channel, _job;
  DateTime? _nextServerCheck;
  Timer? _timer;
  Future<void>? _polling;
  bool _disposed = false;

  Future<void> request(String channelId, String failedUrl) async {
    if (_disposed) return;
    if (_channel == channelId) return;
    final previous = _requested[channelId];
    if (previous != null &&
        now().difference(previous) < const Duration(minutes: 5)) {
      return;
    }
    cancel();
    final generation = _generation;
    _channel = channelId;
    _requested[channelId] = now();
    try {
      final routes = await readRoutes(channelId);
      if (!_active(generation)) return;
      _known.addAll(routes.map((r) => canonicalRouteUrl(r.url)));
      final reply = await submit(channelId, canonicalRouteUrl(failedUrl));
      if (!_active(generation)) return;
      final id = reply['id'];
      if (id is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(id)) {
        throw const FormatException('Invalid server recovery receipt');
      }
      _job = id;
      _status(reply);
      if (automaticPolling) {
        _timer = Timer.periodic(
          const Duration(seconds: 30),
          (_) => unawaited(poll()),
        );
      }
      await poll();
    } catch (_) {
      if (_active(generation)) {
        onStatus?.call('unavailable', null);
        cancel();
      }
    }
  }

  bool _active(int generation) =>
      !_disposed && generation == _generation && _channel != null;

  void _status(Map<String, dynamic> reply) {
    final retry = reply['nextRetryAt'];
    _nextServerCheck = retry is int && retry > 0
        ? DateTime.fromMillisecondsSinceEpoch(retry * 1000)
        : null;
    final items = reply['items'];
    final state = items is List && items.isNotEmpty && items.first is Map
        ? (items.first as Map)['state']
        : reply['state'];
    onStatus?.call(state is String ? state : 'queued', _nextServerCheck);
  }

  Future<void> poll() =>
      _polling ??= _poll().whenComplete(() => _polling = null);

  Future<void> _poll() async {
    final generation = _generation;
    final channel = _channel, job = _job;
    if (channel == null || job == null || !_active(generation)) return;
    try {
      // Catalog refreshes are versioned, coalesced and retain offline data.
      // Never visit a search engine, repository or stream-search site here.
      await syncCatalog();
      if (!_active(generation)) return;
      final routes = await readRoutes(channel);
      if (!_active(generation)) return;
      final added = routes
          .where((r) => !_known.contains(canonicalRouteUrl(r.url)))
          .toList();
      if (added.isNotEmpty) {
        _known.addAll(added.map((r) => canonicalRouteUrl(r.url)));
        await onAvailable(channel, added);
        if (_active(generation)) cancel();
        return;
      }
      if (_nextServerCheck?.isAfter(now()) ?? false) return;
      final reply = await result(job);
      if (!_active(generation)) return;
      _status(reply);
      // A published result may have arrived after this poll's manifest read.
      if (reply['state'] == 'done') {
        await syncCatalog();
        if (!_active(generation)) return;
        final refreshed = await readRoutes(channel);
        if (!_active(generation)) return;
        final added = refreshed
            .where((r) => !_known.contains(canonicalRouteUrl(r.url)))
            .toList();
        if (added.isNotEmpty) {
          await onAvailable(channel, added);
          if (_active(generation)) cancel();
        } else {
          final items = reply['items'];
          final published =
              items is List &&
              items.any(
                (item) =>
                    item is Map &&
                    item['added'] is num &&
                    (item['added'] as num) > 0,
              );
          if (published) {
            // A lagging/offline manifest cannot acknowledge a published route.
            // Keep observing until the actual new row is committed locally.
            _nextServerCheck = now().add(const Duration(minutes: 1));
          } else if (_active(generation)) {
            cancel();
          }
        }
      }
    } catch (_) {
      if (_active(generation)) {
        _nextServerCheck = now().add(const Duration(minutes: 1));
        onStatus?.call('unavailable', _nextServerCheck);
      }
    }
  }

  void cancel() {
    ++_generation;
    _timer?.cancel();
    _timer = null;
    _channel = _job = null;
    _nextServerCheck = null;
    _known.clear();
  }

  void dispose() {
    _disposed = true;
    cancel();
  }
}
