import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../datasources/parsers/xmltv_parser.dart';
import 'epg.dart';
import 'catalog_epg_identity.dart';

const serverEpgSourceId = 'bobtv-server-epg';
const serverEpgManifestUrl = 'https://bobtv.briconbric.com/api/v1/epg/manifest';
final _digest = RegExp(r'^[a-f0-9]{64}$');

class ServerEpgManifest {
  ServerEpgManifest._(this.json);
  final Map<String, dynamic> json;
  String get version => json['version'] as String;
  String get sha256 => json['sha256'] as String;
  String get snapshotPath => json['snapshotUrl'] as String;
  int get compressedBytes => json['compressedBytes'] as int;
  int get channelCount => json['channelCount'] as int;
  int get programmeCount => json['programmeCount'] as int;
  int get coverageEndUtc => json['coverageEndUtc'] as int;
  DateTime get generatedAt => DateTime.parse(json['generatedAt'] as String);

  static ServerEpgManifest? parse(Object? value) {
    if (value is! Map<String, dynamic> || value['schemaVersion'] != 1) {
      throw const FormatException('Unsupported EPG manifest');
    }
    if (value['version'] == null && value['channelCount'] == 0) return null;
    final version = value['version'];
    final hash = value['sha256'];
    final generated = value['generatedAt'];
    bool bounded(String key, int low, int high) =>
        value[key] is int &&
        (value[key] as int) >= low &&
        (value[key] as int) <= high;
    if (version is! String ||
        !RegExp(r'^epg-[a-f0-9]{64}$').hasMatch(version) ||
        hash is! String ||
        !_digest.hasMatch(hash) ||
        value['snapshotUrl'] != '/api/v1/epg/snapshots/$hash.json.gz' ||
        !bounded('compressedBytes', 1, 8 * 1024 * 1024) ||
        !bounded('channelCount', 1, 10000) ||
        !bounded('programmeCount', 1, 200000) ||
        !bounded('coverageStartUtc', 0, 4102444800) ||
        !bounded('coverageEndUtc', 0, 4102444800) ||
        (value['coverageEndUtc'] as int) <=
            (value['coverageStartUtc'] as int) ||
        generated is! String ||
        !generated.endsWith('Z') ||
        DateTime.tryParse(generated) == null) {
      throw const FormatException('Invalid EPG manifest');
    }
    return ServerEpgManifest._(Map.unmodifiable(value));
  }
}

class ServerEpgSnapshot {
  const ServerEpgSnapshot(
    this.guide,
    this.identities, {
    this.attributions = const [],
  });
  final XmltvResult guide;
  // Preserved for exact catalog-identity integration. Never fuzzy auto-mapped.
  final Map<String, Map<String, dynamic>> identities;
  final List<ServerEpgAttribution> attributions;
}

/// Display-only metadata. The receiver never fetches attribution URLs.
class ServerEpgAttribution {
  ServerEpgAttribution._(this.json);
  final Map<String, dynamic> json;
  String get sourceId => json['sourceId'] as String;
  String get sourceLabel => json['sourceLabel'] as String;
  String get attributionUrl => json['attributionUrl'] as String;
  String get licenseUrl => json['licenseUrl'] as String;
  String get modificationNotice => json['modificationNotice'] as String;
  bool get shareAlikeRequired => json['shareAlikeRequired'] as bool;
  String get dataLicense => json['licenseUrl'] == 'https://data.gov.tw/license'
      ? 'Open Government Data License 1.0'
      : 'CC BY-SA 4.0';

