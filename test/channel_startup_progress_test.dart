import 'package:clubtivi/features/channels/channel_startup_progress.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('channel initialization does not repeat the splash logo', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: ChannelStartupProgress(status: '正在载入央视…')),
    );
    expect(find.byType(Image), findsNothing);
    expect(find.text('BobTV'), findsNothing);
    expect(find.text('正在载入央视…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pumpWidget(
      const MaterialApp(home: ChannelStartupProgress(status: '正在同步频道 50/100')),
    );
    expect(find.text('正在同步频道 50/100'), findsOneWidget);
    expect(find.text('正在载入央视…'), findsNothing);
  });

  testWidgets('initialization always has a readable status', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: ChannelStartupProgress(status: '')),
    );
    expect(find.text('正在载入频道…'), findsOneWidget);
  });
}
