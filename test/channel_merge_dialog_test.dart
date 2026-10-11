import 'dart:io';
import 'dart:ui' as ui;
import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/services/channel_merge.dart';
import 'package:clubtivi/features/channels/channel_merge_dialog.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'channel_merge_test.dart' show seedMerge, a;

void main() {
  testWidgets('cross-category multi-select, rename, review and save', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    await tester.runAsync(() => seedMerge(database));
    final channel = await tester.runAsync(
      () async => (await database.getChannelsByIds({'one'})).single,
    );
    tester.view.physicalSize = const Size(1080, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    ChannelMergePlan? saved;
    final boundary = GlobalKey();
    final path = Platform.environment['BOBTV_MERGE_SCREENSHOT'];
    var theme = ThemeData.dark();
    if (path != null) {
      await tester.runAsync(() async {
        final font = FontLoader('MergePreview');
        font.addFont(
          Future.value(
            ByteData.sublistView(
              await File(
                '/System/Library/Fonts/STHeiti Light.ttc',
              ).readAsBytes(),
            ),
          ),
        );
        await font.load();
        final icons = FontLoader('MaterialIcons');
        icons.addFont(Future.value(ByteData.sublistView(await File(
          '/Users/shou/.local/opt/flutter-3.44.6/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf').readAsBytes())));
        await icons.load();
      });
      theme = theme.copyWith(
        textTheme: theme.textTheme.apply(fontFamily: 'MergePreview'),
      );
    }
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  saved = await showDialog<ChannelMergePlan>(
                    context: context,
                    builder: (_) => ChannelMergeDialog(
                      database: database,
                      channel: channel!,
                      seedUrls: [a],
                    ),
                  );
                },
                child: const Text('打开合并'),
              ),
            ),
          ),
        ),
      ),
    );
    Future<void> ready() async {
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await tester.tap(find.text('打开合并'));
    await ready();
    expect(find.text('News Alias'), findsNothing);
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全部分类').last);
    await ready();
    await tester.tap(find.text('News Alias'));
    await tester.pump();
    await tester.tap(find.text('Third'));
    await tester.pump();
    await tester.tap(find.text('下一步'));
    await ready();
    expect(find.text('3 个频道 · 3 条去重线路'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '合并后的新闻台');
    await tester.pump();
    if (path != null) {
      final render =
          boundary.currentContext!.findRenderObject() as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await render.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(path).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('合并频道'));
    await ready();
    expect(saved?.name, '合并后的新闻台');
    expect(saved?.urls, hasLength(3));
    final events = await tester.runAsync(database.pendingSharedEvents);
    expect(events?.single['kind'], 'merge');
  });
}
