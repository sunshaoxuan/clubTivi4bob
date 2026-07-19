import 'package:clubtivi/core/app_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('stream diagnostics omit paths, queries, and credentials', () {
    final summary = AppDiagnostics.summarizeStreamUrl(
      'https://user:secret@example.com/live/channel.m3u8?token=private',
    );

    expect(summary, startsWith('https://example.com/#'));
    expect(summary, isNot(contains('secret')));
    expect(summary, isNot(contains('channel.m3u8')));
    expect(summary, isNot(contains('private')));
  });
}
