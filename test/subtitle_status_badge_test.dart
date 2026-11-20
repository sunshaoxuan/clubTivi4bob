import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:clubtivi/core/i18n/app_language.dart';
import 'package:clubtivi/features/player/subtitle_status.dart';
import 'package:clubtivi/features/player/subtitle_status_badge.dart';

class _Messages extends LocalizationsDelegate<AppMessages> {
  const _Messages(this.language);
  final AppLanguage language;
  @override
  bool isSupported(Locale locale) => true;
  @override
  Future<AppMessages> load(Locale locale) => SynchronousFuture(
    AppMessages(
      (jsonDecode(File(language.bundlePath).readAsStringSync()) as Map)
          .cast<String, String>(),
      (jsonDecode(File(AppLanguage.english.bundlePath).readAsStringSync())
              as Map)
          .cast<String, String>(),
    ),
  );
  @override
  bool shouldReload(_Messages old) => old.language != language;
}

void main() {
  for (final language in AppLanguage.values) {
    testWidgets(
      'real ${language.tag} resources display each honest subtitle state',
      (tester) async {
        final resource =
            (jsonDecode(File(language.bundlePath).readAsStringSync()) as Map)
                .cast<String, String>();
        for (final phase in SubtitlePhase.values) {
          await tester.pumpWidget(
            MaterialApp(
              locale: language.locale,
              supportedLocales: AppLanguage.values.map((l) => l.locale),
              localizationsDelegates: [
                _Messages(language),
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              home: SizedBox(
                width: 300,
                height: 120,
                child: SubtitleStatusBadge(phase: phase),
              ),
            ),
          );
          if (phase.message == null) {
            expect(
              find.byKey(const ValueKey('subtitle-status-badge')),
              findsNothing,
            );
          } else {
            expect(resource[phase.message], isNotNull);
            expect(find.text(resource[phase.message]!), findsOneWidget);
            expect(
              find.byType(CircularProgressIndicator),
              phase.busy ? findsOneWidget : findsNothing,
            );
          }
          expect(tester.takeException(), isNull);
        }
      },
    );
  }
  testWidgets(
    'badge moves with each player and does not intercept playback controls',
    (tester) async {
      var clicks = 0;
      Future<void> pump(Offset offset, Size size) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                Positioned(
                  left: offset.dx,
                  top: offset.dy,
                  width: size.width,
                  height: size.height,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      GestureDetector(
                        onTap: () => clicks++,
                        behavior: HitTestBehavior.opaque,
                        child: const ColoredBox(color: Colors.black),
                      ),
                      const SubtitleStatusBadge(
                        phase: SubtitlePhase.unavailable,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      for (final placement in [
        (const Offset(0, 0), const Size(800, 450)),
        (const Offset(400, 50), const Size(280, 210)),
        (const Offset(100, 300), const Size(100, 60)),
      ]) {
        await pump(placement.$1, placement.$2);
        final badge = find.byKey(const ValueKey('subtitle-status-badge'));
        final rect = tester.getRect(badge);
        expect(rect.left, greaterThanOrEqualTo(placement.$1.dx));
        expect(
          rect.right,
          lessThanOrEqualTo(placement.$1.dx + placement.$2.width),
        );
        await tester.tapAt(rect.center);
        await tester.pump();
        expect(tester.takeException(), isNull);
      }
      expect(clicks, 3);
    },
  );
}
