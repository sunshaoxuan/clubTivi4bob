import 'dart:convert';

/// Builds an escaped UPnP AVTransport request with a real DIDL resource.
List<int> dlnaSetMediaRequest(String url, {String title = ''}) {
  String escape(String value) =>
      const HtmlEscape(HtmlEscapeMode.element).convert(value);
  final path = Uri.parse(url).path.toLowerCase();
  final mime = path.endsWith('.m3u8')
      ? 'application/vnd.apple.mpegurl'
      : path.endsWith('.ts')
      ? 'video/mp2t'
      : path.endsWith('.mp4')
      ? 'video/mp4'
      : path.endsWith('.mp3')
      ? 'audio/mpeg'
      : 'application/octet-stream';
  final mediaClass = mime.startsWith('audio/')
      ? 'object.item.audioItem.musicTrack'
      : 'object.item.videoItem';
  final metadata =
      '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
      'xmlns:dc="http://purl.org/dc/elements/1.1/" '
      'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
      '<item id="0" parentID="-1" restricted="1">'
      '<dc:title>${escape(title.isEmpty ? 'BobTV' : title)}</dc:title>'
      '<upnp:class>$mediaClass</upnp:class>'
      '<res protocolInfo="http-get:*:$mime:*">${escape(url)}</res>'
      '</item></DIDL-Lite>';
  return utf8.encode(
    '<?xml version="1.0" encoding="utf-8"?>'
    '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
    's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
    '<s:Body><u:SetAVTransportURI xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">'
    '<InstanceID>0</InstanceID><CurrentURI>${escape(url)}</CurrentURI>'
    '<CurrentURIMetaData>${escape(metadata)}</CurrentURIMetaData>'
    '</u:SetAVTransportURI></s:Body></s:Envelope>',
  );
}
