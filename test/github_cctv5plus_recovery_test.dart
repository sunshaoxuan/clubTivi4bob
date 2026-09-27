import 'package:clubtivi/data/services/github_cctv5plus_recovery.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('extracts only distinct public CCTV5+ routes', () {
    final candidates = GitHubCctv5PlusRecovery.extractCandidates('''
CCTV5,http://example.com/cctv5.m3u8
CCTV5+,http://223.112.114.228:50080/newlive/live/hls/180/live.m3u8
CCTV-5+,http://223.112.114.228:50080/newlive/live/hls/180/live.m3u8
CCTV5+,http://127.0.0.1/live.m3u8
CCTV5+,http://192.168.1.2/live.m3u8
CCTV5+,https://example.com/live.m3u8?token=abc
''');
    expect(candidates, [
      'http://223.112.114.228:50080/newlive/live/hls/180/live.m3u8',
      'https://example.com/live.m3u8?token=abc',
    ]);
  });
}
