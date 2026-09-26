import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:clubtivi/features/casting/airplay_bridge.dart';
import 'package:clubtivi/features/casting/cast_service.dart';

class FakeAirPlay extends AirPlayBridge {
  final calls = <String>[];
  final messages = StreamController<Map<String, dynamic>>.broadcast();
  Completer<void>? nextPlay;
  @override
  Stream<Map<String, dynamic>> get events => messages.stream;
  @override
  Future<Map<String, dynamic>> request(
    String action, [
    Map<String, dynamic> arguments = const {},
  ]) async {
    calls.add('$action:${arguments['url'] ?? ''}');
    if (action == 'play') {
      final gate = nextPlay;
      nextPlay = null;
      await gate?.future;
    }
    return {};
  }

  @override
  void dispose() {
    messages.close();
    super.dispose();
  }
}

void main() {
  test('unsupported receiver cannot send pairing or playback requests', () async {
    final bridge = FakeAirPlay();
    final service = CastService(airplay: bridge);
    final mac = CastDevice(id: 'airplay_mac', name: 'Mac', type: 'airplay',
      unavailableReason: 'Mac 原生接收端目前不受支援');
    await expectLater(service.beginPairing(mac), throwsStateError);
    expect(await service.castTo(mac, 'https://example.com/live'), false);
    expect(bridge.calls, isEmpty);
    expect(service.lastError, contains('Mac'));
    service.dispose();
  });
  final tv = CastDevice(id: 'airplay_test', name: 'TV', type: 'airplay');
  test('stop queued during connect cannot leave a cast active', () async {
    final bridge = FakeAirPlay();
    final service = CastService(airplay: bridge);
    final gate = Completer<void>();
    bridge.nextPlay = gate;
    final play = service.castTo(tv, 'https://example.com/1');
    await Future<void>.delayed(Duration.zero);
    final stop = service.stopCasting();
    gate.complete();
    await play;
    await stop;
    expect(service.isCasting, false);
    expect(bridge.calls, ['play:https://example.com/1', 'stop:']);
    service.dispose();
  });

  test('rapid changes discard superseded queued URLs', () async {
    final bridge = FakeAirPlay();
    final service = CastService(airplay: bridge);
    final gate = Completer<void>();
    bridge.nextPlay = gate;
    final first = service.castTo(tv, 'https://example.com/1');
    await Future<void>.delayed(Duration.zero);
    final second = service.castTo(tv, 'https://example.com/2');
    final third = service.castTo(tv, 'https://example.com/3');
    gate.complete();
    expect(await first, true);
    expect(await second, false);
    expect(await third, true);
    expect(bridge.calls, [
      'play:https://example.com/1',
      'play:https://example.com/3',
    ]);
    await service.switchChannel('https://example.com/3');
    expect(bridge.calls.length, 2);
    service.dispose();
  });

  test(
    'asynchronous receiver failures clear active status and surface message',
    () async {
      final bridge = FakeAirPlay();
      final service = CastService(airplay: bridge);
      await service.castTo(tv, 'https://example.com/video');
      final message = service.statusStream.first;
      bridge.messages.add({
        'event': 'error',
        'message': 'Receiver unavailable',
      });
      expect(await message, 'Receiver unavailable');
      expect(service.isCasting, false);
      expect(service.lastError, 'Receiver unavailable');
      service.dispose();
    },
  );
}
