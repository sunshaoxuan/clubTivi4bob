import 'package:clubtivi/data/services/legacy_preferences_migration.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('extracts TMDB token from a valid legacy preferences file', () {
    expect(
      LegacyPreferencesMigration.extractLegacyTmdbToken(
        '{"flutter.shows_tmdb_api_key":"test-token"}',
      ),
      'test-token',
    );
  });

  test('recovers TMDB token when another legacy value is malformed', () {
    expect(
      LegacyPreferencesMigration.extractLegacyTmdbToken(
        '{"flutter.last_group":"broken,"flutter.last_channel_id":"1",'
        '"flutter.shows_tmdb_api_key":"recovered-token"}',
      ),
      'recovered-token',
    );
  });

  test('does not invent a missing TMDB token', () {
    expect(
      LegacyPreferencesMigration.extractLegacyTmdbToken(
        '{"flutter.last_group":"CCTV"}',
      ),
      isNull,
    );
  });
}
