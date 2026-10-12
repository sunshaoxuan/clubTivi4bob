import 'dart:convert';

/// Private selection metadata only. Stream URLs and provider credentials are
/// never included; canonical route hashes reconnect favorites to local channels.
class DeviceFavoritesSnapshot {
  const DeviceFavoritesSnapshot({
    this.lists = const [],
    this.legacyRoutes = const [],
  });
  final List<DeviceFavoriteList> lists;
  final List<String> legacyRoutes;
  bool get isEmpty => lists.isEmpty && legacyRoutes.isEmpty;

  Map<String, Object> toJson() => {
    'lists': lists.map((list) => list.toJson()).toList(),
    'legacyRoutes': legacyRoutes,
  };

  static bool _text(Object? value, int max) =>
      value is String &&
      value.isNotEmpty &&
      value.length <= max &&
      !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value);
  static final _route = RegExp(r'^[a-f0-9]{64}$');

  static List<String> _routes(Object? value) {
    if (value is! List ||
        value.length > 5000 ||
        value.any((key) => key is! String || !_route.hasMatch(key)) ||
        value.toSet().length != value.length) {
      throw const FormatException('Invalid private favorite references');
    }
    return List<String>.from(value);
  }

  factory DeviceFavoritesSnapshot.parse(Object? value) {
    if (value is! Map ||
        value.length != 2 ||
        !value.containsKey('lists') ||
        !value.containsKey('legacyRoutes') ||
        value['lists'] is! List ||
        (value['lists'] as List).length > 100) {
      throw const FormatException('Invalid private favorite snapshot');
    }
    final lists = <DeviceFavoriteList>[];
    final ids = <String>{};
    final legacy = _routes(value['legacyRoutes']);
    var count = legacy.length;
    for (final item in value['lists'] as List) {
      if (item is! Map ||
          item.length != 5 ||
          !item.keys.toSet().containsAll({
            'id',
            'name',
            'icon',
            'sortOrder',
            'routes',
          }) ||
          !_text(item['id'], 80) ||
          !RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(item['id'] as String) ||
          !ids.add(item['id'] as String) ||
          !_text(item['name'], 128) ||
          !_text(item['icon'], 64) ||
          item['sortOrder'] is! int ||
          (item['sortOrder'] as int) < 0 ||
          (item['sortOrder'] as int) > 100000) {
        throw const FormatException('Invalid private favorite list');
      }
      final routes = _routes(item['routes']);
      count += routes.length;
      if (count > 5000) {
        throw const FormatException('Private favorites exceed backup limit');
      }
      lists.add(
        DeviceFavoriteList(
          id: item['id'] as String,
          name: item['name'] as String,
          icon: item['icon'] as String,
          sortOrder: item['sortOrder'] as int,
          routes: routes,
        ),
      );
    }
    final snapshot = DeviceFavoritesSnapshot(
      lists: lists,
      legacyRoutes: legacy,
    );
    if (utf8.encode(jsonEncode(snapshot.toJson())).length > 500 * 1024) {
      throw const FormatException('Private favorites exceed backup size limit');
    }
    return snapshot;
  }
}

class DeviceFavoriteList {
  const DeviceFavoriteList({
    required this.id,
    required this.name,
    required this.icon,
    required this.sortOrder,
    required this.routes,
  });
  final String id;
  final String name;
  final String icon;
  final int sortOrder;
  final List<String> routes;
  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'icon': icon,
    'sortOrder': sortOrder,
    'routes': routes,
  };
}

class DeviceFavoritesBackup {
  const DeviceFavoritesBackup({required this.revision, required this.snapshot});
  final int revision;
  final DeviceFavoritesSnapshot? snapshot;
}
