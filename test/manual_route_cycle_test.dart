import 'package:clubtivi/data/services/manual_route_cycle.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('manual next advances after failed attempts and prefers healthy routes', () {
    final cycle = ManualRouteCycle();
    final scores = {'first': 0.9, 'second': 0.7, 'third': 0.8};
    final at = DateTime(2026, 1, 1);

    String? next(String current) => cycle.chooseNext(
      channelKey: 'cctv5',
      currentUrl: current,
      candidates: const ['first', 'second', 'third'],
      score: (url) => scores[url]!,
      now: at,
    );

    expect(next('first'), 'third');
    expect(next('third'), 'second');
    expect(next('second'), isNull);
  });

  test('channel cycles are separate and expired routes can be retried', () {
    final cycle = ManualRouteCycle();
    final at = DateTime(2026, 1, 1);

    String? next(String channel, DateTime time) => cycle.chooseNext(
      channelKey: channel,
      currentUrl: 'first',
      candidates: const ['second'],
      score: (_) => 0.5,
      now: time,
    );

    expect(next('a', at), 'second');
    expect(next('a', at.add(const Duration(minutes: 1))), isNull);
    expect(next('b', at.add(const Duration(minutes: 1))), 'second');
    expect(next('a', at.add(const Duration(minutes: 5))), 'second');
  });
}
