import 'dart:async';
import 'package:clubtivi/data/services/category_load_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('warm scope uses LRU and simultaneous reads coalesce', () async {
    final cache = CategoryLoadCache<int>(capacity: 2);
    var calls = 0;
    Future<int> read() async => ++calls;
    expect(await Future.wait([cache.load('a', read), cache.load('a', read)]), [
      1,
      1,
    ]);
    expect(await cache.load('b', read), 2);
    expect(await cache.load('a', read), 1);
    expect(await cache.load('c', read), 3);
    expect(cache.contains('a'), isTrue);
    expect(cache.contains('b'), isFalse);
    expect(calls, 3);
  });
  test('late invalidated reads cannot poison a new revision', () async {
    final cache = CategoryLoadCache<int>();
    final gate = Completer<int>();
    final old = cache.load('country', () => gate.future);
    cache.invalidate();
    expect(await cache.load('country', () async => 2), 2);
    gate.complete(1);
    expect(await old, 1);
    expect(await cache.load('country', () async => 3), 2);
  });
  test('failed reads remain retryable', () async {
    final cache = CategoryLoadCache<int>();
    await expectLater(
      cache.load('a', () async => throw StateError('fixture')),
      throwsStateError,
    );
    expect(cache.contains('a'), isFalse);
    expect(await cache.load('a', () async => 1), 1);
  });
}
