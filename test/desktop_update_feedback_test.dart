import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clubtivi/data/services/desktop_update_state.dart';
import 'package:clubtivi/features/channels/desktop_update_badge.dart';

void main() {
  test(
    'Only downloaded and verified updates promise installation on close',
    () {
      for (final phase in [
        WindowsUpdatePhase.available,
        WindowsUpdatePhase.starting,
        WindowsUpdatePhase.downloading,
        WindowsUpdatePhase.verifying,
      ]) {
        final state = WindowsUpdateState(phase);
        expect(state.busy, isTrue);
        expect(state.description.contains('关闭 BobTV 后自动安装'), isFalse);
      }
      expect(
        const WindowsUpdateState(WindowsUpdatePhase.ready).description,
        contains('关闭 BobTV 后自动安装'),
      );
      expect(
        const WindowsUpdateState(WindowsUpdatePhase.installed).busy,
        isFalse,
      );
    },
  );

  test(
    'Worker states reject stale versions, old runs, other PIDs and unknown phases',
    () {
      final payload = <String, dynamic>{
        'version': '0.9.1+73',
        'runId': 'new-run',
        'workerPid': 42,
        'phase': 'downloading',
        'percent': 26,
        'receivedBytes': 1000,
        'totalBytes': 4000,
      };
      WindowsUpdateState? parse(Map<String, dynamic> data) =>
          WindowsUpdateState.fromWorkerStatus(
            data,
            version: '0.9.1+73',
            runId: 'new-run',
            workerPid: 42,
          );
      expect(parse(payload)?.percent, 26);
      expect(parse(payload)?.receivedBytes, 1000);
      for (final edit in [
        {'version': '0.9.1+72'},
        {'runId': 'old-run'},
        {'workerPid': 43},
        {'phase': 'made-up'},
      ]) {
        expect(parse({...payload, ...edit}), isNull);
      }
      expect(parse({...payload, 'percent': 200})?.percent, 100);
    },
  );

  test(
    'All stages have distinct labels and completion is separate from readiness',
    () {
      for (final entry in {
        'starting': WindowsUpdatePhase.starting,
        'downloading': WindowsUpdatePhase.downloading,
        'verifying': WindowsUpdatePhase.verifying,
        'ready': WindowsUpdatePhase.ready,
        'backingUp': WindowsUpdatePhase.backingUp,
        'installing': WindowsUpdatePhase.installing,
        'installed': WindowsUpdatePhase.installed,
        'failed': WindowsUpdatePhase.failed,
      }.entries) {
        expect(
          WindowsUpdateState.fromWorkerStatus({
            'version': 'v',
            'phase': entry.key,
          }, version: 'v')?.phase,
          entry.value,
        );
      }
    },
  );

  testWidgets(
    'Spinner appears immediately, live percentage updates, failure offers retry',
    (tester) async {
      final state = ValueNotifier(
        const WindowsUpdateState(
          WindowsUpdatePhase.starting,
          version: '0.9.1+73',
        ),
      );
      var retries = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DesktopUpdateBadge(
              state: state,
              onRetry: () => retries++,
              showPostExitProgress: true,
            ),
          ),
        ),
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('准备下载更新'), findsOneWidget);
      await tester.tap(find.text('准备下载更新'));
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      state.value = const WindowsUpdateState(
        WindowsUpdatePhase.downloading,
        version: '0.9.1+73',
        percent: 37,
        receivedBytes: 1048576,
        totalBytes: 2097152,
      );
      await tester.pump();
      expect(find.text('正在下载 37%'), findsNWidgets(2));
      expect(find.text('1.0 / 2.0 MB'), findsOneWidget);
      state.value = const WindowsUpdateState(
        WindowsUpdatePhase.failed,
        version: '0.9.1+73',
        message: '助手意外退出',
      );
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('助手意外退出'), findsOneWidget);
      await tester.tap(find.text('重试更新'));
      expect(retries, 1);
      state.value = const WindowsUpdateState(
        WindowsUpdatePhase.ready,
        version: '0.9.1+73',
      );
      await tester.pump();
      expect(find.textContaining('已下载并校验通过'), findsOneWidget);
      expect(find.text('重试更新'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );
}
