import 'route_identity.dart';

/// A single endpoint changes ownership. Other routes of either channel stay put.
class ChannelRouteTransfer {
  ChannelRouteTransfer({
    required String url,
    required this.targetChannelId,
    required String targetUrl,
    required this.name,
    required this.group,
    this.epgId,
    this.logoUrl,
    this.mergeId,
    this.shared = false,
  }) : url = canonicalRouteUrl(url),
       targetUrl = canonicalRouteUrl(targetUrl);

  final String url;
  final String targetChannelId;
  final String targetUrl;
  final String name;
  final String group;
  final String? epgId;
  final String? logoUrl;
  final String? mergeId;
  final bool shared;
}
