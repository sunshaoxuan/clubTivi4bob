import 'dart:typed_data';

import 'package:clubtivi/features/player/player_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('recognizes a long-running identical frame', () {
    final pixels = Uint8List.fromList([
      for (var i = 0; i < 64 * 36; i++) ...[20, 40, 80, 255],
    ]);
    final first = PlayerService.frameFingerprint(pixels, 64, 36);
    final second = PlayerService.frameFingerprint(pixels, 64, 36);
    expect(PlayerService.framesAreNearlyIdentical(first, second), isTrue);
  });

  test('keeps moving television frames out of static detection', () {
    final firstPixels = Uint8List.fromList([
      for (var i = 0; i < 64 * 36; i++) ...[10, 20, 30, 255],
    ]);
    final secondPixels = Uint8List.fromList([
      for (var i = 0; i < 64 * 36; i++) ...[
        i % 255,
        (i * 3) % 255,
        (i * 7) % 255,
        255,
      ],
    ]);
    final first = PlayerService.frameFingerprint(firstPixels, 64, 36);
    final second = PlayerService.frameFingerprint(secondPixels, 64, 36);
    expect(PlayerService.framesAreNearlyIdentical(first, second), isFalse);
  });
}
