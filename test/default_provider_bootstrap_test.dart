import 'package:clubtivi/features/providers/default_provider_bootstrap.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('default hotel TV sources have unique IDs and HTTPS URLs', () {
    final sources = DefaultProviderBootstrap.sources;
    expect(sources, isNotEmpty);
    expect(sources.map((source) => source.id).toSet().length, sources.length);
    expect(
      sources.every((source) => Uri.parse(source.url).scheme == 'https'),
      isTrue,
    );
  });

  test('best-fan source follows the current default branch', () {
    final source = DefaultProviderBootstrap.sources.firstWhere(
      (item) => item.id == 'hotel-best-fan-status',
    );
    expect(source.url, contains('/main/cn_all_status.m3u8'));
  });
}
