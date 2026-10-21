import 'dart:convert';

import 'channel_name_normalizer.dart';
import 'channel_category_classifier.dart';
import 'favorite_channel_identity.dart';
import 'route_identity.dart';

/// A local presentation identity, never an EPG identity or a persisted rewrite.
class ChannelPresentationRoute {
  const ChannelPresentationRoute({
    required this.id,
    required this.name,
    required this.url,
    this.group,
    this.tvgName,
    this.tvgId,
    this.catalogId,
    this.mergeId,
    this.countryCode,
    this.regionCode,
  });

  final String id, name, url;
  final String? group, tvgName, tvgId, catalogId, mergeId;
  final String? countryCode, regionCode;

  String get legacyKey => ChannelNameNormalizer.normalize(name).isEmpty
      ? 'unidentified:$id'
      : favoriteChannelIdentity(
          name: name,
          group: group,
          tvgName: tvgName,
          tvgId: tvgId,
        );
}

class ChannelPresentationIdentity {
  const ChannelPresentationIdentity._();

  // Service name, domestic scope, media/quality and compatible guide metadata
  // identify a presentation group. Persistent server and EPG IDs stay intact.
  static String _publicKey(ChannelPresentationRoute route) {
    var path = (route.group ?? '').split(' / ');
    // Older snapshots stored domestic category leaves without the country root.
    if (path.length == 1 && {'央视', '数字', '卫视', '广播'}.contains(path.first)) {
      path = ['中国', ...path];
    }
    final name = ChannelNameNormalizer.normalize(route.name);
    final domestic =
        path.length >= 2 &&
        path.first == '中国' &&
        !path.any((part) => {'其他', '未识别地区', '未知', ''}.contains(part));
    final international =
        path.length >= 2 &&
        path.first == '国际' &&
        ChannelCategoryClassifier.internationalCountryNames.containsValue(
          path[1],
        ) &&
        (path.length == 2 ||
            (path.length == 3 &&
                ChannelCategoryClassifier.internationalGenres.contains(
                  path[2],
                )));
    if ((domestic || international) && name.isNotEmpty) {
      // Genre memberships do not define separate services. Local regions and
      // custom subcategories continue to be explicit identity boundaries.
      final scope = domestic
          ? (path.length == 2 && {'央视', '数字', '卫视'}.contains(path[1])
                ? '中国 / 全国电视'
                : path.join(' / '))
          : path.take(2).join(' / ');
      final guide = route.tvgId;
      final guideIdentity =
          guide == null ||
              guide.trim().isEmpty ||
              ChannelNameNormalizer.normalize(guide) == name
          ? null
          : guide;
      final service = route.legacyKey.split('|').skip(1).join('|');
      final explicitCountry = route.countryCode?.toLowerCase();
      final country = domestic
          ? explicitCountry ?? 'cn'
          : ChannelCategoryClassifier
                    .internationalCountryNames[explicitCountry] ??
                explicitCountry ??
                path[1];
      return 'service:${jsonEncode([scope, service, guideIdentity, country, route.regionCode])}';
    }
    return 'catalog:${route.catalogId}';
  }

