// Development-only native acceptance. No player, network, personal DB or audio.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/features/channels/channel_favorites.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart' show LiveWidgetController, find;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

Future<void> main() async {
  final binding = WidgetsFlutterBinding.ensureInitialized();
  // ignore: invalid_use_of_visible_for_testing_member
  SharedPreferences.setMockInitialValues({});
  final directory = Directory(Platform.environment['BOBTV_FAVORITES_QA_DIR']!);
  await directory.create(recursive: true);
  final checks = <String>[];
  final database = db.AppDatabase.forTesting(NativeDatabase.memory());
  void check(bool passed, String name) {
    if (!passed) throw StateError(name);
    checks.add(name);
  }

  try {
    await windowManager.ensureInitialized();
    await windowManager.setTitle('BobTV 收藏验收（隔离测试，无声音）');
    await windowManager.setSize(const Size(760, 560));
    await database.upsertProvider(
      db.ProvidersCompanion.insert(id: 'qa', name: 'Fixture', type: 'm3u'),
    );
    await database.upsertChannels([
      for (final id in ['a', 'b', 'other'])
        db.ChannelsCompanion.insert(
          id: id,
          providerId: 'qa',
          name: id == 'other' ? 'CCTV-5+' : 'CCTV-6',
          streamUrl: 'https://example.invalid/$id.m3u8',
        ),
    ]);
    await database.addChannelToDefaultFavorites('a');
    await database.addChannelToDefaultFavorites('other');
    final sports = await database.createFavoriteList('验收收藏夹');
    await database.addChannelToList(sports.id, 'a');
    final favorite = ValueNotifier(true);
    BuildContext? pageContext;
    Future<void> refresh() async {
      favorite.value = (await database.getListsForChannel('a')).isNotEmpty;
    }

    runApp(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: Builder(
            builder: (context) {
              pageContext = context;
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('隔离收藏测试，不连接节目源、不播放声音'),
                    ValueListenableBuilder<bool>(
                      valueListenable: favorite,
                      builder: (_, value, _) => TextButton.icon(
                        key: const ValueKey('qa-star'),
                        icon: Icon(value ? Icons.star : Icons.star_outline),
                        label: Text(value ? '取消收藏' : '加入收藏'),
                        onPressed: () => toggleChannelFavorite(
                          context: context,
                          database: database,
                          channelId: 'a',
                          isFavorite: value,
                          onChanged: refresh,
                        ),
                      ),
                    ),
                    TextButton(
                      key: const ValueKey('qa-manage'),
                      child: const Text('管理收藏夹'),
                      onPressed: () => showChannelFavoriteListSheet(
                        context: context,
                        database: database,
                        channelId: 'a',
                        channelName: '测试频道',
                        createListName: () async => null,
                        onChanged: refresh,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
    await windowManager.show();
    await windowManager.focus();
    await Future<void>.delayed(const Duration(milliseconds: 350));
    final driver = LiveWidgetController(binding);
    Future<void> frame() async {
      await driver.pump();
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }

    Future<void> until(FutureOr<bool> Function() predicate) async {
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (!await predicate()) {
        if (DateTime.now().isAfter(deadline)) {
          throw TimeoutException('native favorite acceptance');
        }
        await frame();
      }
      await frame();
    }

    Future<void> open() async {
      await driver.tap(
        find.byKey(const ValueKey('qa-manage')),
        kind: PointerDeviceKind.mouse,
      );
      await until(
        () => find.byType(ChannelFavoriteListSheet).evaluate().isNotEmpty,
      );
      await Future<void>.delayed(const Duration(milliseconds: 350));
      await frame();
    }

    Future<void> close() async {
      await driver.tap(find.byTooltip('关闭'), kind: PointerDeviceKind.mouse);
      await until(
        () => find.byType(ChannelFavoriteListSheet).evaluate().isEmpty,
      );
      await Future<void>.delayed(const Duration(milliseconds: 350));
    }

    CheckboxListTile current(String id) =>
        (find.byKey(ValueKey('favorite-list-$id')).evaluate().single.widget
            as CheckboxListTile);
    Future<void> checkbox(String id) async {
      await driver.tap(
        find.descendant(
          of: find.byKey(ValueKey('favorite-list-$id')),
          matching: find.byType(Checkbox),
        ),
        kind: PointerDeviceKind.mouse,
      );
      await frame();
    }

    await until(() => pageContext != null);
    await open();
    await checkbox('default');
    check(
      current('default').value == false,
      'trailing_checkbox_unchecks_on_first_mouse_click',
    );
    await until(
      () async =>
          !await database.isChannelInList('default', 'a') &&
          current('default').onChanged != null,
    );
    check(
      await database.isChannelInList(sports.id, 'a'),
      'other_list_preserved',
    );
    await database.reconcileFavoriteMemberships(force: true);
    check(
      !await database.isChannelInList('default', 'a'),
      'background_reconcile_does_not_readd',
    );
    await close();
    await open();
    check(
      current('default').value == false,
      'reopen_keeps_unchecked_membership',
    );
    await checkbox('default');
    await until(
      () async =>
          await database.isChannelInList('default', 'a') &&
          current('default').onChanged != null,
    );
    await close();
    await driver.tap(
      find.byKey(const ValueKey('qa-star')),
      kind: PointerDeviceKind.mouse,
    );
    await until(() => !favorite.value);
    check(
      find.byType(ChannelFavoriteListSheet).evaluate().isEmpty,
      'star_removes_without_opening_management',
    );
    check(
      (await database.getListsForChannel('a')).isEmpty,
      'one_click_removes_all_lists',
    );
    check(
      await database.isChannelInList('default', 'other'),
      'unrelated_service_preserved',
    );
    await until(() => find.text('撤销').evaluate().isNotEmpty);
    await driver.tap(find.text('撤销'), kind: PointerDeviceKind.mouse);
    await until(() => favorite.value);
    check(
      (await database.getListsForChannel('a')).length == 2,
      'undo_restores_original_lists',
    );
    await open();
    await driver.tap(find.text('取消全部收藏'), kind: PointerDeviceKind.mouse);
    await until(
      () async =>
          (await database.getListsForChannel('a')).isEmpty && !favorite.value,
    );
    await close();
    await open();
    check(
      current('default').value == false && current(sports.id).value == false,
      'opening_empty_management_does_not_add_favorite',
    );
    await close();
    await driver.tap(
      find.byKey(const ValueKey('qa-star')),
      kind: PointerDeviceKind.mouse,
    );
    await until(() => favorite.value);
    check(
      await database.isChannelInList('default', 'b'),
      'one_click_add_includes_same_service_routes',
    );
    await Future.wait([
      database.reconcileFavoriteMemberships(force: true),
      database.removeChannelFromAllFavorites('a'),
    ]);
    check(
      (await database.getListsForChannel('a')).isEmpty,
      'concurrent_remove_and_reconcile_stays_removed',
    );
    check(
      (await database.getAllChannels()).length == 3,
      'source_rows_preserved',
    );
    await database.close();
    await File('${directory.path}/result.json').writeAsString(
      jsonEncode({
        'state': 'passed',
        'os': Platform.operatingSystem,
        'checks': checks,
        'audioPlaybackStarted': false,
        'networkRequests': 0,
        'personalDatabaseOpened': false,
        'checkedAtUtc': DateTime.now().toUtc().toIso8601String(),
      }),
    );
    exit(0);
  } catch (error, stack) {
    await File('${directory.path}/result.json').writeAsString(
      jsonEncode({
        'state': 'failed',
        'os': Platform.operatingSystem,
        'checks': checks,
        'error': error.toString(),
        'stack': stack.toString(),
      }),
    );
    exit(1);
  }
}
