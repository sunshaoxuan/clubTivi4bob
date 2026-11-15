import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:clubtivi/features/player/hls_buffer_proxy.dart';

void main() {
  test(
    'letterbox, pillarbox, moved preview and grid remain picture-relative',
    () {
      expect(
        subtitleViewportRect(
          const Size(800, 600),
          const Size(1920, 1080),
          BoxFit.contain,
          Alignment.center,
        ),
        const Rect.fromLTWH(0, 75, 800, 450),
      );
      expect(
        subtitleViewportRect(
          const Size(800, 450),
          const Size(640, 480),
          BoxFit.contain,
          Alignment.center,
        ),
        const Rect.fromLTWH(100, 0, 600, 450),
      );
      expect(
        subtitleViewportRect(
          const Size(320, 240),
          const Size(1920, 1080),
          BoxFit.contain,
          Alignment.topLeft,
        ),
        const Rect.fromLTWH(0, 0, 320, 180),
      );
      expect(
        subtitleViewportRect(
          const Size(320, 240),
          const Size(1920, 1080),
          BoxFit.cover,
          Alignment.center,
        ),
        const Rect.fromLTWH(0, 0, 320, 240),
      );
      expect(
        subtitleViewportRect(
          Size.zero,
          const Size(1920, 1080),
          BoxFit.contain,
          Alignment.center,
        ),
        Rect.zero,
      );
    },
  );
  test('live holdback uses elapsed seconds across short advert segments', () {
    final body =
        '#EXTM3U\n#EXT-X-TARGETDURATION:6\n'
        '#EXT-X-MEDIA-SEQUENCE:200\n#EXT-X-CUE-OUT:30\n'
        '#EXT-X-KEY:METHOD=AES-128,URI="../key.bin"\n'
        '${List.generate(30, (i) => '#EXTINF:1,\n$i.ts').join('\n')}\n';
    final result = rewriteBufferedHls(
      body,
      Uri.parse('https://example.com/a/4.m3u8'),
      (uri) => 'http://localhost/playlist',
    );
    expect(result, contains('TIME-OFFSET=-24.0'));
    expect(result, contains('#EXT-X-CUE-OUT:30'));
    expect(result, contains('URI="https://example.com/key.bin"'));
    expect(result, contains('https://example.com/a/0.ts'));
    expect(result, contains('#EXT-X-MEDIA-SEQUENCE:200'));
    expect(
      rewriteBufferedHls(
        '$body#EXT-X-ENDLIST\n',
        Uri.parse('https://example.com/a/4.m3u8'),
        (uri) => '',
      ),
      isNot(contains('#EXT-X-START')),
    );
  });
}
