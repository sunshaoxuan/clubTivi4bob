import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/i18n/app_language.dart';
import '../core/i18n/language_menu.dart';

import '../core/platform_info.dart';
import 'router.dart';
import 'theme.dart';
import 'windows_fullscreen_controls.dart';
import 'android_app_controls.dart';

class ClubTiviApp extends StatefulWidget {
  const ClubTiviApp({super.key, this.preferences});

  final SharedPreferences? preferences;

  @override
  State<ClubTiviApp> createState() => _ClubTiviAppState();
}

class _ClubTiviAppState extends State<ClubTiviApp> with WidgetsBindingObserver {
  late AppLanguage? _selected;
  String? _timeZone;
  Future<void> _saveLanguage = Future.value();

  @override
  void initState() {
    super.initState();
    _selected = AppLanguage.fromTag(
      widget.preferences?.getString(AppLanguage.preferenceKey),
    );
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refreshTimeZone());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _refreshTimeZone() async {
    final zone = await AppLanguage.readTimeZone();
    if (mounted && zone != _timeZone) setState(() => _timeZone = zone);
  }

  @override
  void didChangeLocales(List<Locale>? locales) {
    if (_selected == null) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _selected == null) {
      unawaited(_refreshTimeZone());
    }
  }

  void _selectLanguage(String tag) {
    final next = AppLanguage.fromTag(tag);
    final preferences = widget.preferences;
    if (next == _selected) return;
    setState(() => _selected = next);
    if (preferences != null) {
      _saveLanguage = _saveLanguage.then((_) async {
        try {
          if (next == null) {
            await preferences.remove(AppLanguage.preferenceKey);
          } else {
            await preferences.setString(AppLanguage.preferenceKey, next.tag);
          }
        } catch (error, stack) {
          FlutterError.reportError(
            FlutterErrorDetails(exception: error, stack: stack),
          );
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return LanguageScope(
      selected: _selected,
      onSelected: _selectLanguage,
      child: MaterialApp.router(
        title: 'BobTV',
        debugShowCheckedModeBanner: false,
        locale:
            (_selected ??
                    AppLanguage.resolve(
                      WidgetsBinding.instance.platformDispatcher.locales,
                      _timeZone,
                    ))
                .locale,
        supportedLocales: AppLanguage.values.map((language) => language.locale),
        localizationsDelegates: const [
          AppMessages.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: ClubTiviTheme.dark,
        routerConfig: router,
        builder: (context, child) {
          // Detect TV mode from the first MediaQuery context
          PlatformInfo.detectFromContext(context);
          return AndroidAppControls(
            child: WindowsFullscreenControls(
              child: child ?? const SizedBox.shrink(),
            ),
          );
        },
      ),
    );
  }
}
