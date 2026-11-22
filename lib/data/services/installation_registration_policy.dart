import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Captured before startup creates preferences, identities, or a new database.
/// Existing installations retain anonymous catalog access across future upgrades.
class InstallationRegistrationPolicy {
  InstallationRegistrationPolicy({
    Future<SharedPreferences> Function()? preferences,
    Future<bool> Function()? existingData,
  }) : _preferences = preferences ?? SharedPreferences.getInstance,
       _existingData = existingData ?? _hasExistingData;

  static final instance = InstallationRegistrationPolicy();
  static const preferenceKey = 'bobtv.installation.registration_policy.v1';
  final Future<SharedPreferences> Function() _preferences;
  final Future<bool> Function() _existingData;
  Future<void>? _initialization;

  // Uncertain installation state must never interrupt an existing viewer.
  bool legacyAccess = true;

  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    try {
      final prefs = await _preferences();
      final saved = prefs.getString(preferenceKey);
      if (saved != null) {
        legacyAccess = saved != 'new';
        return;
      }
      legacyAccess = prefs.getKeys().isNotEmpty || await _existingData();
      if (!await prefs.setString(
        preferenceKey,
        legacyAccess ? 'legacy' : 'new',
      )) {
        legacyAccess = true;
      }
    } catch (_) {
      legacyAccess = true;
    }
  }

  static Future<bool> _hasExistingData() async {
    final support = await getApplicationSupportDirectory();
    final documents = await getApplicationDocumentsDirectory();
    final paths = [
      p.join(support.path, 'clubtivi', 'clubtivi.db'),
      p.join(documents.path, 'clubtivi', 'clubtivi.db'),
      p.join(support.path, 'Identity', 'client_fingerprint.txt'),
      if (Platform.isWindows && Platform.environment['LOCALAPPDATA'] != null)
        p.join(
          Platform.environment['LOCALAPPDATA']!,
          'HotelTV',
          'Identity',
          'client_fingerprint.txt',
        ),
      if (Platform.isWindows && Platform.environment['APPDATA'] != null)
        p.join(
          Platform.environment['APPDATA']!,
          'io.github.clubanderson',
          'clubTivi',
          'shared_preferences.json',
        ),
    ];
    for (final path in paths) {
      if (await File(path).exists()) return true;
    }
    return false;
  }
}
