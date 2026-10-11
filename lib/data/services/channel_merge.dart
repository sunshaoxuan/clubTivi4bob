import 'route_identity.dart';

class ChannelMergeChoice {
  const ChannelMergeChoice({
    required this.id,
    required this.name,
    required this.group,
    required this.routeCount,
    this.mergeId,
  });
  final String id;
  final String name;
  final String group;
  final int routeCount;
  final String? mergeId;
}

class ChannelMergePlan {
  ChannelMergePlan({
    required String name,
    required this.group,
    required Iterable<String> urls,
    this.epgId,
    this.logoUrl,
  }) : name = name.trim(),
       urls = List.unmodifiable(urls.map(canonicalRouteUrl).toSet());
  final String name;
  final String group;
  final List<String> urls;
  final String? epgId;
  final String? logoUrl;

  bool get valid =>
      name.isNotEmpty &&
      name.length <= 128 &&
      !name.contains(RegExp(r'[\x00-\x1f]')) &&
      group.isNotEmpty &&
      group.length <= 192 &&
      !group.contains(RegExp(r'[\x00-\x1f]')) &&
      urls.isNotEmpty &&
      urls.length <= 1000;
}
