import 'dart:convert';
import 'dart:io';

const _assetPath = 'assets/data/github_ai_snapshot.json.gz';
const _generatedAt = '2026-07-19T15:33:27Z';
const _snapshotId = 'hotel-tv-20260719T153327Z';

const _sources = <Map<String, Object?>>[
  {
    'name': 'CCTV5 4K',
    'streamUrl':
        'http://[2409:8087:2001:20:2800:0:df6e:eb22]/ott.mobaibox.com/PLTV/4/224/3221228502/index.m3u8',
    'githubOwner': 'qist',
    'githubRepo': 'tvbox',
    'githubRef': '1ac041519585848188ac851eede6a90d8c24e19a',
    'githubPath': 'list.m3u',
    'sourceDocumentUrl': 'https://github.com/qist/tvbox/blob/master/list.m3u',
  },
  {
    'name': 'CCTV5 4K',
    'streamUrl': 'http://ott.mobaibox.com/PLTV/4/224/3221228502/index.m3u8',
    'githubOwner': 'sqrsus',
    'githubRepo': 'tv',
    'githubRef': 'ee6bfc02027522ca66625aef21b7b9af92fccdee',
    'githubPath': 'tv.m3u',
    'sourceDocumentUrl': 'https://github.com/sqrsus/tv/blob/main/tv.m3u',
  },
  {
    'name': 'CCTV5 4K',
    'streamUrl': 'http://148.135.93.213:81/live.php?id=CCTV5-4K',
    'githubOwner': 'cnmeeia',
    'githubRepo': '4K_IPTV',
    'githubRef': '8f9e8eda9eea9b695002a58f01fbccee819b5b26',
    'githubPath': '4K.m3u',
    'sourceDocumentUrl': 'https://github.com/cnmeeia/4K_IPTV/blob/main/4K.m3u',
  },
  {
    'name': 'CCTV5 4K',
    'streamUrl': 'http://119.98.177.131:4000/rtp/239.69.1.12:9712',
    'githubOwner': '977567941',
    'githubRepo': '-',
    'githubRef': 'c97c064ec77a08d95f11ba1178a48e27200210dd',
    'githubPath': '结果.txt',
    'sourceDocumentUrl': 'https://github.com/977567941/-/blob/main/结果.txt',
  },
  {
    'name': 'CCTV5 4K',
    'streamUrl': 'http://171.80.228.240:4000/rtp/239.69.1.12:9712',
    'githubOwner': '977567941',
    'githubRepo': '-',
    'githubRef': 'c97c064ec77a08d95f11ba1178a48e27200210dd',
    'githubPath': '结果.txt',
    'sourceDocumentUrl': 'https://github.com/977567941/-/blob/main/结果.txt',
  },
  {
    'name': 'CCTV5 4K',
    'streamUrl': 'http://27.19.213.7:4022/rtp/239.69.1.12:9712',
    'githubOwner': '977567941',
    'githubRepo': '-',
    'githubRef': 'c97c064ec77a08d95f11ba1178a48e27200210dd',
    'githubPath': '结果.txt',
    'sourceDocumentUrl': 'https://github.com/977567941/-/blob/main/结果.txt',
  },
  {
    'name': 'CCTV5 4K',
    'streamUrl': 'http://27.25.77.223:4000/rtp/239.69.1.12:9712',
    'githubOwner': '977567941',
    'githubRepo': '-',
    'githubRef': 'c97c064ec77a08d95f11ba1178a48e27200210dd',
    'githubPath': '结果.txt',
    'sourceDocumentUrl': 'https://github.com/977567941/-/blob/main/结果.txt',
  },
  {
    'name': 'CCTV5 4K',
    'streamUrl': 'http://59.173.122.26:10001/rtp/239.69.1.12:9712',
    'githubOwner': 'iodata999',
    'githubRepo': 'frxz751113-IPTVzb1',
    'githubRef': '42903eda8190dfaf69a931cd01beb9f3671aeaac',
    'githubPath': '湖北电信.txt',
    'sourceDocumentUrl':
        'https://github.com/iodata999/frxz751113-IPTVzb1/blob/main/湖北电信.txt',
  },
  {
    'name': 'CCTV5 4K',
    'streamUrl': 'http://59.173.123.163:19999/rtp/239.69.1.12:9712',
    'githubOwner': 'iodata999',
    'githubRepo': 'frxz751113-IPTVzb1',
    'githubRef': '42903eda8190dfaf69a931cd01beb9f3671aeaac',
    'githubPath': '湖北电信.txt',
    'sourceDocumentUrl':
        'https://github.com/iodata999/frxz751113-IPTVzb1/blob/main/湖北电信.txt',
  },
  {
    'name': 'CCTV5 4K',
    'streamUrl':
        'http://cqshushu.us.kg:2086/公众号【医工学习日志】/jiangsu.php?id=cctv5avs',
    'githubOwner': 'hc0768',
    'githubRepo': 'A',
    'githubRef': 'c20a4580ed8383d6b83dec959fee09db6605e71e',
    'githubPath': '1',
    'sourceDocumentUrl': 'https://github.com/hc0768/A/blob/main/1',
  },
];

