import 'package:clubtivi/features/player/ios_native_media.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('movie handoff preserves position before duration metadata arrives', () {
    expect(
      iosNeedsLiveReopen('http://localhost/movie.mp4', Duration.zero),
      isFalse,
    );
    expect(
      iosNeedsLiveReopen(
        'https://example.test/Movie.M4V?token=abc|User-Agent=BobTV',
        Duration.zero,
      ),
      isFalse,
    );
    expect(
      iosNeedsLiveReopen(
        'https://example.test/a.mov',
        const Duration(seconds: 30),
      ),
      isFalse,
    );
  });
  test('unknown live duration reopens at the current live edge', () {
    expect(
      iosNeedsLiveReopen('https://example.test/live.m3u8', Duration.zero),
      isTrue,
    );
    expect(
      iosNeedsLiveReopen(
        'https://example.test/live.ts',
        const Duration(seconds: 30),
      ),
      isTrue,
    );
    expect(
      iosNeedsLiveReopen(
        'https://example.test/movie.m3u8',
        const Duration(hours: 1),
      ),
      isFalse,
    );
  });
}
