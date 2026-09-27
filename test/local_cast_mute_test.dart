import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:clubtivi/features/casting/local_cast_mute.dart';

void main() {
  test('idle status never reads or writes the player', () async {
    final policy = LocalCastMute(
      readMute: () async => throw StateError('unexpected read'),
      writeMute: (_) async => throw StateError('unexpected write'),
    );
    await policy.update(false);
    await policy.update(false);
  });

  for (final initial in [false, true]) {
    test('restores initial mute=$initial without touching volume', () async {
      var muted = initial;
      final writes = <bool>[];
      final policy = LocalCastMute(readMute: () async => muted,
        writeMute: (value) async { writes.add(value); muted = value; });
      await policy.update(true);
      await policy.update(true);
      expect(writes, [true]);
      await policy.update(false);
      await policy.update(false);
      expect(writes, [true, initial]);
      expect(muted, initial);
    });
  }

  test('stop during delayed activation restores local output', () async {
    final gate = Completer<bool>();
    final writes = <bool>[];
    final policy = LocalCastMute(readMute: () => gate.future,
      writeMute: (v) async { writes.add(v); });
    final start = policy.update(true);
    final stop = policy.update(false);
    gate.complete(false);
    await Future.wait([start, stop]);
    expect(writes, [true, false]);
  });

  test('failed restore can be retried', () async {
    var fail = true;
    final writes = <bool>[];
    final policy = LocalCastMute(readMute: () async => false,
      writeMute: (v) async {
        if (!v && fail) { fail = false; throw StateError('test'); }
        writes.add(v);
      });
    await policy.update(true);
    await expectLater(policy.update(false), throwsStateError);
    await policy.update(false);
    expect(writes, [true, false]);
  });

  test('disposal during read prevents a late mute write', () async {
    final gate = Completer<bool>();
    final writes = <bool>[];
    final policy = LocalCastMute(readMute: () => gate.future,
      writeMute: (v) async { writes.add(v); });
    final pending = policy.update(true);
    await Future<void>.delayed(Duration.zero);
    policy.dispose();
    gate.complete(false);
    await pending;
    expect(writes, isEmpty);
  });
}
