import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../datasources/local/database.dart' as db;
import '../resource_package/resource_package.dart';

/// Guide URLs discovered through a user source stay scoped to its provider.
class PlaylistEpgSources {
  const PlaylistEpgSources(this.database);

  final db.AppDatabase database;
  static const _playlistPrefix = 'user:m3u:';
  static const _xtreamPrefix = 'user:xtream:';

  static bool isXtream(String sourceId) => sourceId.startsWith(_xtreamPrefix);

  static bool contains(String sourceId) =>
      sourceId.startsWith(_playlistPrefix) || isXtream(sourceId);

  static String prefixFor(String providerId, {required bool xtream}) =>
      '${xtream ? _xtreamPrefix : _playlistPrefix}${Uri.encodeComponent(providerId)}:';

  static String? providerOf(String sourceId) =>
      contains(sourceId) ? Uri.decodeComponent(sourceId.split(':')[2]) : null;

  Future<List<String>> reconcile(
    db.Provider provider,
    Uri playlistUri,
    List<String> declarations,
  ) async {
    final urls = <String>{};
    for (final declaration in declarations) {
      try {
        final url = ResourcePackage.url(
          playlistUri.resolve(declaration).toString(),
          'playlist EPG URL',
        );
        if (playlistUri.scheme == 'https' && url.scheme != 'https') continue;
        urls.add(url.toString());
        if (urls.length == 4) break;
      } on FormatException {
        continue;
      }
    }
    final prefix = prefixFor(provider.id, xtream: provider.type == 'xtream');
    final previous = {
      for (final source in await database.getAllEpgSources())
        if (source.id.startsWith(prefix)) source.id: source,
    };
    final pending = <String>[];
    for (final url in urls) {
      final id = '$prefix${sha256.convert(utf8.encode(url))}';
      final source = previous.remove(id);
      if (source == null) {
        await database.upsertEpgSource(
          db.EpgSourcesCompanion.insert(id: id, name: provider.name, url: url),
        );
      }
      if (source == null || (source.enabled && source.lastRefresh == null)) {
        pending.add(id);
      }
    }
    for (final id in previous.keys) {
      await _remove(id);
    }
    return pending;
  }

  Future<void> removeProvider(String providerId, {required bool xtream}) async {
    final prefix = prefixFor(providerId, xtream: xtream);
    for (final source in await database.getAllEpgSources()) {
      if (source.id.startsWith(prefix)) await _remove(source.id);
    }
  }

  Future<void> _remove(String id) async {
    await (database.delete(
      database.epgMappings,
    )..where((mapping) => mapping.epgSourceId.equals(id))).go();
    await database.deleteEpgSource(id);
  }
}
