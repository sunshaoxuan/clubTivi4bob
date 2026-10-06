import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clubtivi/features/settings/settings_design.dart';
import 'package:clubtivi/features/settings/settings_screen.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:clubtivi/features/settings/ai_configuration_screen.dart';
import 'package:clubtivi/features/settings/debrid_services_screen.dart';
import 'package:clubtivi/features/providers/provider_manager.dart';
import 'package:clubtivi/data/datasources/local/database.dart';
import 'package:drift/native.dart';

class _RetainedForm extends StatefulWidget {
  const _RetainedForm({required this.onMount});
  final VoidCallback onMount;
  @override
  State<_RetainedForm> createState() => _RetainedFormState();
}

class _RetainedFormState extends State<_RetainedForm> {
  final controller = TextEditingController();
  @override
  void initState() {
    super.initState();
    widget.onMount();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      TextField(key: const ValueKey('retained-form'), controller: controller);
}

void main() {
  List<Override> isolatedDatabase() => [
    databaseProvider.overrideWith((ref) {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      ref.onDispose(database.close);
      return database;
    }),
  ];
  testWidgets('AI detail saves safely and masks the key', (tester) async {
    SharedPreferences.setMockInitialValues({'bobtv_ai_enabled_v1': false});
    FlutterSecureStorage.setMockInitialValues({});
    await tester.pumpWidget(const MaterialApp(home: AiConfigurationScreen()));
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(3));
    await tester.enterText(fields.at(0), 'https://example.com/v1');
    await tester.enterText(fields.at(1), 'test-model');
    await tester.enterText(fields.at(2), 'dummy-test-key');
    expect(tester.widget<TextField>(fields.at(2)).obscureText, isTrue);
    await tester.ensureVisible(find.text('保存设置'));
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();
    expect(
      (await SharedPreferences.getInstance()).getString('bobtv_ai_model_v1'),
      'test-model',
    );
    expect(find.text('dummy-test-key'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Debrid detail lays out in a narrow window', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(480, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: isolatedDatabase(),
        child: const MaterialApp(home: DebridServicesScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Debrid 服务'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final width in [480.0, 1200.0, 3840.0]) {
    testWidgets('all real settings categories at width $width', (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: isolatedDatabase(),
          child: MaterialApp(
            theme: ThemeData.dark(),
            home: const SettingsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (var category = 0; category < settingsCategories.length; category++) {
        final target = find.byKey(ValueKey('settings-category-$category'));
        await tester.ensureVisible(target);
        await tester.tap(target);
        await tester.pumpAndSettle();
        expect(
          tester.takeException(),
          isNull,
          reason: 'category $category at width $width',
        );
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('real settings retain saved playback, clock and EPG options', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'playback_buffer_size': '8 MB (Large)',
      'playback_user_agent': 'BobTV-test-agent',
      'failover_mode': 'warm',
      'use_24_hour_time': true,
      'epg_auto_refresh_hours': 6,
    });
    tester.view.physicalSize = const Size(1200, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: isolatedDatabase(),
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: const SettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('管理电视源'), findsOneWidget);
    expect(find.text('节目单映射'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('settings-category-1')));
    await tester.pumpAndSettle();
    expect(find.text('BobTV-test-agent'), findsOneWidget);
    expect(find.text('8 MB (Large)'), findsOneWidget);
    await tester.tap(find.text('缓冲大小'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('4 MB (Medium)'));
    await tester.pumpAndSettle();
    expect(
      (await SharedPreferences.getInstance()).getString('playback_buffer_size'),
      '4 MB (Medium)',
    );
    await tester.tap(find.byKey(const ValueKey('settings-category-2')));
    await tester.pumpAndSettle();
    expect(find.text('14:30'), findsOneWidget);
    await tester.tap(find.text('24 小时制'));
    await tester.pumpAndSettle();
    expect(
      (await SharedPreferences.getInstance()).getBool('use_24_hour_time'),
      false,
    );
    await tester.tap(find.byKey(const ValueKey('settings-category-4')));
    await tester.pumpAndSettle();
    final firstSave = find.widgetWithText(FilledButton, '保存').first;
    expect(tester.widget<FilledButton>(firstSave).onPressed, isNull);
    await tester.enterText(find.byType(TextFormField).first, 'dummy-test-key');
    await tester.pump();
    expect(tester.widget<FilledButton>(firstSave).onPressed, isNotNull);
    await tester.tap(find.byKey(const ValueKey('settings-category-5')));
    await tester.pumpAndSettle();
    expect(find.text('导出备份'), findsOneWidget);
    expect(find.text('导入备份'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('settings-category-6')));
    await tester.pumpAndSettle();
    expect(find.text('源代码'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  Future<void> pump(
    WidgetTester tester, {
    double width = 1200,
    double scale = 1,
    List<Widget>? sections,
    VoidCallback? onBack,
  }) async {
    tester.view.physicalSize = Size(width, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark().copyWith(
          textTheme: ThemeData.dark().textTheme.apply(
            fontFamily: 'SettingsPreview',
          ),
        ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: RepaintBoundary(
          key: const ValueKey('settings-preview'),
          child: SettingsWorkspace(
            onBack: onBack ?? () {},
            sections:
                sections ??
                [
                  for (var i = 0; i < 11; i++)
                    SettingsPanel(
                      title: '设置分区 $i',
                      children: [
                        ListTile(
                          title: Text('功能 $i'),
                          subtitle: const Text('设置说明'),
                          onTap: () {},
                        ),
                      ],
                    ),
                ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  test('every existing section belongs to exactly one category', () {
    final indices =
        settingsCategories.expand((category) => category.sections).toList()
          ..sort();
    expect(indices, List.generate(11, (index) => index));
  });

  for (final width in [360.0, 752.0, 1200.0, 3840.0]) {
    testWidgets('settings layout at width $width', (tester) async {
      await pump(tester, width: width);
      expect(find.byTooltip('返回频道'), findsOneWidget);
      expect(find.text('功能 0'), findsOneWidget);
      expect(find.text('功能 3'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final last = find.byKey(const ValueKey('settings-category-6'));
      await tester.ensureVisible(last);
      await tester.tap(last);
      await tester.pumpAndSettle();
      expect(find.text('功能 9'), findsOneWidget);
      expect(find.text('功能 0'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('large text wraps without overflow', (tester) async {
    await pump(tester, width: 752, scale: 1.8);
    expect(tester.takeException(), isNull);
  });

  testWidgets('lazy categories retain unsaved forms and do not remount', (
    tester,
  ) async {
    var mounts = 0;
    final sections = List<Widget>.generate(11, (i) => Text('section-$i'));
    sections[2] = _RetainedForm(onMount: () => mounts++);
    await pump(tester, sections: sections);
    expect(mounts, 0);
    await tester.tap(find.byKey(const ValueKey('settings-category-4')));
    await tester.pumpAndSettle();
    expect(mounts, 1);
    await tester.enterText(
      find.byKey(const ValueKey('retained-form')),
      'unsaved',
    );
    await tester.tap(find.byKey(const ValueKey('settings-category-0')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('retained-form')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('settings-category-4')));
    await tester.pumpAndSettle();
    expect(find.text('unsaved'), findsOneWidget);
    expect(mounts, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mouse back and setting actions respond immediately', (
    tester,
  ) async {
    var backs = 0;
    var actions = 0;
    final sections = List<Widget>.generate(11, (i) => const SizedBox());
    sections[0] = SettingsPanel(
      title: '电视源',
      children: [ListTile(title: const Text('管理电视源'), onTap: () => actions++)],
    );
    await pump(tester, sections: sections, onBack: () => backs++);
    await tester.tap(find.text('管理电视源'));
    expect(actions, 1);
    await tester.tap(find.byTooltip('返回频道'));
    expect(backs, 1);
  });

  testWidgets('settings dialogs use the new visual language', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showSettingsDialog<void>(
                context: context,
                builder: (_) => const AlertDialog(
                  title: Text('缓冲大小'),
                  content: Text('保留现有选项'),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('缓冲大小'), findsOneWidget);
    final context = tester.element(find.byType(AlertDialog));
    expect(Theme.of(context).colorScheme.primary, SettingsDesign.accent);
    expect(tester.takeException(), isNull);
  });

  if (Platform.environment['BOBTV_SETTINGS_VISUAL'] == '1') {
    testWidgets('desktop settings visual preview', (tester) async {
      await tester.runAsync(() async {
        final loader = FontLoader('SettingsPreview')
          ..addFont(
            File(
              '/System/Library/Fonts/STHeiti Medium.ttc',
            ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
          );
        await loader.load();
        final icons = FontLoader('MaterialIcons');
        icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
        await icons.load();
      });
      await pump(
        tester,
        sections: [
          SettingsPanel(
            title: '电视源',
            children: [
              ListTile(
                leading: const Icon(Icons.dns_rounded),
                title: const Text('管理电视源'),
                subtitle: const Text('管理 M3U、Xtream 与免费电视源'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {},
              ),
            ],
          ),
          const SizedBox(),
          const SizedBox(),
          SettingsPanel(
            title: '节目单',
            children: [
              ListTile(
                leading: const Icon(Icons.source_rounded),
                title: const Text('节目单来源'),
                subtitle: const Text('管理 XMLTV 节目单'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {},
              ),
              ListTile(
                leading: const Icon(Icons.link_rounded),
                title: const Text('节目单映射'),
                subtitle: const Text('管理频道与节目单的对应关系'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {},
              ),
              ListTile(
                leading: const Icon(Icons.update_rounded),
                title: const Text('自动刷新间隔'),
                subtitle: const Text('每 6 小时'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {},
              ),
            ],
          ),
          for (var i = 4; i < 11; i++) const SizedBox(),
        ],
      );
      await expectLater(
        find.byKey(const ValueKey('settings-preview')),
        matchesGoldenFile('/tmp/bobtv-settings-preview.png'),
      );
    });
  }
}