void main() {
  final file = File(_assetPath);
  final decoded = jsonDecode(utf8.decode(gzip.decode(file.readAsBytesSync())));
  if (decoded is! Map<String, dynamic> || decoded['channels'] is! List) {
    throw const FormatException('Unexpected bundled source snapshot format');
  }

  final channels = (decoded['channels'] as List).cast<Map<String, dynamic>>();
  final existingByUrl = <String, Map<String, dynamic>>{
    for (final channel in channels)
      if (_normalizeUrl(channel['streamUrl']?.toString() ?? '').isNotEmpty)
        _normalizeUrl(channel['streamUrl']?.toString() ?? ''): channel,
  };
  var added = 0;
  var updated = 0;

  for (final source in _sources) {
    final url = source['streamUrl']! as String;
    final owner = source['githubOwner']! as String;
    final repo = source['githubRepo']! as String;
    final path = source['githubPath']! as String;
    final name = source['name']! as String;
    final channel = {
      'id': _discoveredChannelId(owner, repo, path, name, url),
      ...source,
      'tvgId': 'CCTV5',
      'tvgName': name,
      'tvgLogo': 'https://live.fanmingming.com/tv/CCTV5.png',
      'groupTitle': 'CCTV5 4K',
      'channelNumber': null,
      'confidence': 0.25,
    };
    final normalizedUrl = _normalizeUrl(url);
    final existing = existingByUrl[normalizedUrl];
    if (existing == null) {
      channels.add(channel);
      existingByUrl[normalizedUrl] = channel;
      added++;
    } else {
      existing
        ..clear()
        ..addAll(channel);
      updated++;
    }
  }

  decoded['snapshotId'] = _snapshotId;
  decoded['generatedAt'] = _generatedAt;
  decoded['count'] = channels.length;
  file.writeAsBytesSync(gzip.encode(utf8.encode(jsonEncode(decoded))));
  stdout.writeln(
    'Added $added and updated $updated unique CCTV5 4K routes; total ${channels.length}.',
  );
}

String _normalizeUrl(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null) return value.trim();
  final normalized = uri.replace(
    scheme: uri.scheme.toLowerCase(),
    host: uri.host.toLowerCase(),
    fragment: '',
  );
  return normalized.toString();
}

String _discoveredChannelId(
  String owner,
  String repo,
  String path,
  String name,
  String url,
) {
  final identity = '$owner/$repo/$path\u0000$name\u0000$url';
  var hash = 0x811c9dc5;
  for (final byte in utf8.encode(identity)) {
    hash ^= byte;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return 'github-ai-crawler_${hash.toRadixString(16).padLeft(8, '0')}';
}
