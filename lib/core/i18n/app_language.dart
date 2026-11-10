import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

enum AppLanguage {
  english('en', 'English', Locale('en')),
  simplifiedChinese(
    'zh-CN',
    '简体中文',
    Locale.fromSubtags(
      languageCode: 'zh',
      scriptCode: 'Hans',
      countryCode: 'CN',
    ),
  ),
  traditionalChinese(
    'zh-TW',
    '繁體中文',
    Locale.fromSubtags(
      languageCode: 'zh',
      scriptCode: 'Hant',
      countryCode: 'TW',
    ),
  ),
  japanese('ja', '日本語', Locale('ja')),
  french('fr', 'Français', Locale('fr')),
  spanish('es', 'Español', Locale('es')),
  korean('ko', '한국어', Locale('ko'));

  const AppLanguage(this.tag, this.label, this.locale);
  static const preferenceKey = 'bobtv_app_language';

  final String tag;
  final String label;
  final Locale locale;

  String get bundlePath => 'assets/i18n/$tag.json';

  static AppLanguage? fromTag(String? tag) =>
      values.where((language) => language.tag == tag).firstOrNull;

  static AppLanguage resolve(Iterable<Locale> hostLocales, String? timeZone) {
    for (final locale in hostLocales) {
      if (locale.languageCode == 'zh') {
        if (locale.scriptCode == 'Hant') return traditionalChinese;
        if (locale.scriptCode == 'Hans') return simplifiedChinese;
        return const {'TW', 'HK', 'MO'}.contains(locale.countryCode)
            ? traditionalChinese
            : simplifiedChinese;
      }
      final language = fromTag(locale.languageCode);
      if (language != null) return language;
    }

    return switch (timeZone) {
      'Asia/Tokyo' || 'Tokyo Standard Time' || 'JST' => japanese,
      'Asia/Seoul' ||
      'Asia/Pyongyang' ||
      'Korea Standard Time' ||
      'KST' => korean,
      'Asia/Taipei' ||
      'Asia/Hong_Kong' ||
      'Asia/Macau' ||
      'Taipei Standard Time' => traditionalChinese,
      'Asia/Shanghai' ||
      'Asia/Chongqing' ||
      'Asia/Urumqi' ||
      'Asia/Harbin' ||
      'PRC' ||
      'China Standard Time' => simplifiedChinese,
      'Europe/Paris' ||
      'Europe/Monaco' ||
      'Romance Standard Time (France)' ||
      'America/Guadeloupe' ||
      'America/Martinique' ||
      'America/Cayenne' ||
      'Indian/Reunion' ||
      'Indian/Mayotte' => french,
      'Europe/Madrid' ||
      'Atlantic/Canary' ||
      'Africa/Ceuta' ||
      'America/Argentina/Buenos_Aires' ||
      'America/Buenos_Aires' ||
      'America/Mexico_City' ||
      'America/Bogota' ||
      'America/Santiago' ||
      'America/Lima' ||
      'America/Caracas' ||
      'America/La_Paz' ||
      'America/Asuncion' ||
      'America/Montevideo' ||
      'America/Guayaquil' ||
      'America/Panama' ||
      'America/Costa_Rica' ||
      'America/Managua' ||
      'America/Tegucigalpa' ||
      'America/El_Salvador' ||
      'America/Guatemala' ||
      'America/Santo_Domingo' ||
      'America/Havana' ||
      'America/Puerto_Rico' ||
      'Central Standard Time (Mexico)' ||
      'Romance Standard Time (Spain)' ||
      'Argentina Standard Time' ||
      'Pacific SA Standard Time' ||
      'Venezuela Standard Time' ||
      'Paraguay Standard Time' ||
      'Montevideo Standard Time' => spanish,
      _ => english,
    };
  }

  static Future<String?> readTimeZone() async {
    try {
      final zone = await const MethodChannel(
        'bobtv/locale',
      ).invokeMethod<String>('timeZone');
      if (zone != null && zone.isNotEmpty) return zone;
    } on MissingPluginException {
      // Unix builds can read the zoneinfo link below.
    } on PlatformException {
      // Continue with the process's local zone.
    }
    final zone = Platform.environment['TZ'];
    if (zone != null && zone.isNotEmpty) return zone;
    if (Platform.isLinux) {
      try {
        final path = await Link('/etc/localtime').target();
        final marker = path.lastIndexOf('zoneinfo/');
        if (marker >= 0) return path.substring(marker + 'zoneinfo/'.length);
      } on FileSystemException {
        // An offset or ambiguous abbreviation cannot identify a region.
      }
    }
    return DateTime.now().timeZoneName;
  }
}

class AppMessages {
  const AppMessages(this._messages, this._english);

  final Map<String, String> _messages;
  final Map<String, String> _english;
  static const delegate = _MessagesDelegate();

  static String category(BuildContext context, String source) {
    final messages = Localizations.of<AppMessages>(context, AppMessages);
    return source
        .split(' / ')
        .map((part) {
          return messages?._messages['country:$part'] ??
              messages?._english['country:$part'] ??
              text(context, part);
        })
        .join(' / ');
  }

  static String text(
    BuildContext context,
    String source, [
    List<Object?> args = const [],
  ]) {
    final messages = Localizations.of<AppMessages>(context, AppMessages);
    return (messages?._messages[source] ?? messages?._english[source] ?? source)
        .replaceAllMapped(RegExp(r'\{(\d+)\}'), (match) {
          final index = int.parse(match[1]!);
          return index < args.length ? '${args[index]}' : match[0]!;
        });
  }
}

class _MessagesDelegate extends LocalizationsDelegate<AppMessages> {
  const _MessagesDelegate();

  @override
  bool isSupported(Locale locale) =>
      AppLanguage.values.any((language) => language.locale == locale);

  @override
  Future<AppMessages> load(Locale locale) async {
    Future<Map<String, String>> loadBundle(AppLanguage language) async =>
        (jsonDecode(await rootBundle.loadString(language.bundlePath)) as Map)
            .cast<String, String>();

    final language = AppLanguage.resolve([locale], null);
    final english = await loadBundle(AppLanguage.english);
    return AppMessages(
      language == AppLanguage.english ? english : await loadBundle(language),
      english,
    );
  }

  @override
  bool shouldReload(_MessagesDelegate old) => false;
}
