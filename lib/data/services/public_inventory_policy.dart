/// Only reviewed built-in catalogs and public repository subscriptions are
/// eligible for automatic sharing. Personal subscriptions remain local.
const sharedInventoryProviderIds = {
  'bobtv-channel-catalog',
  'github-ai-crawler',
  'bobtv-reviewed',
  'hotel-guovin-ipv4',
  'hotel-chinaiptv',
  'hotel-myiptv-ipv4',
  'hotel-burningc4-ipv4',
  'hotel-kimentanm-ipv4',
  'hotel-guovin-ipv6',
  'hotel-myiptv-ipv6',
  'hotel-vbskycn-ipv4',
  'hotel-yuechan-ipv4',
  'hotel-iptv-org-cn',
  'hotel-best-fan-status',
};

bool isSharedInventoryProvider({
  required String id,
  required String type,
  String? url,
  String? username,
  String? password,
}) {
  if (type == 'xtream' ||
      (username?.isNotEmpty ?? false) ||
      (password?.isNotEmpty ?? false))
    return false;
  if (sharedInventoryProviderIds.contains(id)) return true;
  final uri = Uri.tryParse(url ?? '');
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment)
    return false;
  final host = uri.host.toLowerCase();
  return const {'github.com', 'raw.githubusercontent.com'}.contains(host) ||
      host.endsWith('.github.io');
}
