import 'dart:async';

import 'route_identity.dart';

/// Permanent endpoint exclusions, independent of recoverable health scores.
/// A stale snapshot or a later success can never remove a known tombstone.
class RetiredRouteGuard {
  RetiredRouteGuard({
    required Future<Set<String>> Function() read,
    required Stream<Set<String>> updates,
    this.beforeOpen,
  }) : _read = read {
    _subscription = updates.listen(
      _absorb,
      onError: (Object _) {
        // The next open still reads durable storage and fails closed on error.
      },
    );
  }

  final Future<Set<String>> Function() _read;
  final Future<void> Function(String url)? beforeOpen;
  final _retired = <String>{};
  final _changes = StreamController<Set<String>>.broadcast(sync: true);
  late final StreamSubscription<Set<String>> _subscription;
  Future<void>? _reading;
  bool _disposed = false;

  Stream<Set<String>> get changes => _changes.stream;
  bool allowsCached(String url) =>
      !_disposed && !_retired.contains(canonicalRouteUrl(url));
  Iterable<String> filter(Iterable<String> urls) => urls.where(allowsCached);

  void _absorb(Set<String> routes) {
    if (_disposed) return;
    final added = routes.map(canonicalRouteUrl).toSet().difference(_retired);
    if (added.isEmpty) return;
    _retired.addAll(added);
    _changes.add(Set.unmodifiable(added));
  }

  Future<void> refresh() {
    if (_disposed) return Future.error(const RetiredRouteException());
    return _reading ??= _read()
        .then(_absorb)
        .whenComplete(() => _reading = null);
  }

  Future<void> requireAllowed(String url) async {
    await refresh();
    if (!allowsCached(url)) throw const RetiredRouteException();
  }

  /// Check both sides of an asynchronous native open. A retirement arriving
  /// during connection must stop the decoder before it can be promoted.
  Future<void> open(
    String url,
    Future<void> Function() operation, {
    required Future<void> Function() stop,
  }) async {
    await beforeOpen?.call(url);
    await requireAllowed(url);
    await operation();
    try {
      await requireAllowed(url);
    } catch (_) {
      await stop();
      rethrow;
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await _subscription.cancel();
    await _changes.close();
  }
}

class RetiredRouteException implements Exception {
  const RetiredRouteException();
  @override
  String toString() => '线路已永久淘汰，禁止再次播放';
}
