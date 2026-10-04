import 'dart:async';
import 'dart:io';

import 'package:clubtivi/features/player/desktop_exit_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Mouse exit requests native close once and shows feedback', (
    tester,
  ) async {
    final close = Completer<void>();
    var requests = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DesktopExitButton(
            onClose: () {
              requests++;
              return close.future;
            },
          ),
        ),
      ),
    );
    expect(find.text('退出'), findsOneWidget);
    await tester.tap(find.text('退出'));
    await tester.pump();
    expect(requests, 1);
    expect(find.text('正在退出'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      tester.widget<TextButton>(find.byType(TextButton)).onPressed,
      isNull,
    );
    close.complete();
    await tester.pump();
  });

  testWidgets('A failed close remains retryable', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DesktopExitButton(
            onClose: () async => throw StateError('test'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('退出'));
    await tester.pump();
    expect(find.text('关闭未完成，请重试。'), findsOneWidget);
    expect(
      tester.widget<TextButton>(find.byType(TextButton)).onPressed,
      isNotNull,
    );
  });

  test('All desktop entry points expose the same close control', () {
    final channels = File(
      'lib/features/channels/channels_screen.dart',
    ).readAsStringSync();
    final player = File(
      'lib/features/player/player_screen.dart',
    ).readAsStringSync();
    expect('const DesktopExitButton()'.allMatches(channels).length, 2);
    expect(player, contains('const DesktopExitButton()'));
  });
}