  static ServerEpgAttribution parse(Object? value) {
    const keys = {
      'sourceId',
      'sourceLabel',
      'attributionUrl',
      'licenseUrl',
      'modificationNotice',
      'shareAlikeRequired',
    };
    if (value is! Map<String, dynamic> ||
        value.length != keys.length ||
        !value.keys.toSet().containsAll(keys) ||
        !_text(value['sourceId'], 128) ||
        !_text(value['sourceLabel'], 512) ||
        !_text(value['modificationNotice'], 512) ||
        !((value['shareAlikeRequired'] == true &&
                value['licenseUrl'] ==
                    'https://creativecommons.org/licenses/by-sa/4.0/') ||
            (value['shareAlikeRequired'] == false &&
                value['licenseUrl'] == 'https://data.gov.tw/license')) ||
        !_publicAttributionUrl(value['attributionUrl'])) {
      throw const FormatException('Invalid EPG data attribution');
    }
    return ServerEpgAttribution._(Map.unmodifiable(value));
  }
}

bool _publicAttributionUrl(Object? value) {
  if (!_text(value, 2048)) return false;
  final uri = Uri.tryParse(value as String);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.userInfo.isNotEmpty ||
      uri.hasPort ||
      uri.hasFragment ||
      !uri.host.contains('.') ||
      uri.host.endsWith('.local') ||
      uri.host.endsWith('.localhost') ||
      InternetAddress.tryParse(uri.host) != null) {
    return false;
  }
  return true;
}

