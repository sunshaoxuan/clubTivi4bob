import 'package:flutter_test/flutter_test.dart';
import 'package:clubtivi/features/player/hls_playlist_history.dart';

final origin = Uri.parse('https://media.example/live/playlist.m3u8');
String playlist(
  int start,
  int count,
  double duration, {
  String tags = '',
  String prefix = 'media',
}) =>
    '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:${duration.ceil()}\n#EXT-X-MEDIA-SEQUENCE:$start\n$tags${List.generate(count, (i) => '#EXTINF:$duration,\n$prefix-${start + i}.ts\n').join()}';
List<int> sequences(String body) {
  final first = int.parse(
    RegExp(r'#EXT-X-MEDIA-SEQUENCE:(\d+)').firstMatch(body)![1]!,
  );
  final count = RegExp(r'#EXTINF:').allMatches(body).length;
  return List.generate(count, (i) => first + i);
}

void main() {
  test(
    'a six-segment advert window retains prior movie media and continuous sequence',
    () {
      final history = HlsPlaylistHistory();
      history.update(playlist(100, 6, 6), origin);
      final body = history.update(
        playlist(106, 6, 1, prefix: 'advert'),
        origin,
      );
      expect(sequences(body), List.generate(12, (i) => 100 + i));
      expect(body, contains('#EXT-X-TARGETDURATION:6'));
      expect(body, contains('https://media.example/live/media-100.ts'));
      expect(body, contains('https://media.example/live/advert-111.ts'));
    },
  );
  test(
    'long adverts keep a bounded duration instead of a fixed segment count',
    () {
      final history = HlsPlaylistHistory(seconds: 40);
      history.update(playlist(100, 6, 6), origin);
      var body = '';
      for (var first = 106; first <= 220; first++) {
        body = history.update(playlist(first, 6, 1, prefix: 'advert'), origin);
      }
      expect(sequences(body), List.generate(40, (i) => 186 + i));
      expect(body, contains('#EXT-X-TARGETDURATION:1'));
    },
  );
  test('encryption keys and discontinuities stay with the original segments', () {
    final history = HlsPlaylistHistory();
    history.update(
      playlist(100, 6, 6, tags: '#EXT-X-KEY:METHOD=AES-128,URI="old.key"\n'),
      origin,
    );
    history.update(
      playlist(
        106,
        6,
        1,
        tags: '#EXT-X-KEY:METHOD=NONE\n#EXT-X-DISCONTINUITY\n',
        prefix: 'advert',
      ),
      origin,
    );
    final body = history.update(
      playlist(
        112,
        6,
        6,
        tags:
            '#EXT-X-DISCONTINUITY-SEQUENCE:1\n#EXT-X-DISCONTINUITY\n#EXT-X-KEY:METHOD=AES-128,URI="new.key",IV=0x1234\n',
      ),
      origin,
    );
    expect(body, contains('URI="https://media.example/live/old.key"'));
    expect(body, contains('#EXT-X-KEY:METHOD=NONE'));
    expect(
      body,
      contains('URI="https://media.example/live/new.key",IV=0x1234'),
    );
    expect(
      RegExp(
        r'^#EXT-X-DISCONTINUITY$',
        multiLine: true,
      ).allMatches(body).length,
      2,
    );
    final refreshed = history.update(
      playlist(
        113,
        5,
        6,
        tags:
            '#EXT-X-DISCONTINUITY-SEQUENCE:2\n#EXT-X-KEY:METHOD=AES-128,URI="new.key",IV=0x1234\n',
      ),
      origin,
    );
    expect(
      RegExp(
        r'^#EXT-X-DISCONTINUITY$',
        multiLine: true,
      ).allMatches(refreshed).length,
      2,
    );
  });
  test(
    'implicit byte ranges become explicit before their predecessor expires',
    () {
      final history = HlsPlaylistHistory(seconds: .5);
      final body = history.update(
        '#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:0\n#EXTINF:1,\n#EXT-X-BYTERANGE:100@5\nall.ts\n#EXTINF:1,\n#EXT-X-BYTERANGE:50\nall.ts\n',
        origin,
      );
      expect(sequences(body), [1]);
      expect(body, contains('#EXT-X-BYTERANGE:50@105'));
    },
  );
  test('missing unseen segments never become fabricated entries', () {
    final history = HlsPlaylistHistory();
    history.update(playlist(1, 6, 6), origin);
    final body = history.update(playlist(20, 6, 6), origin);
    expect(sequences(body), [20, 21, 22, 23, 24, 25]);
    expect(body, isNot(contains('media-6.ts')));
  });
  test('stale snapshots cannot retract newer observed media', () {
    final history = HlsPlaylistHistory();
    history.update(playlist(100, 6, 6), origin);
    history.update(playlist(106, 6, 1), origin);
    final body = history.update(playlist(100, 6, 6), origin);
    expect(sequences(body).last, 111);
  });
  test('completed media remains byte-for-byte original', () {
    final history = HlsPlaylistHistory();
    history.update(playlist(100, 6, 6), origin);
    final vod = '${playlist(0, 6, 6)}#EXT-X-ENDLIST\n';
    expect(history.update(vod, origin), vod);
  });
}
