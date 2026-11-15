import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:media_kit/media_kit.dart';
import 'package:clubtivi/features/player/live_subtitle_session.dart';
import 'package:clubtivi/features/player/native_subtitle_selection.dart';

class _Streams extends Fake implements PlayerStream {
  @override
  Stream<Tracks> get tracks => const Stream.empty();
  @override
  Stream<Duration> get position => const Stream.empty();
}

class _Player extends Fake implements Player {
  @override
  PlayerState state = const PlayerState(position: Duration(seconds: 1));
  @override
  PlayerStream stream = _Streams();
  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {}
}

void main() {
  test('late session response cannot caption the next channel', () async {
    final response = Completer<http.Response>();
    final player = _Player();
    final selection = NativeSubtitleSelection(player);
    final session = LiveSubtitleSession(
      player,
      selection,
      client: MockClient((request) => response.future),
      serviceEndpoint: 'http://127.0.0.1/',
    );
    final preparing = session.prepare('old-channel');
    await Future<void>.delayed(Duration.zero);
    session.clear();
    response.complete(
      http.Response(
        jsonEncode({
          'session': 'old',
          'source': 'old-channel',
          'playbackUrl': 'http://127.0.0.1/video',
          'windows': [],
        }),
        200,
      ),
    );
    expect(await preparing, 'old-channel');
    session.activate();
    expect(session.text.value, isEmpty);
    expect(selection.external, isFalse);
    await session.dispose();
    await selection.dispose();
  });
  test('expired service lease hides captions without touching video', () async {
    var requests = 0;
    final player = _Player();
    final selection = NativeSubtitleSelection(player);
    final session = LiveSubtitleSession(
      player,
      selection,
      client: MockClient(
        (request) async => ++requests > 1
            ? http.Response('', 503)
            : http.Response(
                jsonEncode({
                  'session': 'a',
                  'source': 'channel',
                  'playbackUrl': 'http://127.0.0.1/video',
                  'windows': [
                    {
                      'start': 0,
                      'end': 10,
                      'state': 'LOCKED',
                      'program': 'movie',
                      'asset': 'verified',
                      'tracks': [
                        {
                          'language': 'en',
                          'verified': true,
                          'cues': [
                            {'start': 0, 'end': 10, 'text': 'Hello'},
                          ],
                        },
                      ],
                    },
                  ],
                }),
                200,
              ),
      ),
      serviceEndpoint: 'http://127.0.0.1/',
    );
    expect(await session.prepare('channel'), 'http://127.0.0.1/video');
    session.activate();
    expect(session.text.value, 'Hello');
    await Future<void>.delayed(const Duration(seconds: 4));
    expect(session.text.value, isEmpty);
    expect(player.state.position, const Duration(seconds: 1));
    await session.dispose();
    await selection.dispose();
  });
}
