// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:clubtivi/app/app.dart';
import 'package:clubtivi/core/i18n/app_language.dart';
import 'package:clubtivi/core/i18n/language_menu.dart';

void main() {
  testWidgets('App follows the saved language and writes manual changes', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({AppLanguage.preferenceKey: 'ja'});
    tester.binding.platformDispatcher.localesTestValue = [const Locale('ko')];
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
    final preferences = await SharedPreferences.getInstance();
    await tester.runAsync(() async {
      for (final language in AppLanguage.values) {
        await rootBundle.loadString(language.bundlePath);
      }
    });

    await tester.pumpWidget(
      ProviderScope(child: ClubTiviApp(preferences: preferences)),
    );
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).locale,
      AppLanguage.japanese.locale,
    );

    await tester.pump();
    final scope = tester.widget<LanguageScope>(find.byType(LanguageScope));
    scope.onSelected('fr');
    await tester.pump();
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).locale,
      AppLanguage.french.locale,
    );
    expect(preferences.getString(AppLanguage.preferenceKey), 'fr');

    scope.onSelected('system');
    await tester.pump();
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).locale,
      AppLanguage.korean.locale,
    );
    expect(preferences.getString(AppLanguage.preferenceKey), isNull);
  });
}
