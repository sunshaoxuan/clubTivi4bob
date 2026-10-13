import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// A per-user choice. Setup supplies only the first-run default; subsequent
/// upgrades must not overwrite an explicit choice in the application's settings.
class DeviceFavoritesPrivacy {
  static const preferenceKey = 'bobtv_private_favorites_backup_enabled';

  static Future<bool> enabled({
    Future<bool?> Function()? installationChoice,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getBool(preferenceKey);
    if (saved != null) return saved;
    final value = await (installationChoice ?? _installationChoice)() ?? true;
    // An explicit choice made while the installation file was being read wins.
    final latest = prefs.getBool(preferenceKey);
    if (latest != null) return latest;
    await prefs.setBool(preferenceKey, value);
    return prefs.getBool(preferenceKey) ?? value;
  }

  static Future<bool?> _installationChoice() async {
    if (Platform.isWindows) {
      try {
        final marker = File(
          p.join(p.dirname(Platform.resolvedExecutable), 'installation.ini'),
        );
        if (await marker.exists()) {
          return installerDefault(await marker.readAsString());
        }
      } catch (_) {
        // Preserve the existing behavior of portable and older installations.
      }
    }
    return null;
  }

  static Future<void> setEnabled(bool enabled) async {
    await (await SharedPreferences.getInstance()).setBool(
      preferenceKey,
      enabled,
    );
  }

  static bool? installerDefault(String text) {
    var inPrivacy = false;
    bool? found;
    for (final raw in text.split(RegExp(r'\r?\n'))) {
      final line = raw.trim().replaceFirst('\uFEFF', '');
      if (line.isEmpty || line.startsWith(';') || line.startsWith('#')) {
        continue;
      }
      if (line.startsWith('[') && line.endsWith(']')) {
        inPrivacy = line.toLowerCase() == '[bobtvprivacy]';
        continue;
      }
      if (!inPrivacy) continue;
      final equal = line.indexOf('=');
      if (equal < 0 ||
          line.substring(0, equal).trim().toLowerCase() != 'favoritesbackup') {
        continue;
      }
      final value = line.substring(equal + 1).trim();
      if (value != '0' && value != '1') return false;
      final next = value == '1';
      if (found != null && found != next) return false;
      found = next;
    }
    return found;
  }
}
