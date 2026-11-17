import 'package:flutter_test/flutter_test.dart';
import 'package:clubtivi/features/player/source_clock.dart';

void main() {
  test('read-ahead corrections apply at their media time and both streams', () {
    final ledger = SourceClockLedger()..reset();
    ledger.observe({
      'event': 'remux_discontinuity',
      'stream': 0,
      'outputDts': 148.0,
      'removedSeconds': 94000.0,
    });
    ledger.observe({
      'event': 'remux_discontinuity',
      'stream': 1,
      'outputDts': 148.0,
      'removedSeconds': 94000.1,
    });
    expect(ledger.at(147.0)!['audioRemoved'], 0);
    expect(ledger.at(148.1)!['audioRemoved'], 94000.1);
    ledger.observe({
      'event': 'remux_discontinuity',
      'stream': 0,
      'outputDts': 298.0,
      'removedSeconds': -94148.0,
    });
    ledger.observe({
      'event': 'remux_discontinuity',
      'stream': 1,
      'outputDts': 298.0,
      'removedSeconds': -94148.153333,
    });
    expect(ledger.at(297.0)!['updatedAt'], 148.0);
    expect(ledger.at(298.1)!['audioRemoved'], closeTo(-148.053333, .000001));
    expect(ledger.at(298.1)!['updatedAt'], 298.0);
  });
  test(
    'PID changes, repairs and sequence gaps invalidate optional evidence',
    () {
      for (final kind in [
        'remux_stream_changed',
        'remux_packet_adjusted',
        'remux_error',
      ]) {
        final ledger = SourceClockLedger()..reset();
        ledger.observe({'event': kind});
        expect(ledger.at(1), isNull);
        ledger.reset();
        expect(ledger.at(1), isNotNull);
        ledger.invalidate();
        expect(ledger.at(1), isNull);
      }
    },
  );
  test('recorded Android ad transition clears on the first AV stream', () {
    final ledger = SourceClockLedger()..reset();
    ledger.observe({
      'event': 'remux_discontinuity',
      'stream': 0,
      'outputDts': 4289.770066667,
      'removedSeconds': 94469.792655556,
    });
    ledger.observe({
      'event': 'remux_discontinuity',
      'stream': 1,
      'outputDts': 4290.32,
      'removedSeconds': 94469.744355556,
    });
    expect(
      sourceBoundaryBeforeAdvert(
        ledger.at(4289.3 + .25),
        4289.3,
        advertWithinLookahead: true,
      ),
      isFalse,
    );
    for (final position in [4289.8, 4290.0, 4290.4, 4297.9]) {
      expect(
        sourceBoundaryBeforeAdvert(
          ledger.at(position + .25),
          position,
          advertWithinLookahead: true,
        ),
        isTrue,
      );
    }
    expect(
      sourceBoundaryBeforeAdvert(
        ledger.at(4297),
        4297,
        advertWithinLookahead: false,
      ),
      isFalse,
    );
    expect(
      sourceBoundaryBeforeAdvert(null, 4297, advertWithinLookahead: true),
      isFalse,
    );
    expect(
      sourceBoundaryBeforeAdvert(
        ledger.at(4350),
        4350,
        advertWithinLookahead: true,
      ),
      isFalse,
    );
  });
}
