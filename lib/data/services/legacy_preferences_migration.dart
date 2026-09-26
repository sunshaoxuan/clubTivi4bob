import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/app_diagnostics.dart';

class LegacyPreferencesMigration {
  static const _migrationMarker = 'bobtv_legacy_preferences_migrated_v1';
  static const _tmdbKey = 'shows_tmdb_api_key';

  static Future<void> run() async {
    if (!Platform.isWindows) return;
    try {
      final preferences = await SharedPreferences.getInstance();
      if (preferences.getBool(_migrationMarker) ?? false) return;

      var tmdbMigrated = false;
      final currentToken = preferences.getString(_tmdbKey) ?? '';
      if (currentToken.isEmpty) {
        final appData = Platform.environment['APPDATA'];
        if (appData != null && appData.isNotEmpty) {
          final legacyFile = File(
            p.join(
              appData,
              'io.github.clubanderson',
              'clubTivi',
              'shared_preferences.json',
            ),
          );
          if (await legacyFile.exists()) {
            final token = extractLegacyTmdbToken(
              await legacyFile.readAsString(),
            );
            if (token != null && token.isNotEmpty) {
              await preferences.setString(_tmdbKey, token);
              tmdbMigrated = true;
            }
          }
        }
      }

      await preferences.setBool(_migrationMarker, true);
      AppDiagnostics.instance.log('legacy_preferences_migrated', {
        'tmdbMigrated': tmdbMigrated,
        'tmdbAlreadyPresent': currentToken.isNotEmpty,
      });
    } catch (error, stackTrace) {
      AppDiagnostics.instance.recordError(
        'legacy_preferences_migration',
        error,
        stackTrace,
      );
    }
  }

  @visibleForTesting
  static String? extractLegacyTmdbToken(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        final value = decoded['flutter.$_tmdbKey'] ?? decoded[_tmdbKey];
        if (value is String && value.isNotEmpty) return value;
      }
    } catch (_) {
      // Older preference files can contain unrelated malformed values. The
      // credential itself is recovered with the narrow fallback below.
    }

    final match = RegExp(
      r'"(?:flutter\.)?shows_tmdb_api_key"\s*:\s*"([^"]*)"',
    ).firstMatch(raw);
    final encodedValue = match?.group(1);
    if (encodedValue == null || encodedValue.isEmpty) return null;
    try {
      final decodedValue = jsonDecode('"$encodedValue"');
      return decodedValue is String && decodedValue.isNotEmpty
          ? decodedValue
          : null;
    } catch (_) {
      return encodedValue;
    }
  }
}
