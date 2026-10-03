/// Conservative endpoint identity shared with the website. Path and query
/// spelling, HTTP/HTTPS, and non-default ports remain distinct.
String canonicalRouteUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null ||
      !{'http', 'https'}.contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment) {
    return url;
  }
  var host = uri.host.toLowerCase();
  if (host.contains(':') && !host.startsWith('[')) host = '[$host]';
  final defaultPort = uri.scheme == 'https' ? 443 : 80;
  if (uri.hasPort && uri.port != defaultPort) host = '$host:${uri.port}';
  final authorityStart = url.indexOf('://') + 3;
  if (authorityStart < 3) return url;
  final rest = url.substring(authorityStart);
  final marker = rest.indexOf(RegExp(r'[/\?#]'));
  var suffix = marker < 0 ? '' : rest.substring(marker);
  if (suffix.isEmpty || suffix.startsWith('?')) suffix = '/$suffix';
  return '${uri.scheme}://$host$suffix';
}
