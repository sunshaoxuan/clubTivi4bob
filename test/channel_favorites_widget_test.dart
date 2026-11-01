import 'dart:async';

import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/features/channels/channel_favorites.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final lists = [
  db.FavoriteList(
    id: 'default',
    name: '我的收藏',
    sortOrder: 0,
    icon: 'star',
    createdAt: DateTime.utc(2030),
  ),
  db.FavoriteList(
    id: 'sports',
    name: '体育',
    sortOrder: 1,
    icon: 'star',
    createdAt: DateTime.utc(2030),
  ),
];

Future<void> openSheet(
  WidgetTester tester, {
  Set<String> selected = const {'default'},
  Future<void> Function(String, bool)? change,
  Future<void> Function()? removeAll,
  List<db.FavoriteList>? choices,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              builder: (_) => ChannelFavoriteListSheet(
                channelName: 'Fixture TV',
                lists: choices ?? lists,
                selectedIds: selected,
                onMembershipChanged: change ?? (_, _) async {},
                onRemoveAll: removeAll ?? () async {},
                onCreate: () async => null,
              ),
            ),
            child: const Text('管理'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('管理'));
  await tester.pumpAndSettle();
}

CheckboxListTile tile(WidgetTester tester, String id) =>
    tester.widget(find.byKey(ValueKey('favorite-list-$id')));

void main() {
  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.android,
  ]) {
    testWidgets(
      '$platform trailing checkbox unchecks immediately and saves once',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final saving = Completer<void>();
        final calls = <String>[];
        await openSheet(
          tester,
          change: (id, checked) async {
            calls.add('$id:$checked');
            await saving.future;
          },
        );
        await tester.tap(
          find.descendant(
            of: find.byKey(const ValueKey('favorite-list-default')),
            matching: find.byType(Checkbox),
          ),
        );
        await tester.pump();
        expect(tile(tester, 'default').value, isFalse);
        expect(tile(tester, 'default').onChanged, isNull);
        expect(calls, ['default:false']);
        saving.complete();
        await tester.pumpAndSettle();
        expect(tile(tester, 'default').value, isFalse);
        expect(tile(tester, 'default').onChanged, isNotNull);
        await tester.tap(find.text('我的收藏'));
        await tester.pumpAndSettle();
        expect(tile(tester, 'default').value, isTrue);
        expect(calls, ['default:false', 'default:true']);
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }

  testWidgets('save errors restore the checkbox and show a retryable error', (
    tester,
  ) async {
    await openSheet(
      tester,
      change: (_, _) async => throw StateError('fixture write failed'),
    );
    await tester.tap(find.text('我的收藏'));
    await tester.pumpAndSettle();
    expect(tile(tester, 'default').value, isTrue);
    expect(find.text('修改收藏失败，请重试'), findsOneWidget);
    expect(tile(tester, 'default').onChanged, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'two list changes paint immediately while writes remain serialized',
    (tester) async {
      final first = Completer<void>();
      final calls = <String>[];
      await openSheet(
        tester,
        selected: {'default', 'sports'},
        change: (id, checked) async {
          calls.add('$id:$checked');
          if (id == 'default') await first.future;
        },
      );
      await tester.tap(find.text('我的收藏'));
      await tester.pump();
      await tester.tap(find.text('体育'));
      await tester.pump();
      expect(tile(tester, 'default').value, isFalse);
      expect(tile(tester, 'sports').value, isFalse);
      expect(calls, ['default:false']);
      first.complete();
      await tester.pumpAndSettle();
      expect(calls, ['default:false', 'sports:false']);
    },
  );

  testWidgets(
    'closing during a write still finishes without setState after dispose',
    (tester) async {
      final saving = Completer<void>();
      var finished = false;
      await openSheet(
        tester,
        change: (_, _) async {
          await saving.future;
          finished = true;
        },
      );
      await tester.tap(find.text('我的收藏'));
      await tester.pump();
      await tester.tap(find.byTooltip('关闭'));
      await tester.pump(const Duration(milliseconds: 400));
      saving.complete();
      await tester.pumpAndSettle();
      expect(finished, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('empty selection never implicitly adds favorites', (
    tester,
  ) async {
    var writes = 0;
    await openSheet(
      tester,
      selected: {},
      change: (_, _) async {
        writes++;
      },
    );
    expect(tile(tester, 'default').value, isFalse);
    expect(tile(tester, 'sports').value, isFalse);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(writes, 0);
  });

  testWidgets('all favorites can be removed with one management action', (
    tester,
  ) async {
    var clears = 0;
    await openSheet(
      tester,
      selected: {'default', 'sports'},
      removeAll: () async {
        clears++;
      },
    );
    await tester.tap(find.text('取消全部收藏'));
    await tester.pumpAndSettle();
    expect(clears, 1);
    expect(tile(tester, 'default').value, isFalse);
    expect(tile(tester, 'sports').value, isFalse);
  });

  testWidgets('many lists scroll within a small desktop window', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(600, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await openSheet(
      tester,
      choices: [
        for (var i = 0; i < 30; i++)
          db.FavoriteList(
            id: '$i',
            name: '收藏夹$i',
            sortOrder: i,
            icon: 'star',
            createdAt: DateTime.utc(2030),
          ),
      ],
    );
    await tester.ensureVisible(find.text('收藏夹29'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
