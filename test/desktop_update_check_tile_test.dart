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
    expect(find.text('升级需要授权'), findsOneWidget);
    expect(find.text('下载安装包'), findsOneWidget);
    state.dispose();
  });
}
