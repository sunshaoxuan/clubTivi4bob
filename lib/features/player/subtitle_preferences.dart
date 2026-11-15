import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/i18n/app_language.dart';

class SubtitlePreferences extends ChangeNotifier {
  static final instance = SubtitlePreferences();
  static const languageKey = 'bobtv_subtitle_language';
  static const enabledKey = 'bobtv_subtitle_enabled';
  SharedPreferences? _preferences;
  AppLanguage? _specified;
  AppLanguage _application = AppLanguage.english;
  bool _enabled = true;
  Future<void> _saving = Future.value();

  AppLanguage get language => _specified ?? _application;
  bool get enabled => _enabled;
  bool get followsApplication => _specified == null;

  void initialize(SharedPreferences? preferences) {
    _preferences = preferences;
    _specified = AppLanguage.fromTag(preferences?.getString(languageKey));
    _enabled = preferences?.getBool(enabledKey) ?? true;
  }

  void applicationLanguage(AppLanguage language) {
    if (_application == language) return;
    _application = language;
    if (_specified == null) notifyListeners();
  }

  void choose(AppLanguage? language) {
    _specified = language;
    _enabled = true;
    notifyListeners();
    _save();
  }

  void setEnabled(bool enabled) {
    if (_enabled == enabled) return;
    _enabled = enabled;
    notifyListeners();
    _save();
  }

  void _save() {
    final preferences = _preferences;
    if (preferences == null) return;
    final language = _specified?.tag;
    final enabled = _enabled;
    _saving = _saving
        .then((_) async {
          await preferences.setBool(enabledKey, enabled);
          if (language == null) {
            await preferences.remove(languageKey);
          } else {
            await preferences.setString(languageKey, language);
          }
        })
        .catchError((Object error, StackTrace stack) {
          FlutterError.reportError(
            FlutterErrorDetails(exception: error, stack: stack),
          );
        });
  }
}
