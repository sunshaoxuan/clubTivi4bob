import 'package:clubtivi/features/player/player_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Television video readiness policy', () {
    test('rejects an audio only route', () {
      expect(
        PlayerService.isUsableTelevisionVideo(
          hasVideoTrack: false,
          width: 0,
          height: 0,
        ),
        isFalse,
      );
    });

    test('waits for decoded video dimensions', () {
      expect(
        PlayerService.isUsableTelevisionVideo(
          hasVideoTrack: true,
          width: 0,
          height: 0,
        ),
        isFalse,
      );
    });

    test('accepts a decoded television picture', () {
      expect(
        PlayerService.isUsableTelevisionVideo(
          hasVideoTrack: true,
          width: 1920,
          height: 1080,
        ),
        isTrue,
      );
    });

    test('accepts an audio track for a radio channel', () {
      expect(
        PlayerService.isUsablePlaybackMedia(
          hasVideoTrack: false,
          hasAudioTrack: true,
          width: 0,
          height: 0,
          allowAudioOnly: true,
        ),
        isTrue,
      );
    });

    test('keeps rejecting audio-only media for a television channel', () {
      expect(
        PlayerService.isUsablePlaybackMedia(
          hasVideoTrack: false,
          hasAudioTrack: true,
          width: 0,
          height: 0,
          allowAudioOnly: false,
        ),
        isFalse,
      );
    });
  });
}
