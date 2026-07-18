/// Normalizes IPTV channel names so equivalent entries from different
/// playlists can be grouped safely.
///
/// The original matching logic was ASCII-oriented. In Dart, `\w` does not
/// retain CJK characters, so Chinese channel names could collapse to an empty
/// key. This normalizer keeps CJK text and removes only common quality and
/// source labels.
class ChannelNameNormalizer {
  static const _cctvAliases = <String, String>{
    'cctv综合': 'cctv1',
    'cctv财经': 'cctv2',
    'cctv综艺': 'cctv3',
    'cctv体育': 'cctv5',
    'cctv体育赛事': 'cctv5plus',
    'cctv电影': 'cctv6',
    'cctv国防军事': 'cctv7',
    'cctv电视剧': 'cctv8',
    'cctv纪录': 'cctv9',
    'cctv科教': 'cctv10',
    'cctv戏曲': 'cctv11',
    'cctv社会与法': 'cctv12',
    'cctv新闻': 'cctv13',
    'cctv少儿': 'cctv14',
    'cctv音乐': 'cctv15',
    'cctv奥林匹克': 'cctv16',
    'cctv农业农村': 'cctv17',
  };

  static const _chineseDigits = <String, String>{
    '十七': '17',
    '十六': '16',
    '十五': '15',
    '十四': '14',
    '十三': '13',
    '十二': '12',
    '十一': '11',
    '十': '10',
    '零': '0',
    '一': '1',
    '二': '2',
    '两': '2',
    '三': '3',
    '四': '4',
    '五': '5',
    '六': '6',
    '七': '7',
    '八': '8',
    '九': '9',
  };

