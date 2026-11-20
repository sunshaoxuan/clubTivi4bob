import 'dart:async';
import 'dart:convert';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:media_kit/media_kit.dart';
import 'package:clubtivi/core/i18n/app_language.dart';
import 'package:clubtivi/features/player/live_subtitle_session.dart';
import 'package:clubtivi/features/player/native_subtitle_selection.dart';
import 'package:clubtivi/features/player/subtitle_preferences.dart';
import 'package:clubtivi/features/player/subtitle_status.dart';

class _Streams extends Fake implements PlayerStream {
  @override
  Stream<Tracks> get tracks => const Stream.empty();
  @override
  Stream<Duration> get position => const Stream.empty();
  @override
  Stream<bool> get buffering => const Stream.empty();
  @override
  Stream<bool> get playing => const Stream.empty();
}

class _Player extends Fake implements Player {
  @override
  PlayerState state = const PlayerState(
    position: Duration(seconds: 1),
    playing: true,
  );
  @override
  PlayerStream stream = _Streams();
  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {}
}

Map<String, Object?> reply({
  bool ready = true,
  String phase = 'matched',
  bool cues = true,
}) => {
  'session': 'session',
  'source': 'channel',
  'playbackReady': ready,
  'playbackUrl': 'http://127.0.0.1/media',
  'subtitleStatus': {
    'phase': phase,
    'availableLanguages': phase == 'matched' ? ['en'] : [],
  },
  'windows': [
    {
      'start': 0,
      'end': 10,
      'state': 'LOCKED',
      'program': 'film',
      'asset': 'edition',
      'tracks': [
        {
          'language': 'en',
          'verified': true,
          'cues': cues
              ? [
                  {'start': 0, 'end': 10, 'text': 'Existing caption'},
                ]
              : [],
        },
      ],
    },
  ],
};
void main() {
  setUp(() {
    SubtitlePreferences.instance.initialize(null);
    SubtitlePreferences.instance.choose(AppLanguage.english);
  });
  test('recovered playback arms only the background caption callback', () {
    fakeAsync((clock) {
      final player = _Player();
      final selection = NativeSubtitleSelection(player);
      final session = LiveSubtitleSession(
        player,
        selection,
        client: MockClient((_) async => fail('no separate network probe')),
      );
      var attempts = 0;
      session.onMediaReady = () async => fail('do not reopen active media');
      session.onRecoveryMediaReady = () async {
        attempts++;
        return true;
      };
      session.mediaUnavailable('channel');
      clock.elapse(const Duration(seconds: 3));
      expect(attempts, 0);
      session.activate();
      for (var i = 2; i <= 4; i++) {
        player.state = PlayerState(
          playing: true,
          position: Duration(seconds: i),
        );
        clock.elapse(const Duration(seconds: 1));
      }
      expect(attempts, 1);
      expect(player.state.position, const Duration(seconds: 4));
      expect(session.text.value, isEmpty);
      unawaited(session.dispose());
      unawaited(selection.dispose());
      clock.flushMicrotasks();
    });
  });
  for (final endpoint in [
    'https://bobtv.briconbric.com/api/v1/subtitles/',
    'https://cndrp.com/bobtv/api/v1/subtitles/',
  ]) {
    test(
      'EPG-bound channel enters discovery without calling retired API at $endpoint',
      () async {
        var requests = 0;
        var programmeLookups = 0;
        final player = _Player();
        final selection = NativeSubtitleSelection(player);
        final session = LiveSubtitleSession(
          player,
          selection,
          serviceEndpoint: endpoint,
          programmeLookup: (_) async {
            programmeLookups++;
            return {'key': 'sunshine-cleaning', 'title': 'Sunshine Cleaning'};
          },
          client: MockClient((_) async {
            requests++;
            return http.Response('', 502);
          }),
        );
        const source = 'https://comedy-rakuten-tv-uk.fast.rakuten.tv/live.m3u8';
        expect(await session.prepare(source), source);
        session.activate();
        expect(session.status.value, SubtitlePhase.serviceUnavailable);
        expect(session.text.value, isEmpty);
        expect(requests, 0);
        expect(programmeLookups, 1);
        expect(player.state.position, const Duration(seconds: 1));
        await session.dispose();
        await selection.dispose();
      },
    );
  }
  test(
    'reviewed Comedy route can resolve EPG on server after local lookup misses',
    () async {
      final player = _Player();
      final selection = NativeSubtitleSelection(player);
      var legacyRequests = 0;
      final session = LiveSubtitleSession(
        player,
        selection,
        programmeLookup: (_) async => null,
        client: MockClient((_) async {
          legacyRequests++;
          return http.Response('', 502);
        }),
      );
      const source =
          'https://comedy-rakuten-tv-uk.fast.rakuten.tv/v1/master/session/production-hls-aes128-rtv-6181-playout/master.m3u8';
      expect(await session.prepare(source), source);
      // Tests have no native ASR bundle. Reaching this state demonstrates that
      // missing local EPG did not reject this public route before local setup.
      expect(session.status.value, SubtitlePhase.serviceUnavailable);
      expect(legacyRequests, 0);
      await session.dispose();
      await selection.dispose();
    },
  );
  test(
    'pending search and confirmed absence are distinct and do not move playback',
    () async {
      final response = Completer<http.Response>();
      final player = _Player();
      final selection = NativeSubtitleSelection(player);
      final session = LiveSubtitleSession(
        player,
        selection,
        serviceEndpoint: 'http://127.0.0.1/',
        client: MockClient((_) => response.future),
      );
      final preparing = session.prepare('channel');
      expect(session.status.value, SubtitlePhase.searching);
      response.complete(
        http.Response(
          jsonEncode({...reply(phase: 'unavailable'), 'windows': []}),
          200,
        ),
      );
      await preparing;
      session.activate();
      expect(session.status.value, SubtitlePhase.unavailable);
      expect(player.state.position, const Duration(seconds: 1));
      await session.dispose();
      await selection.dispose();
    },
  );
  test('dialogue gaps retain file readiness and English fallback', () async {
    SubtitlePreferences.instance.choose(AppLanguage.japanese);
    final player = _Player();
    final selection = NativeSubtitleSelection(player);
    final session = LiveSubtitleSession(
      player,
      selection,
      serviceEndpoint: 'http://127.0.0.1/',
      client: MockClient(
        (_) async => http.Response(jsonEncode(reply(cues: false)), 200),
      ),
    );
    await session.prepare('channel');
    session.activate();
    expect(session.text.value, isEmpty);
    expect(session.status.value, SubtitlePhase.englishFallback);
    await session.dispose();
    await selection.dispose();
  });
  test(
    'warming discovery automatically connects a fresh media origin without user action',
    () async {
      final player = _Player();
      final selection = NativeSubtitleSelection(player);
      var connects = 0;
      var polls = 0;
      final done = Completer<void>();
      final requests = <http.Request>[];
      final session = LiveSubtitleSession(
        player,
        selection,
        serviceEndpoint: 'http://127.0.0.1/',
        client: MockClient((request) async {
          requests.add(request);
          if (request.url.path == '/sessions')
            return http.Response(
              jsonEncode(reply(ready: false, phase: 'searching')),
              200,
            );
          if (request.url.path.endsWith('/connect')) {
            connects++;
            return http.Response(
              jsonEncode({...reply(), 'mediaClockOrigin': 900}),
              200,
            );
          }
          polls++;
          return http.Response(jsonEncode(reply()), 200);
        }),
      );
      session.onMediaReady = () async {
        expect(
          await session.attachReadyMedia('channel'),
          'http://127.0.0.1/media',
        );
        // Server captions cannot be rendered against the original source clock.
        expect(session.text.value, isEmpty);
        session.activate();
        if (!done.isCompleted) done.complete();
      };
      expect(await session.prepare('channel'), 'channel');
      session.activate();
      expect(session.text.value, isEmpty);
      await done.future.timeout(const Duration(seconds: 3));
      expect(connects, 1);
      expect(polls, greaterThan(0));
      expect(session.text.value, 'Existing caption');
      expect(requests.every((r) => r.url.host == '127.0.0.1'), isTrue);
      expect(player.state.position, const Duration(seconds: 1));
      await session.dispose();
      await selection.dispose();
    },
  );
  test(
    'cleared channel rejects a late ready response and cannot trigger reconnection',
    () async {
      final player = _Player();
      final selection = NativeSubtitleSelection(player);
      final late = Completer<http.Response>();
      var connects = 0;
      final session = LiveSubtitleSession(
        player,
        selection,
        serviceEndpoint: 'http://127.0.0.1/',
        client: MockClient((request) async {
          if (request.method == 'POST')
            return http.Response(
              jsonEncode(reply(ready: false, phase: 'searching')),
              200,
            );
          return late.future;
        }),
      );
      session.onMediaReady = () async {
        connects++;
      };
      await session.prepare('channel');
      session.activate();
      await Future<void>.delayed(const Duration(milliseconds: 550));
      session.clear();
      late.complete(http.Response(jsonEncode(reply()), 200));
      await Future<void>.delayed(Duration.zero);
      expect(connects, 0);
      expect(session.status.value, SubtitlePhase.idle);
      expect(session.text.value, isEmpty);
      await session.dispose();
      await selection.dispose();
    },
  );
}
