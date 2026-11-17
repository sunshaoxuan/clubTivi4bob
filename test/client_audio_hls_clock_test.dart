import 'package:flutter_test/flutter_test.dart';
import 'package:clubtivi/features/player/hls_buffer_proxy.dart';

void main() {
  test('old sessions bootstrap the verified current UK AES configuration', () {
    const old =
        'https://action-rakuten-tv-uk.fast.rakuten.tv/v1/manifest/0547f18649bd788bec7b67b746e47670f558b6b2/production-LiveChannel-6065/expired/4.m3u8';
    final master = currentActionMoviesMaster(old);
    expect(
      master.path,
      endsWith('/production-hls-aes128-rtv-6065-playout/master.m3u8'),
    );
    expect(isActionMoviesUk(master.toString()), isTrue);
    expect(
      isActionMoviesUk(master.toString().replaceAll('6065', '6066')),
      isFalse,
    );
    expect(
      () => currentActionMoviesMaster(old.replaceAll('-uk.fast', '-de.fast')),
      throwsFormatException,
    );
  });
  test(
    'balanced live selection leaves bandwidth headroom and safely falls back',
    () {
      final master = currentActionMoviesMaster(
        'https://action-rakuten-tv-uk.fast.rakuten.tv/v1/master/key/production-LiveChannel-6065/master.m3u8',
      );
      final body =
          '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=4935626\n../../../manifest/key/production-hls-aes128-rtv-6065-playout/session/4.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=2849771\n../../../manifest/key/production-hls-aes128-rtv-6065-playout/session/3.m3u8\n';
      expect(selectActionMoviesMedia(body, master).path, endsWith('/3.m3u8'));
      expect(
        selectActionMoviesMedia(body, master, maxBandwidth: 5000000).path,
        endsWith('/4.m3u8'),
      );
      expect(
        selectActionMoviesMedia(body, master, maxBandwidth: 1).path,
        endsWith('/3.m3u8'),
      );
    },
  );
  final origin = Uri.parse(
    'https://action-rakuten-tv-uk.fast.rakuten.tv/live/playlist.m3u8',
  );
  test(
    'clock follows requested media, short adverts and sliding manifests',
    () {
      final proxy = HlsBufferProxy(captureClock: true);
      final body = proxy.indexSegments(
        '''#EXTM3U
#EXT-X-MEDIA-SEQUENCE:100
#EXTINF:6,epid=movie:ct=m
movie/media-100.ts
#EXTINF:6,epid=movie:ct=m
movie/media-101.ts
#EXTINF:1,advert
advert/media-102.ts
''',
        origin,
        (key) => 'http://127.0.0.1:1234$key',
      );
      expect(body, contains('http://127.0.0.1:1234/segment/101.ts'));
      expect(proxy.segmentAt(0), isNull);
      proxy.beginSegment('/segment/101.ts');
      expect(proxy.segmentAt(0)!.movieId, 'movie');
      expect(proxy.segmentAt(0)!.start, 0);
      expect(proxy.segmentAt(6)!.start, 6);
      expect(proxy.segmentAt(5.99)!.ad, isFalse);
      expect(proxy.segmentAt(6)!.ad, isTrue);
      proxy.indexSegments(
        '''#EXTM3U
#EXT-X-MEDIA-SEQUENCE:102
#EXTINF:1,advert
advert/media-102.ts
#EXTINF:6,epid=movie:ct=m
movie/media-103.ts
''',
        origin,
        (key) => key,
      );
      expect(proxy.segmentAt(6.99)!.ad, isTrue);
      expect(proxy.segmentAt(7)!.ad, isFalse);
      expect(proxy.segmentAt(7)!.sequence, 103);
      expect(proxy.segmentAt(13), isNull);
    },
  );
  test('unknown programme markers keep movie captions suspended', () {
    final proxy = HlsBufferProxy(captureClock: true);
    proxy.indexSegments(
      '''#EXTM3U
#EXT-X-MEDIA-SEQUENCE:1
#EXTINF:6,
unknown/media-1.ts
''',
      origin,
      (key) => key,
    );
    proxy.beginSegment('/segment/1.ts');
    expect(proxy.segmentAt(1)!.ad, isTrue);
  });
}
