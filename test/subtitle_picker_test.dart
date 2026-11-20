import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:clubtivi/core/i18n/app_language.dart';
import 'package:clubtivi/features/player/subtitle_picker.dart';
import 'package:clubtivi/features/player/subtitle_preferences.dart';
import 'package:clubtivi/features/player/subtitle_status.dart';
import 'package:clubtivi/features/player/subtitle_variants.dart';

class _EnglishMessages extends LocalizationsDelegate<AppMessages> {
  const _EnglishMessages();

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<AppMessages> load(Locale locale) {
    final messages =
        (jsonDecode(File(AppLanguage.english.bundlePath).readAsStringSync())
                as Map)
            .cast<String, String>();
    return SynchronousFuture(AppMessages(messages, messages));
  }

  @override
  bool shouldReload(_EnglishMessages old) => false;
}

void main() {
  testWidgets('icon-only subtitle button opens the menu', (tester) async {
    final preferences = SubtitlePreferences.instance;
    preferences.initialize(null);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [_EnglishMessages()],
        home: Scaffold(
          body: SubtitleMenuButton(session: () => null),
        ),
      ),
    );
    expect(find.text('subtitles'), findsNothing);
    expect(find.byTooltip('subtitles'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('subtitle-menu')));
    await tester.pumpAndSettle();
    expect(find.byType(SubtitlePicker), findsOneWidget);
    expect(find.text('Follow interface language'), findsOneWidget);
    expect(find.text('日本語'), findsOneWidget);
    expect(find.text('Off'), findsOneWidget);
    await tester.tap(find.text('Off'));
    await tester.pumpAndSettle();
    expect(preferences.enabled, isFalse);
    await tester.pumpWidget(const SizedBox());
    preferences.initialize(null);
  });

  testWidgets('picker lists versions across available languages', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 568);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final preferences = SubtitlePreferences()
      ..choose(AppLanguage.simplifiedChinese);
    const first =
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    const second =
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    const french =
        'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
    final options = ValueNotifier(
      const SubtitleVariantOptions(
        scope: 4,
        candidates: [
          SubtitleVariantCandidate(
            id: first,
            language: 'en',
            provider: 'SubDL',
            label: 'First release',
          ),
          SubtitleVariantCandidate(
            id: second,
            language: 'en',
            provider: 'Subtitle Cat',
            label: 'Second release',
          ),
          SubtitleVariantCandidate(
            id: french,
            language: 'fr',
            provider: 'SubDL',
            label: 'French release',
          ),
        ],
        activeId: first,
      ),
    );
    final phase = ValueNotifier(SubtitlePhase.englishFallback);
    final chosen = <(String?, int)>[];
    final searches = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [_EnglishMessages()],
        home: Scaffold(
          body: SubtitlePicker(
            preferences: preferences,
            options: options,
            status: phase,
            onVariant: (id, scope) => chosen.add((id, scope)),
            onRetry: (language) async {
              searches.add(language);
              return true;
            },
          ),
        ),
      ),
    );
    expect(find.text('English subtitle versions'), findsOneWidget);
    expect(find.text('Using English subtitles'), findsOneWidget);
    await tester.tap(find.text('Search again for 简体中文 subtitles'));
    await tester.pump();
    expect(searches, ['zh-CN']);
    expect(find.byTooltip('Currently in use'), findsOneWidget);
    await tester.ensureVisible(find.text('Second release'));
    await tester.tap(find.text('Second release'));
    expect(chosen.single, (second, 4));
    await tester.ensureVisible(find.text('French release'));
    await tester.tap(find.text('French release'));
    expect(chosen.last, (french, 4));
    expect(preferences.language, AppLanguage.simplifiedChinese);
    phase.value = SubtitlePhase.synchronizing;
    await tester.pump();
    expect(find.text('Synchronizing subtitles…'), findsOneWidget);
    expect(find.byTooltip('Currently in use'), findsNothing);
    await tester.ensureVisible(find.text('Automatic version'));
    await tester.tap(find.text('Automatic version'));
    expect(chosen.last, (null, 4));
    await tester.pumpWidget(const SizedBox());
    options.dispose();
    phase.dispose();
    preferences.dispose();
  });
}
