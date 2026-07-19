class SourceVisibility {
  static const hideIpv6PreferenceKey = 'hide_ipv6_sources';

  static bool isIpv6Provider({
    required String id,
    required String name,
    required String? url,
  }) {
    final metadata = '$id $name ${url ?? ''}'.toLowerCase();
    return RegExp(r'(^|[^a-z0-9])ipv6([^a-z0-9]|$)').hasMatch(metadata);
  }

  static bool isIpv6StreamUrl(String streamUrl) {
    final cleanUrl = streamUrl.split('|').first.trim();
    final uri = Uri.tryParse(cleanUrl);
    if (uri == null || uri.host.isEmpty) return false;
    return uri.host.contains(':');
  }
}
