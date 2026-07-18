import 'package:clubtivi/features/player/playback_stall_detector.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PlaybackStallDetector', () {
    test('keeps advancing playback healthy when cache is unavailable', () {
      final detector = PlaybackStallDetector();
      for (var i = 0; i < 5; i++) {
        final state = detector.add(
          PlaybackHealthSample(
            position: Duration(seconds: i * 2),
            cacheSeconds: null,
            buffering: false,
            playing: true,
          ),
        );
        expect(state.shouldFailover, isFalse);
      }
    });

    test('fails over when position freezes and cache disappears', () {
      final detector = PlaybackStallDetector();
      detector.add(
        const PlaybackHealthSample(
          position: Duration(seconds: 10),
          cacheSeconds: 3,
          buffering: false,
          playing: true,
        ),
      );
      PlaybackStallState? state;
      for (var i = 0; i < 4; i++) {
        state = detector.add(
          const PlaybackHealthSample(
            position: Duration(seconds: 10),
            cacheSeconds: null,
            buffering: false,
            playing: true,
          ),
        );
      }
      expect(state!.shouldFailover, isTrue);
    });

    test('fails over after sustained buffering', () {
      final detector = PlaybackStallDetector();
      PlaybackStallState? state;
      for (var i = 0; i < 3; i++) {
        state = detector.add(
          const PlaybackHealthSample(
            position: Duration.zero,
            cacheSeconds: 0,
            buffering: true,
            playing: false,
          ),
        );
      }
      expect(state!.shouldWarmAlternative, isTrue);
      expect(state.shouldFailover, isTrue);
    });

    test('resets stress after playback recovers', () {
      final detector = PlaybackStallDetector();
      detector.add(
        const PlaybackHealthSample(
          position: Duration.zero,
          cacheSeconds: 0,
          buffering: true,
          playing: false,
        ),
      );
      final recovered = detector.add(
        const PlaybackHealthSample(
          position: Duration(seconds: 2),
          cacheSeconds: 5,
          buffering: false,
          playing: true,
        ),
      );
      expect(recovered.healthy, isTrue);
    });
  });
}
