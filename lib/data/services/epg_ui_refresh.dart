import 'dart:async';

import '../datasources/local/database.dart' as db;
import '../models/server_epg_snapshot.dart';

/// Coalesces guide invalidations without knowing anything about playback.
class EpgUiRefresh {
  EpgUiRefresh(
    Stream<void> changes,
    this.refresh, {
    this.debounce = const Duration(milliseconds: 120),
    this.onError,
  }) {
    _subscription = changes.listen(
      (_) => request(),
      onError: (Object error, StackTrace stack) {
        _report(error, stack);
      },
    );
  }
  final Future<void> Function() refresh;
  final Duration debounce;
  final void Function(Object, StackTrace)? onError;
  StreamSubscription<void>? _subscription;
  Timer? _timer;
  bool _disposed = false, _running = false, _queued = false;

  void request() {
    if (_disposed) return;
    _queued = true;
    if (_running) return;
    _timer?.cancel();
    _timer = Timer(debounce, _drain);
  }

  Future<void> _drain() async {
    if (_disposed || _running) return;
    _running = true;
    try {
      while (_queued && !_disposed) {
        _queued = false;
        try {
          await refresh();
        } catch (error, stack) {
          _report(error, stack);
        }
      }
    } finally {
      _running = false;
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    unawaited(_subscription?.cancel());
  }

  void _report(Object error, StackTrace stack) {
    try {
      onError?.call(error, stack);
    } catch (_) {
      /* Non-blocking diagnostics. */
    }
  }
}

/// Resolve a newly added or changed mapping while fullscreen navigation context
/// stays untouched. Invalidated managed mappings cannot reuse a stale nav ID.
Future<String?> resolveLiveEpgId(
  db.AppDatabase database, {
  required String channelId,
  String? providerId,
  String? fallbackId,
}) async {
  if (channelId.isNotEmpty) {
    final mappings = await database.getMappingsForChannelIds({channelId});
    final mapping = mappings
        .where((m) => providerId == null || m.providerId == providerId)
        .firstOrNull;
    if (mapping != null) {
      final source = (await database.getAllEpgSources())
          .where((s) => s.id == mapping.epgSourceId && s.enabled)
          .firstOrNull;
      if (source == null) return null;
      return '${mapping.epgSourceId}_${mapping.epgChannelId}';
    }
  }
  if (fallbackId?.startsWith('${serverEpgSourceId}_') == true) return null;
  return fallbackId;
}
