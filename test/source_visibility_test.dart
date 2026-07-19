import 'package:clubtivi/data/services/source_visibility.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SourceVisibility', () {
    test('recognizes IPv6 playlist providers from metadata', () {
      expect(
        SourceVisibility.isIpv6Provider(
          id: 'hotel-guovin-ipv6',
          name: 'Guovin 混合线路',
          url: 'https://example.test/result.m3u',
        ),
        isTrue,
      );
      expect(
        SourceVisibility.isIpv6Provider(
          id: 'custom',
          name: '家庭 IPv6 源',
          url: null,
        ),
        isTrue,
      );
      expect(
        SourceVisibility.isIpv6Provider(
          id: 'hotel-guovin-ipv4',
          name: 'Guovin IPv4',
          url: 'https://example.test/ipv4.m3u',
        ),
        isFalse,
      );
    });

    test('recognizes IPv6 literal stream hosts', () {
      expect(
        SourceVisibility.isIpv6StreamUrl(
          'http://[2409:8087:1a0a:df::404b]/live/index.m3u8',
        ),
        isTrue,
      );
      expect(
        SourceVisibility.isIpv6StreamUrl(
          'http://39.135.133.134/live/index.m3u8',
        ),
        isFalse,
      );
    });
  });
}
