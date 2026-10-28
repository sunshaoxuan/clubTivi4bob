import 'dart:async';

import '../../core/app_diagnostics.dart';
import '../datasources/local/database.dart' as db;
import 'bobtv_api_client.dart';
import 'route_identity.dart';

/// Small metadata requests only. Foreground requests bypass the category queue.
class ChannelRouteSyncService {
  ChannelRouteSyncService({
    required this.database,
    required this.fetch,
    this.onCatalogChanged,
  });

  final db.AppDatabase database;
  final Future<BobTvRouteState> Function(List<String>) fetch;
  final void Function()? onCatalogChanged;
  final Map<String, Future<void>> _foreground = {};
  final Map<String, DateTime> _checked = {};
  List<String> _queued = [];
  Future<void>? _background;
  bool _disposed = false;
  int _categoryGeneration = 0;

  List<String> _publicUrls(Iterable<String> urls) => urls
      .map(canonicalRouteUrl)
      .where(BobTvApiClient.isPublicCatalogUrl)
      .toSet()
      .toList();

  Future<void> priority(Iterable<String> urls) async {
    final requested = _publicUrls(urls);
    if (_disposed || requested.isEmpty) return;
    // Each click reads fresh state. Duplicate concurrent clicks share a request.
    for (var offset = 0; offset < requested.length; offset += 200) {
      if (_disposed) return;
      final page = requested.skip(offset).take(200).toList()..sort();
      final key = page.join('\n');
      await (_foreground[key] ??= _read(page).whenComplete(() {
        _foreground.remove(key);
      }));
    }
  }

  Future<void> beforeOpen(String url) async {
    final canonical = canonicalRouteUrl(url);
    if (!BobTvApiClient.isPublicCatalogUrl(canonical)) return;
    final checked = _checked[canonical];
    // A click already checked every candidate; native opening adds protection
    // for startup, next-route, warm players and requests outside the channel UI.
    if (checked != null &&
        DateTime.now().difference(checked) < const Duration(seconds: 3)) {
      return;
    }
    await priority([canonical]);
  }

  void queueCategory(Iterable<String> urls) {
    if (_disposed) return;
    ++_categoryGeneration;
    _queued = _publicUrls(urls);
    _background ??= _drain().whenComplete(() {
      _background = null;
      if (!_disposed && _queued.isNotEmpty) queueCategory(_queued);
    });
  }

  Future<void> _drain() async {
    while (!_disposed && _queued.isNotEmpty) {
      // Wait for foreground work before beginning another background page.
      if (_foreground.isNotEmpty) {
        await Future.wait(
          _foreground.values.map((f) => f.catchError((Object _) {})),
        );
        continue;
      }
      final generation = _categoryGeneration;
      final page = _queued.take(100).toList();
      _queued = _queued.skip(page.length).toList();
      try {
        await _read(page);
      } catch (error, stack) {
        AppDiagnostics.instance.recordError(
          'category_route_state_sync',
          error,
          stack,
        );
        // A failed page cannot hold playback or loop indefinitely. Next category
        // selection and periodic catalog polling retry with the durable cache.
      }
      if (_disposed) return;
      if (generation == _categoryGeneration) {
        await Future<void>.delayed(const Duration(milliseconds: 80));
      }
    }
  }

  Future<void> _read(List<String> urls) async {
    final state = await fetch(urls).timeout(const Duration(seconds: 3));
    if (_disposed) return;
    // Permanent tombstones are applied before this request can authorize open.
    for (final url in state.retiredUrls) {
      if (!await database.isStreamUrlBlocked(url)) {
        await database.withoutSharedReporting(
          () => database.blockAndDeleteStreamUrl(
            url,
            reason: 'shared_catalog_retired',
          ),
        );
      }
    }
    final now = DateTime.now();
    for (final url in urls) {
      _checked[url] = now;
    }
    if (state.catalogVersion != null &&
        state.catalogVersion != await database.sharedCatalogVersion()) {
      onCatalogChanged?.call();
    }
  }

  /// Stop scheduling work and join every operation that can still use the DB.
  Future<void> shutdown() async {
    dispose();
    await Future.wait<Object?>([?_background, ..._foreground.values]);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _queued = [];
  }
}
