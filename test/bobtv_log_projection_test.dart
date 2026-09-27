import 'dart:convert';

import 'package:clubtivi/data/services/bobtv_log_projection.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('projects diagnostics onto the exact allowed field set', () {
    final bytes = BobTvLogProjection.project([
      jsonEncode({
        'time': '2026-09-27T00:00:00Z',
        'event': 'application_error',
        'source': 'player',
        'fatal': true,
        'rssBytes': 1200,
        'error': 'token=secret',
        'stack': '/home/private/source.dart',
        'stream': 'https://media.example.com/live.m3u8',
      }),
      jsonEncode({
        'time': '2026-09-27T00:01:00Z',
        'event': 'heartbeat',
        'source': 'https://media.example.com/live.m3u8',
      }),
    ]);
    final lines = utf8.decode(bytes).trim().split('\n');
    final first = jsonDecode(lines.first) as Map<String, dynamic>;
    expect(first, {
      'time': '2026-09-27T00:00:00Z',
      'event': 'application_error',
      'source': 'player',
      'fatal': true,
      'rssBytes': 1200,
    });
    expect(jsonDecode(lines.last), {
      'time': '2026-09-27T00:01:00Z',
      'event': 'heartbeat',
    });
    expect(utf8.decode(bytes), isNot(contains('secret')));
    expect(utf8.decode(bytes), isNot(contains('media.example.com')));
  });

  test('keeps snapshot below server limits', () {
    final line = jsonEncode({
      'time': '2026-09-27T00:00:00Z',
      'event': 'heartbeat',
      'rssBytes': 1200,
    });
    final bytes = BobTvLogProjection.project(List.filled(6000, line));
    expect(bytes.length, lessThanOrEqualTo(1024 * 1024));
    expect(utf8.decode(bytes).trim().split('\n').length, 5000);
  });
}
