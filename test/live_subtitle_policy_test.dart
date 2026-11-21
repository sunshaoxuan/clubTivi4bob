import 'package:flutter_test/flutter_test.dart';
import 'package:clubtivi/core/i18n/app_language.dart';
import 'package:clubtivi/features/player/subtitle_policy.dart';
import 'package:clubtivi/features/player/live_subtitle_timeline.dart';

void main() {
  for (final language in AppLanguage.values) {
    test('${language.tag}: requested, English, none', () {
      String? choose(List<String> tracks) =>
          selectSubtitle(tracks, language.tag, language: (s) => s);
      expect(choose([language.tag, 'en']), language.tag);
      expect(choose(['de', 'en']), 'en');
      expect(choose(['de', 'und', 'zh']), isNull);
      expect(choose([]), isNull);
    });
  }
  test('ISO aliases and Chinese scripts stay distinct', () {
    expect(subtitleLanguage('ENG'), 'en');
    expect(subtitleLanguage('fre'), 'fr');
    expect(subtitleLanguage('zh_Hant_HK'), 'zh-TW');
    expect(subtitleLanguage('zh-Hans'), 'zh-CN');
    expect(subtitleLanguage('chi'), isNull);
    expect(
      selectSubtitle(['zh-TW', 'eng'], 'zh-CN', language: (s) => s),
      'zh-TW',
    );
    expect(
      selectSubtitle(
        ['ja', 'en'],
        'ja',
        language: (s) => s,
        usable: (s) => s != 'ja',
      ),
      'en',
    );
  });
  Map<String, dynamic> window(double start, double end, String state) => {
    'start': start,
    'end': end,
    'state': state,
    'program': 'film',
    'asset': 'verified-source',
    'tracks': [
      {
        'language': 'en',
        'verified': true,
        'cues': [
          {'start': start, 'end': end, 'text': 'English'},
        ],
      },
      {
        'language': 'zh-CN',
        'verified': true,
        'cues': [
          {'start': start, 'end': end, 'text': '中文'},
        ],
      },
    ],
  };
  LiveSubtitleTimeline decode(
    List<Map<String, dynamic>> windows, {
    String identity = 'a',
  }) => LiveSubtitleTimeline.decode(
    {'session': identity, 'source': 'route', 'windows': windows},
    session: 'a',
    source: 'route',
  );
  test(
    'playhead gates full advert and resumes exactly at returned picture',
    () {
      final timeline = decode([
        window(0, 5, 'LOCKED'),
        window(5, 155, 'SUSPENDED'),
        window(155, 180, 'LOCKED'),
      ]);
      expect(timeline.textAt(4.99, 'zh-CN'), '中文');
      for (var t = 5.0; t < 155; t += .05) {
        expect(timeline.textAt(t, 'zh-CN'), isEmpty);
      }
      expect(timeline.textAt(155, 'zh-CN'), '中文');
      expect(timeline.textAt(155, 'ko'), 'English');
      expect(timeline.textAt(190, 'zh-CN'), isEmpty);
      // A network-edge update never moves the buffered/paused playhead.
      expect(timeline.textAt(80, 'zh-CN'), isEmpty);
      expect(timeline.textAt(4, 'zh-CN'), '中文');
    },
  );
  test('unknown asset, acquisition and stale identities fail closed', () {
    final unknown = window(0, 5, 'LOCKED')..['asset'] = '';
    expect(decode([unknown]).textAt(1, 'en'), isEmpty);
    expect(decode([window(0, 5, 'ACQUIRING')]).textAt(1, 'en'), isEmpty);
    expect(
      () => decode([], identity: 'previous-channel'),
      throwsFormatException,
    );
    expect(
      () => decode([window(0, 5, 'LOCKED'), window(4, 8, 'LOCKED')]),
      throwsFormatException,
    );
  });
  test('malformed cue is rejected before a decoder callback renders it', () {
    final bad = window(0, 5, 'LOCKED');
    ((bad['tracks'] as List).first as Map)['cues'] = [
      {'start': 'bad', 'end': 5, 'text': 'wrong'},
    ];
    expect(() => decode([bad]), throwsFormatException);
  });
}
