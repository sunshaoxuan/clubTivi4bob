import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clubtivi/data/services/desktop_update_state.dart';
import 'package:clubtivi/features/settings/desktop_update_check_tile.dart';

void main() {
  test('Checks cannot overwrite a pending download or installation', () {
    for (final phase in WindowsUpdatePhase.values) {
      final state = WindowsUpdateState(phase);
      if (state.busy || phase == WindowsUpdatePhase.ready) {
        expect(state.canCheck, isFalse, reason: phase.name);
      }
    }
    expect(
      const WindowsUpdateState(WindowsUpdatePhase.manualRequired).busy,
      isFalse,
    );
    expect(
      const WindowsUpdateState(WindowsUpdatePhase.upToDate).canCheck,
      isTrue,
    );
  });

  testWidgets('Manual check shows immediate spinner and actual result', (
    tester,
  ) async {
    final state = ValueNotifier(
      const WindowsUpdateState(WindowsUpdatePhase.idle),
    );
    var checks = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DesktopUpdateCheckTile(
            state: state,
            onCheck: () async {
              checks++;
              state.value = const WindowsUpdateState(
                WindowsUpdatePhase.checking,
              );
            },
          ),
        ),
      ),
    );
    await tester.tap(find.text('检查更新'));
    await tester.pump();
    expect(find.text('正在检查更新'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.tap(find.text('正在检查更新'));
    expect(checks, 1);
    state.value = const WindowsUpdateState(WindowsUpdatePhase.upToDate);
    await tester.pump();
    expect(find.text('已是最新版本'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    state.value = const WindowsUpdateState(
      WindowsUpdatePhase.failed,
      message: '连接超时',
    );
    await tester.pump();
    expect(find.text('连接超时'), findsOneWidget);
    state.value = const WindowsUpdateState(WindowsUpdatePhase.manualRequired);
    await tester.pump();
    expect(find.text('更新服务暂未就绪'), findsOneWidget);
    expect(find.text('重试更新'), findsOneWidget);
    expect(find.text('下载安装包'), findsNothing);
    await tester.tap(find.text('重试更新'));
    expect(checks, 2);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  testWidgets(
    'managed update stays in the app and only offers install when ready',
    (tester) async {
      final state = ValueNotifier(
        const WindowsUpdateState(
          WindowsUpdatePhase.downloading,
          requiresAuthorization: true,
          percent: 30,
        ),
      );
      var installs = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DesktopUpdateCheckTile(
              state: state,
              onCheck: () async {},
              onInstall: () async {
                installs++;
              },
            ),
          ),
        ),
      );
      expect(find.text('安装更新'), findsNothing);
      state.value = const WindowsUpdateState(
        WindowsUpdatePhase.ready,
        requiresAuthorization: true,
      );
      await tester.pump();
      expect(find.textContaining('Windows 提示中授权'), findsOneWidget);
      await tester.tap(find.text('安装更新'));
      expect(installs, 1);
      state.value = const WindowsUpdateState(
        WindowsUpdatePhase.authorizing,
        requiresAuthorization: true,
      );
      await tester.pump();
      expect(find.text('等待 Windows 授权'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      state.value = const WindowsUpdateState(
        WindowsUpdatePhase.awaitingExit,
        requiresAuthorization: true,
      );
      await tester.pump();
      await tester.tap(find.text('退出并安装'));
      expect(installs, 2);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );
}