  static String normalize(String name) {
    var value = _toHalfWidth(name).toLowerCase();

    value = value
        .replaceAll('中国中央电视台', 'cctv')
        .replaceAll('中央电视台', 'cctv')
        .replaceAll('央视', 'cctv')
        .replaceAll('+', ' plus ');

    for (final entry in _chineseDigits.entries) {
      value = value.replaceAllMapped(
        RegExp('cctv\\s*${entry.key}(?=\\s|[频套台]|\$)'),
        (_) => 'cctv${entry.value}',
      );
    }

    // Quality, codec and resolution labels do not identify the programme.
    value = value.replaceAll(
      RegExp(
        r'(?<![a-z0-9])(hd|fhd|shd|sd|uhd|4k|8k|hevc|h\.?26[45]|av1|50fps|60fps)(?![a-z0-9])',
        caseSensitive: false,
      ),
      ' ',
    );
    value = value.replaceAll(RegExp(r'(超高清|全高清|高清|标清|蓝光|流畅|原画|高码率|低码率)'), ' ');

    // Provider and route labels are frequently appended to otherwise equal
    // channel names in public and private M3U playlists.
    value = value.replaceAll(
      RegExp(
        r'(?<![a-z0-9])(ipv4|ipv6|udp|http|https|hls|p2p|backup|bak)(?![a-z0-9])',
        caseSensitive: false,
      ),
      ' ',
    );
    value = value.replaceAll(
      RegExp(r'(备用|备份|镜像|测试|组播|单播|内网|酒店|电信|联通|移动|广电)'),
      ' ',
    );
    value = value.replaceAll(
      RegExp(r'(线路|线|源|节点|通道)\s*[a-z0-9一-十]*', caseSensitive: false),
      ' ',
    );

    // Keep letters, digits and CJK scripts. Convert punctuation to spaces so
    // English word matching remains useful.
    value = value
        .replaceAll(RegExp(r'[^a-z0-9㐀-䶿一-鿿぀-ヿ가-힯]+', unicode: true), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    var compact = value.replaceAll(' ', '');
    compact = _cctvAliases[compact] ?? compact;

    // CCTV descriptions are stable aliases for numbered services. CCTV-4
    // regional variants are retained because their schedules can differ.
    final cctv = RegExp(
      r'^cctv(\d{1,2})(plus)?(综合|财经|综艺|体育|体育赛事|电影|国防军事|电视剧|纪录|科教|戏曲|社会与法|新闻|少儿|音乐|奥林匹克|农业农村|频道|台|套)?$',
    ).firstMatch(compact);
    if (cctv != null && cctv.group(1) != '4') {
      return 'cctv${cctv.group(1)}${cctv.group(2) ?? ''}';
    }

    return compact;
  }

  /// Returns a strict service key for the two separate CCTV sports channels.
  /// This is also used as a guard when accepting EPG IDs supplied by playlists.
  static String? cctvSportsServiceKey(String name) {
    final normalized = normalize(name);
    if (normalized == 'cctv5plus') return 'cctv5plus';
    if (normalized == 'cctv5') return 'cctv5';

    final raw = _toHalfWidth(name).toLowerCase();
    if (RegExp(r'cctv\s*[-_]?\s*5\s*(\+|plus)').hasMatch(raw) ||
        raw.contains('体育赛事')) {
      return 'cctv5plus';
    }
    if (RegExp(r'cctv\s*[-_]?\s*5(?!\s*(\+|plus))').hasMatch(raw) ||
        raw.contains('cctv体育')) {
      return 'cctv5';
    }
    return null;
  }

  /// Whether playlist metadata explicitly advertises an Ultra HD stream.
  /// Kept separate from [normalize] because quality is ignored for channel
  /// identity but must be retained when choosing interchangeable routes.
  static bool isUltraHd(String name) {
    final value = _toHalfWidth(name).toLowerCase();
    return RegExp(
          r'(^|[^a-z0-9])(4k|uhd|2160p?)([^a-z0-9]|$)',
        ).hasMatch(value) ||
        value.contains('超高清') ||
        value.contains('超高畫質') ||
        value.contains('超高画质');
  }

  /// Infers the CCTV sports service from common stream URL route names.
  /// Several public playlists contain correct-looking channel metadata while
  /// the route itself points at `cctv5p`, the usual CCTV5 Plus identifier.
  static String? cctvSportsServiceKeyFromStreamUrl(String url) {
    var value = _toHalfWidth(url).toLowerCase();
    try {
      value = Uri.decodeComponent(value);
    } catch (_) {}
    final boundary = r'(^|[/?&=._-])';
    final ending = r'(?=$|[/?&=._-])';
    if (RegExp(
      '$boundary'
      r'cctv[-_]?5(?:plus|p)'
      '$ending',
    ).hasMatch(value)) {
      return 'cctv5plus';
    }
    if (RegExp(
      '$boundary'
      r'cctv[-_]?5(?:hd)?'
      '$ending',
    ).hasMatch(value)) {
      return 'cctv5';
    }
    return null;
  }

  static bool hasCctvSportsMetadataConflict({
    required Iterable<String> names,
    required String streamUrl,
  }) {
    String? metadataService;
    for (final name in names) {
      metadataService ??= cctvSportsServiceKey(name);
    }
    final routeService = cctvSportsServiceKeyFromStreamUrl(streamUrl);
    return metadataService != null &&
        routeService != null &&
        metadataService != routeService;
  }

  /// Rejects labels that claim UHD while also declaring a lower resolution or
  /// a clearly sub-UHD bitrate in the route path.
  static bool hasUltraHdMetadataConflict({
    required Iterable<String> names,
    required String streamUrl,
  }) {
    if (!names.any(isUltraHd)) return false;
    final joined = names
        .map((name) => _toHalfWidth(name).toLowerCase())
        .join(' ');
    if (RegExp(
      r'(^|[^0-9])(480|576|720|1080)[pi]?([^0-9]|$)',
    ).hasMatch(joined)) {
      return true;
    }
    final bitrateMatch = RegExp(
      r'(^|[/_.-])(\d{3,5})k(?=$|[/_.-])',
      caseSensitive: false,
    ).firstMatch(streamUrl);
    final bitrateKbps = int.tryParse(bitrateMatch?.group(2) ?? '');
    return bitrateKbps != null && bitrateKbps < 8000;
  }

  static String _toHalfWidth(String input) {
    final output = StringBuffer();
    for (final rune in input.runes) {
      if (rune == 0x3000) {
        output.write(' ');
      } else if (rune >= 0xff01 && rune <= 0xff5e) {
        output.writeCharCode(rune - 0xfee0);
      } else {
        output.writeCharCode(rune);
      }
    }
    return output.toString();
  }
}
