import 'package:clubtivi/features/player/player_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Ultra HD quality policy', () {
    test('rejects upscaled Full HD', () {
      expect(
        PlayerService.isAcceptableUltraHdMedia(
          width: 1920,
          height: 1080,
          videoBitrate: 12000000,
        ),
        isFalse,
      );
    });

    test('rejects 4K dimensions with a low video bitrate', () {
      expect(
        PlayerService.isAcceptableUltraHdMedia(
          width: 3840,
          height: 2160,
          videoBitrate: 2000000,
        ),
        isFalse,
      );
    });

    test('accepts 4K dimensions with a sufficient video bitrate', () {
      expect(
        PlayerService.isAcceptableUltraHdMedia(
          width: 3840,
          height: 2160,
          videoBitrate: 12000000,
        ),
        isTrue,
      );
    });
  });
}
