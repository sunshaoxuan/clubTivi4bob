import 'package:clubtivi/features/player/player_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  bool ready({
    bool playing = true,
    bool buffering = false,
    bool video = true,
    bool audio = true,
    int width = 1920,
    int height = 1080,
    bool advanced = true,
    bool radio = false,
  }) => PlayerService.preparedMediaReady(
        playing: playing,
        buffering: buffering,
        hasVideoTrack: video,
        hasAudioTrack: audio,
        width: width,
        height: height,
        advanced: advanced,
        allowAudioOnly: radio,
      );

  test('video needs decoded dimensions and advancing playback', () {
    expect(ready(), isTrue);
    expect(ready(width: 0), isFalse);
    expect(ready(height: 0), isFalse);
    expect(ready(advanced: false), isFalse);
    expect(ready(buffering: true), isFalse);
    expect(ready(playing: false), isFalse);
    expect(ready(video: false), isFalse);
  });

  test('radio accepts progressing audio without video', () {
    expect(ready(radio: true, video: false, width: 0, height: 0), isTrue);
    expect(ready(radio: true, video: false, audio: false), isFalse);
  });
}