/// Runs in a background isolate. Both compressed and expanded sizes are bounded.
Future<ServerEpgSnapshot> decodeServerEpg(Map<String, Object> message) async {
  final bytes = message['bytes'] as List<int>;
  final manifest = ServerEpgManifest.parse(message['manifest'])!;
  final now = message['nowUtc'] as int;
  if (bytes.length != manifest.compressedBytes ||
      sha256.convert(bytes).toString() != manifest.sha256) {
    throw const FormatException('EPG checksum mismatch');
  }
  if (manifest.coverageEndUtc <= now ||
      manifest.generatedAt.millisecondsSinceEpoch ~/ 1000 > now + 300) {
    throw const FormatException('Stale or future-dated EPG manifest');
  }
  final raw = <int>[];
  await for (final part in gzip.decoder.bind(Stream.value(bytes))) {
    if (raw.length + part.length > 32 * 1024 * 1024) {
      throw const FormatException('Expanded EPG exceeds limit');
    }
    raw.addAll(part);
  }
  final payload = jsonDecode(utf8.decode(raw));
  if (payload is! Map ||
      payload['schemaVersion'] != 1 ||
      payload['version'] != manifest.version ||
      payload['channels'] is! List ||
      payload['programmes'] is! List ||
      (payload['channels'] as List).length != manifest.channelCount ||
      (payload['programmes'] as List).length != manifest.programmeCount) {
    throw const FormatException('Invalid EPG snapshot envelope');
  }
  final identities = <String, Map<String, dynamic>>{};
  final channels = <EpgChannel>[];
  for (final channel in payload['channels'] as List) {
    if (channel is! Map<String, dynamic> ||
        !_text(channel['id'], 256) ||
        !_text(channel['name'], 256) ||
        !_text(channel['sourceId'], 128) ||
        !_text(channel['originalChannelId'], 256) ||
        channel['catalogIdentityHash'] is! String ||
        !_digest.hasMatch(channel['catalogIdentityHash'] as String) ||
        channel['confidence'] is! num ||
        !(channel['confidence'] as num).isFinite ||
        (channel['confidence'] as num) < .95 ||
        (channel['confidence'] as num) > 1 ||
        identities.containsKey(channel['id'])) {
      throw const FormatException('Invalid or duplicate EPG identity');
    }
    final id = channel['id'] as String;
    if (catalogEpgIdentityHash(channel) != channel['catalogIdentityHash']) {
      throw const FormatException('EPG catalog identity fingerprint mismatch');
    }
    identities[id] = Map.unmodifiable(channel);
    channels.add(
      EpgChannel(
        id: id,
        sourceId: serverEpgSourceId,
        displayNames: [channel['name'] as String],
      ),
    );
  }
  final attributionRows = payload.containsKey('dataAttributions')
      ? payload['dataAttributions']
      : const [];
  if (attributionRows is! List || attributionRows.length > 256) {
    throw const FormatException('Invalid EPG attribution list');
  }
  final sources = identities.values.map((v) => v['sourceId']).toSet();
  final attributions = <String, ServerEpgAttribution>{};
  for (final raw in attributionRows) {
    final credit = ServerEpgAttribution.parse(raw);
    if (!sources.contains(credit.sourceId) ||
        attributions.containsKey(credit.sourceId)) {
      throw const FormatException('Duplicate or unrelated EPG attribution');
    }
    attributions[credit.sourceId] = credit;
  }
  final programmes = <EpgProgramme>[];
  final byChannel = <String, List<EpgProgramme>>{};
  var minStart = 4102444800, maxStop = 0;
  for (final item in payload['programmes'] as List) {
    final identity = item is Map ? identities[item['channelId']] : null;
    if (item is! Map ||
        identity == null ||
        item['sourceId'] != identity['sourceId'] ||
        item['originalChannelId'] != identity['originalChannelId'] ||
        !_text(item['title'], 512) ||
        item['startUtc'] is! int ||
        item['stopUtc'] is! int ||
        item['provenance'] is! Map) {
      throw const FormatException('Invalid EPG programme identity');
    }
    final dataLicense = (item['provenance'] as Map)['dataLicense'];
    final credit = attributions[item['sourceId']];
    if (((dataLicense == 'CC BY-SA 4.0' ||
                dataLicense == 'Open Government Data License 1.0') &&
            credit == null) ||
        (credit != null && dataLicense != credit.dataLicense) ||
        (dataLicense is String &&
            dataLicense.startsWith('CC BY-SA') &&
            dataLicense != 'CC BY-SA 4.0')) {
      throw const FormatException(
        'EPG programme attribution missing or mismatched',
      );
    }
    final start = item['startUtc'] as int, stop = item['stopUtc'] as int;
    if (start < 0 ||
        stop <= start ||
        stop - start > 86400 ||
        stop > 4102444800 ||
        start > now + 14 * 86400 ||
        stop < now - 2 * 86400) {
      throw const FormatException('Invalid EPG UTC interval');
    }
    final programme = EpgProgramme(
      channelId: item['channelId'] as String,
      sourceId: serverEpgSourceId,
      title: item['title'] as String,
      start: DateTime.fromMillisecondsSinceEpoch(start * 1000, isUtc: true),
      stop: DateTime.fromMillisecondsSinceEpoch(stop * 1000, isUtc: true),
    );
    (byChannel[programme.channelId] ??= []).add(programme);
    programmes.add(programme);
    if (start < minStart) minStart = start;
    if (stop > maxStop) maxStop = stop;
  }
  for (final id in identities.keys) {
    final rows = byChannel[id] ?? [];
    rows.sort((a, b) => a.start.compareTo(b.start));
    var hasNext = false;
    DateTime? previousStop;
    for (final row in rows) {
      if (previousStop != null && row.start.isBefore(previousStop)) {
        throw const FormatException('Overlapping or duplicate EPG programmes');
      }
      previousStop = row.stop;
      final start = row.start.millisecondsSinceEpoch ~/ 1000;
      hasNext |= start > now;
    }
    // An explicit source gap at now must not discard its real future entries.
    // Current-programme queries keep the gap empty; no placeholder is added.
    if (!hasNext) {
      throw const FormatException('EPG channel lacks future data');
    }
  }
  if (minStart != manifest.json['coverageStartUtc'] ||
      maxStop != manifest.coverageEndUtc) {
    throw const FormatException('EPG coverage mismatch');
  }
  return ServerEpgSnapshot(
    XmltvResult(channels: channels, programmes: programmes),
    Map.unmodifiable(identities),
    attributions: List.unmodifiable(attributions.values),
  );
}

bool _text(Object? value, int max) =>
    value is String &&
    value.trim().isNotEmpty &&
    value.length <= max &&
    !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value);