  /// Bridge old-provider rows through an exact canonical public route. Names
  /// and category boundaries plus guide, region and quality metadata identify
  /// domestic services. Ambiguous bridges fail closed. Explicit
  /// manual merges take precedence, and no source rows are removed.
  static Map<String, String> keys(Iterable<ChannelPresentationRoute> input) {
    final routes = input.toList();
    final publicCandidates = <String, Set<String>>{};
    for (final route in routes) {
      if (route.catalogId != null && route.mergeId == null) {
        (publicCandidates[route.catalogId!] ??= {}).add(_publicKey(route));
      }
    }
    final publicKeys = {
      for (final entry in publicCandidates.entries)
        entry.key: entry.value.length == 1
            ? entry.value.single
            : 'catalog:${entry.key}',
    };
    final publicByUrl = <String, List<ChannelPresentationRoute>>{};
    for (final route in routes) {
      if (route.catalogId != null && route.mergeId == null) {
        (publicByUrl[canonicalRouteUrl(route.url)] ??= []).add(route);
      }
    }
    // Legacy provider labels often omit the domestic catalog hierarchy. A
    // unique national service can accept its exact full-name alternatives,
    // provided no country, local region, guide or quality distinction conflicts.
    final nationalByService = <String, Set<String>>{};
    for (final route in routes) {
      if (route.catalogId == null ||
          route.mergeId != null ||
          route.regionCode != null ||
          (route.countryCode != null && route.countryCode != 'cn'))
        continue;
      final key = publicKeys[route.catalogId]!;
      if (!key.startsWith('service:')) continue;
      final scope =
          (jsonDecode(key.substring('service:'.length)) as List).first;
      if (scope == '中国 / 全国电视') {
        (nationalByService[route.legacyKey.split('|').skip(1).join('|')] ??= {})
            .add(key);
      }
    }
    final bridges = <String, Set<String>>{};
    for (final route in routes) {
      if (route.catalogId != null || route.mergeId != null) {
        continue;
      }
      if (ChannelNameNormalizer.normalize(route.name).isEmpty) {
        continue;
      }
      final legacyParts = route.legacyKey.split('|');
      final group = route.group ?? '';
      final country = legacyParts.first;
      final localPath = group.split(' / ');
      final nationalOrUnspecified =
          !group.startsWith('国际') &&
          (!group.startsWith('中国 / ') ||
              (localPath.length == 2 &&
                  {'央视', '数字', '卫视'}.contains(localPath[1])));
      if ((country.isEmpty || country == '中国') &&
          nationalOrUnspecified &&
          (route.tvgId == null ||
              ChannelNameNormalizer.normalize(route.tvgId!) ==
                  ChannelNameNormalizer.normalize(route.name))) {
        final candidates = nationalByService[legacyParts.skip(1).join('|')];
        if (candidates != null && candidates.length == 1) {
          (bridges[route.legacyKey] ??= {}).add(candidates.single);
        }
      }
      for (final public
          in publicByUrl[canonicalRouteUrl(route.url)] ??
              <ChannelPresentationRoute>[]) {
        // Matching URL with contradictory metadata is an identity conflict,
        // not permission to select programmes or a different service.
        if (ChannelNameNormalizer.normalize(route.name) !=
            ChannelNameNormalizer.normalize(public.name)) {
          continue;
        }
        final legacy = route.legacyKey.split('|');
        final managed = public.legacyKey.split('|');
        if (legacy.skip(2).join('|') != managed.skip(2).join('|')) {
          continue;
        }
        if (legacy.first.isNotEmpty &&
            managed.first.isNotEmpty &&
            legacy.first != managed.first) {
          continue;
        }
        (bridges[route.legacyKey] ??= {}).add(publicKeys[public.catalogId]!);
      }
    }
    return {
      for (final route in routes)
        route.id: route.mergeId != null
            ? 'manual:${route.mergeId}'
            : route.catalogId != null
            ? publicKeys[route.catalogId]!
            : bridges[route.legacyKey]?.length == 1
            ? bridges[route.legacyKey]!.single
            : 'legacy:${route.legacyKey}',
    };
  }

  /// Keep the currently playing row as the visible representative when it is
  /// still present. A catalog refresh must not move the live preview.
  static List<T> representatives<T>(
    Iterable<T> routes, {
    required String Function(T) idOf,
    required String Function(T) keyOf,
    required int Function(T) scoreOf,
    String? playingId,
  }) {
    final selected = <String, T>{};
    for (final route in routes) {
      final key = keyOf(route);
      final previous = selected[key];
      if (previous == null ||
          idOf(route) == playingId ||
          (idOf(previous) != playingId && scoreOf(route) > scoreOf(previous))) {
        selected[key] = route;
      }
    }
    return selected.values.toList();
  }
}
