import 'dart:async';
import 'package:clubtivi/features/channels/channel_card_feedback.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget card(Future<void> Function() tap, {Future<void> Function()? force}) =>
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 260,
            height: 172,
            child: ChannelCardFeedback(
              loading: false,
              onTap: tap,
              onDoubleTap: force ?? () async {},
              builder: (busy) => ColoredBox(
                color: Colors.black,
                child: busy
                    ? const CircularProgressIndicator()
                    : const Text('ready'),
              ),
            ),
          ),
        ),
      );

  testWidgets('pointer down paints spinner before route work starts', (
    tester,
  ) async {
    final done = Completer<void>();
    var clicks = 0;
    await tester.pumpWidget(
      card(() {
        clicks++;
        return done.future;
      }),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('ready')),
    );
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(clicks, 0);
    await gesture.up();
    await tester.pump();
    expect(clicks, 1);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    done.complete();
    await tester.pump();
    expect(find.text('ready'), findsOneWidget);
  });

  testWidgets('second click forces play without a second preview request', (
    tester,
  ) async {
    var preview = 0, force = 0;
    await tester.pumpWidget(
      card(
        () async {
          preview++;
        },
        force: () async {
          force++;
        },
      ),
    );
    final point = tester.getCenter(find.text('ready'));
    await tester.tapAt(point);
    await tester.pump();
    expect(preview, 1);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(point);
    await tester.pump();
    expect(preview, 1);
    expect(force, 1);
  });

  testWidgets('dragging or secondary click does not activate a channel', (
    tester,
  ) async {
    var clicks = 0;
    await tester.pumpWidget(
      card(() async {
        clicks++;
      }),
    );
    final point = tester.getCenter(find.text('ready'));
    final gesture = await tester.startGesture(point);
    await gesture.moveBy(const Offset(40, 0));
    await gesture.up();
    await tester.pump();
    expect(clicks, 0);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.tapAt(point, buttons: kSecondaryMouseButton);
    await tester.pump();
    expect(clicks, 0);
  });

  testWidgets('hover lights the card border', (tester) async {
    await tester.pumpWidget(card(() async {}));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('ready')));
    await tester.pump(const Duration(milliseconds: 180));
    final decorations = tester.widgetList<AnimatedContainer>(
      find.byType(AnimatedContainer),
    );
    expect(
      decorations.any((w) => (w.decoration as BoxDecoration?)?.border != null),
      isTrue,
    );
    await mouse.removePointer();
  });

  testWidgets('disposing a pending card does not update removed state', (
    tester,
  ) async {
    final done = Completer<void>();
    await tester.pumpWidget(card(() => done.future));
    await tester.tap(find.text('ready'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    done.complete();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
