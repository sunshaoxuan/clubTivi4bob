import 'dart:async';

import 'package:clubtivi/features/player/offline_asr_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const request = (pcmPath: 'window.pcm', audioLocale: 'ja-JP');

  test(
    'QA Mandarin and Cantonese routes never guess from a Chinese region',
    () {
      expect(cjkQaAudioLocale('cmn-Hans-CN'), 'zh-CN');
      expect(cjkQaAudioLocale('yue_HK'), 'yue-HK');
      expect(cjkQaAudioLocale('zh-HK'), isNull);
      expect(isUnspecifiedChineseSpeech('zh-HK'), isTrue);
      expect(isUnspecifiedChineseSpeech('chi'), isTrue);
      expect(isUnspecifiedChineseSpeech('en-GB'), isFalse);
    },
  );

  test(
    'uses system recognition and treats confirmed silence as success',
    () async {
      final words = await recognizeOffline<List<String>>(
        request,
        system: (input) async {
          expect(input, request);
          return [];
        },
        whisper: (_) async => throw StateError('unexpected fallback'),
        isCurrent: () => true,
      );
      expect(words, isEmpty);
    },
  );

  test('falls back with the same PCM and audio locale', () async {
    final calls = <String>[];
    final result = await recognizeOffline<String>(
      request,
      system: (input) async {
        expect(input, request);
        calls.add('system');
        return null;
      },
      whisper: (input) async {
        expect(input, request);
        calls.add('whisper');
        return '日本語';
      },
      isCurrent: () => true,
    );
    expect(calls, ['system', 'whisper']);
    expect(result, '日本語');
  });

  test('unknown audio language goes to multilingual detection', () async {
    final result = await recognizeOffline<String>(
      (pcmPath: 'window.pcm', audioLocale: null),
      system: (_) async => throw StateError('system locale is unknown'),
      whisper: (input) async {
        expect(input.audioLocale, isNull);
        return 'fr';
      },
      isCurrent: () => true,
    );
    expect(result, 'fr');
  });

  test(
    'invalidated playback window cannot trigger fallback or return text',
    () async {
      final gate = Completer<String?>();
      var active = true;
      final pending = recognizeOffline<String>(
        request,
        system: (_) => gate.future,
        whisper: (_) async => throw StateError('stale window reached fallback'),
        isCurrent: () => active,
      );
      active = false;
      gate.complete(null);
      expect(await pending, isNull);

      active = true;
      expect(
        await recognizeOffline<String>(
          request,
          system: (_) async => null,
          whisper: (_) async {
            active = false;
            return 'stale transcript';
          },
          isCurrent: () => active,
        ),
        isNull,
      );
    },
  );
}
