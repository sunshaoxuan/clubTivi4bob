import 'dart:convert';
import 'dart:io';

import 'package:clubtivi/data/services/windows_update_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('bobtv/updater');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory directory;
  var workerRunning = false;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('bobtv-auth-poll-');
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'isRunning');
      expect(call.arguments, {'pid': 42});
      return workerRunning;
    });
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    await directory.delete(recursive: true);
  });

  Future<WindowsUpdateService> fixture(
    String phase, {
    String request = 'old',
  }) async {
    await File('${directory.path}/status-run.json').writeAsString(
      jsonEncode({
        'version': '1.1.7+100',
        'runId': 'run',
        'workerPid': 42,
        'phase': phase,
        'authorizationRequestId': request,
        'requiresAuthorization': true,
      }),
    );
    final service = WindowsUpdateService.forTesting(
      directory: directory,
      version: '1.1.7+100',
      runId: 'run',
      workerPid: 42,
      installRequestId: 'current',
    );
    service.state.value = const WindowsUpdateState(
      WindowsUpdatePhase.authorizing,
    );
    return service;
  }

  for (final phase in ['ready', 'authorizing', 'awaitingExit']) {
    test(
      'dead helper cannot hide behind stale $phase authorization receipt',
      () async {
        workerRunning = false;
        final service = await fixture(phase);
        await service.pollWorkerStatusForTesting();
        expect(service.state.value.phase, WindowsUpdatePhase.failed);
        expect(service.state.value.canCheck, isTrue);
        expect(service.state.value.message, contains('当前版本保留'));
        service.state.dispose();
      },
    );
  }
  test(
    'live helper cannot close playback using an older consent attempt',
    () async {
      workerRunning = true;
      final service = await fixture('awaitingExit');
      await service.pollWorkerStatusForTesting();
      expect(service.state.value.phase, WindowsUpdatePhase.authorizing);
      service.state.dispose();
    },
  );
  test(
    'acknowledged cancellation makes another explicit attempt available',
    () async {
      workerRunning = true;
      final service = await fixture('ready', request: 'current');
      await service.pollWorkerStatusForTesting();
      expect(service.state.value.phase, WindowsUpdatePhase.ready);
      service.state.dispose();
    },
  );
  test(
    'completed receipt remains completed after normal helper exit',
    () async {
      workerRunning = false;
      final service = await fixture('installed', request: 'current');
      await service.pollWorkerStatusForTesting();
      expect(service.state.value.phase, WindowsUpdatePhase.installed);
      service.state.dispose();
    },
  );
  test(
    'receipt published during process exit wins over stale installing snapshot',
    () async {
      final service = await fixture('installing', request: 'current');
      messenger.setMockMethodCallHandler(channel, (call) async {
        final file = File('${directory.path}/status-run.json');
        final data =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        data['phase'] = 'installed';
        await file.writeAsString(jsonEncode(data));
        return false;
      });
      await service.pollWorkerStatusForTesting();
      expect(service.state.value.phase, WindowsUpdatePhase.installed);
      service.state.dispose();
    },
  );
}
