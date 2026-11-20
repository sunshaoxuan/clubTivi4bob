import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Data only. Unknown fields are rejected so misspelled fields cannot silently
/// turn into a different snapshot. IDs belong to one local subscription.
class ResourcePackage {
  ResourcePackage._(
    this.id,
    this.name,
    this.revision,
    this.categories,
    this.channels,
    this.epgSources,
    this.updateUrl,
  );
  final String id, name, revision;
  final Map<String, String> categories;
  final List<ResourceChannel> channels;
  final Map<String, Uri> epgSources;
  final Uri? updateUrl;
  int get routeCount => channels.fold(0, (n, c) => n + c.routes.length);

  static const maxBytes = 8 * 1024 * 1024;
  static Never invalid(String field) =>
      throw FormatException('Invalid BobTV resource package: $field');

  static Map<String, dynamic> object(
    Object? value,
    Set<String> keys,
    String at,
  ) {
    if (value is! Map<String, dynamic> ||
        value.keys.any((k) => !keys.contains(k))) {
      invalid(at);
    }
    return value;
  }

  static String string(Object? value, String at, {int max = 512}) {
    if (value is! String ||
        value.trim().isEmpty ||
        value.length > max ||
        value.contains(RegExp(r'[\x00-\x1f]'))) {
      invalid(at);
    }
    return value.trim();
  }

  static List<dynamic> list(Object? value, String at, int max) {
    if (value is! List || value.length > max) invalid(at);
    return value;
  }

  static Uri url(Object? value, String at, {bool media = false}) {
    final text = string(value, at, max: 4096);
    final uri = Uri.tryParse(text);
    final schemes = media
        ? {'https', 'http', 'rtsp', 'rtmp', 'udp', 'rtp'}
        : {'https', 'http'};
    if (uri == null ||
        !schemes.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      invalid(at);
    }
    return uri;
  }

  static String localId(String provider, String kind, String remote) =>
      'user:${sha256.convert(utf8.encode(jsonEncode([provider, kind, remote])))}';

  factory ResourcePackage.parse(String input) {
    if (utf8.encode(input).length > maxBytes) invalid('size');
    // Bound nesting before jsonDecode, including hostile unknown fields.
    var depth = 0, inString = false, escaped = false;
    for (final rune in input.runes) {
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (rune == 92) {
          escaped = true;
        } else if (rune == 34) {
          inString = false;
        }
      } else if (rune == 34) {
        inString = true;
      } else if (rune == 123 || rune == 91) {
        if (++depth > 16) invalid('depth');
      } else if (rune == 125 || rune == 93) {
        depth--;
      }
    }
    Object? decoded;
    try {
      decoded = jsonDecode(input);
    } on FormatException {
      invalid('JSON');
    }
    final root = object(decoded, {
      'format',
      'schemaVersion',
      'id',
      'name',
      'revision',
      'categories',
      'channels',
      'epgSources',
      'updateUrl',
    }, 'root');
    if (root['format'] != 'bobtv-resource' ||
        root['schemaVersion'] is! int ||
        root['schemaVersion'] != 1) {
      invalid('format/schemaVersion');
    }
    final id = string(root['id'], 'id', max: 128);
    final name = string(root['name'], 'name');
    final revision = string(root['revision'], 'revision', max: 128);
    final categories = <String, String>{};
    for (final value in list(root['categories'], 'categories', 1000)) {
      final c = object(value, {'id', 'name'}, 'category');
      final key = string(c['id'], 'category.id', max: 128);
      if (categories.containsKey(key)) invalid('duplicate category');
      categories[key] = string(c['name'], 'category.name');
    }
    if (categories.isEmpty) invalid('categories empty');
    final epg = <String, Uri>{};
    for (final value in list(root['epgSources'] ?? [], 'epgSources', 32)) {
      final e = object(value, {'id', 'url'}, 'epgSource');
      final key = string(e['id'], 'epgSource.id', max: 128);
      if (epg.containsKey(key)) invalid('duplicate epgSource');
      epg[key] = url(e['url'], 'epgSource.url');
    }
    final channels = <ResourceChannel>[];
    final ids = <String>{};
    var routes = 0;
    for (final value in list(root['channels'], 'channels', 10000)) {
      final c = object(value, {
        'id',
        'name',
        'categoryId',
        'logo',
        'epg',
        'routes',
      }, 'channel');
      final key = string(c['id'], 'channel.id', max: 128);
      if (!ids.add(key)) invalid('duplicate channel');
      final group = string(c['categoryId'], 'channel.categoryId', max: 128);
      if (!categories.containsKey(group)) invalid('unknown categoryId');
      final channelRoutes = <String, Uri>{};
      for (final r in list(c['routes'], 'routes', 32)) {
        final route = object(r, {'id', 'url'}, 'route');
        final rid = string(route['id'], 'route.id', max: 128);
        if (channelRoutes.containsKey(rid)) invalid('duplicate route');
        channelRoutes[rid] = url(route['url'], 'route.url', media: true);
        if (++routes > 30000) invalid('route count');
      }
      if (channelRoutes.isEmpty) invalid('routes empty');
      String? epgId, epgSource;
      if (c['epg'] != null) {
        final e = object(c['epg'], {'sourceId', 'channelId'}, 'channel.epg');
        epgSource = string(e['sourceId'], 'epg.sourceId', max: 128);
        epgId = string(e['channelId'], 'epg.channelId');
        if (!epg.containsKey(epgSource)) invalid('unknown epg source');
      }
      channels.add(
        ResourceChannel(
          key,
          string(c['name'], 'channel.name'),
          categories[group]!,
          c['logo'] == null ? null : url(c['logo'], 'logo'),
          channelRoutes,
          epgSource,
          epgId,
        ),
      );
    }
    // An explicit empty snapshot is valid, and retires previous routes.
    return ResourcePackage._(
      id,
      name,
      revision,
      Map.unmodifiable(categories),
      List.unmodifiable(channels),
      Map.unmodifiable(epg),
      root['updateUrl'] == null ? null : url(root['updateUrl'], 'updateUrl'),
    );
  }
}

class ResourceChannel {
  const ResourceChannel(
    this.id,
    this.name,
    this.group,
    this.logo,
    this.routes,
    this.epgSourceId,
    this.epgChannelId,
  );
  final String id, name, group;
  final Uri? logo;
  final Map<String, Uri> routes;
  final String? epgSourceId, epgChannelId;
}
