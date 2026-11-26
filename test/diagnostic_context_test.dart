import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:clubtivi/core/diagnostic_context.dart';
import 'package:clubtivi/core/diagnostic_log_store.dart';

void main() {
  test('route error retains errno and code locations without source secrets', () {
    final fields = DiagnosticFailure.describe(
      const SocketException(
        'private address and token',
        osError: OSError('No route to host', 65),
      ),
      StackTrace.fromString(
        '#0 send (dart:io-patch/socket_patch.dart:1513:7)\n'
        '#1 search (package:clubtivi/features/casting/dlna_discovery.dart:70:9)\n'
        '#2 private (/Users/person/private.dart:1:2)',
      ),
    );
    final safe = DiagnosticProjection.project({
      ...fields,
      'event': 'cast_dlna_search_send_failed',
      'time': DateTime.now().toUtc().toIso8601String(),
    }, DateTime.now())!;
    expect(safe['errorCode'], 'no_route');
    expect(safe['osErrorCode'], 65);
    expect(safe['stackFrames'], contains('dlna_discovery.dart:70:9'));
    expect(jsonEncode(safe), isNot(contains('private')));
    expect(jsonEncode(safe), isNot(contains('/Users/')));
  });

  test('subnet comparisons use the observed mask and address family', () {
    expect(
      DiagnosticNetwork.sameSubnet('192.168.0.2', '192.168.1.3', 23),
      true,
    );
    expect(
      DiagnosticNetwork.sameSubnet('192.168.0.2', '192.168.1.3', 24),
      false,
    );
    expect(DiagnosticNetwork.sameSubnet('fd00::1', 'fd00::2', 64), true);
    expect(
      () => DiagnosticNetwork.sameSubnet('127.0.0.1', '::1', 24),
      throwsFormatException,
    );
  });

  test('Mac memory parser distinguishes free and reclaimable memory', () {
    final fields = DiagnosticEnvironment.parseMacMemory(
      'Mach Virtual Memory Statistics: (page size of 4096 bytes)\n'
      'Pages free: 10.\nPages inactive: 20.\nPages speculative: 5.\n'
      'Pages occupied by compressor: 3.\n',
    );
    expect(fields['freeMemoryBytes'], 10 * 4096);
    expect(fields['reclaimableMemoryBytes'], 35 * 4096);
    expect(fields['compressedMemoryBytes'], 3 * 4096);
  });

  test(
    'environment and network fields survive client projection for server validation',
    () async {
      final original = {
        ...await DiagnosticEnvironment.instance.sample(),
        ...await DiagnosticNetwork.inspect('127.0.0.1', port: 7000),
        'event': 'diagnostic_environment',
        'time': DateTime.now().toUtc().toIso8601String(),
        'sessionId': 'ab' * 16,
        'incidentId': 'cd' * 16,
        'errorType': 'FileNotFoundError',
        'errorCode': 'missing_dependency',
        'nativeStackFrames': 'video_relay:start:45',
        'processExitCode': -9,
        'ffmpegAvailable': false,
      };
      final safe = DiagnosticProjection.project(original, DateTime.now())!;
      expect(safe['errorCode'], 'missing_dependency');
      expect(safe['cpuLogicalCores'], greaterThan(0));
      expect(
        safe['totalMemoryBytes'],
        Platform.isMacOS ? greaterThan(0) : anything,
      );
      expect(safe['nativeStackFrames'], 'video_relay:start:45');
      expect(safe['processExitCode'], -9);
      expect(safe['ffmpegAvailable'], false);
      if (Platform.isMacOS) {
        expect(safe['sameSubnet'], true);
        expect(safe['prefixLength'], isNotNull);
      }
      final path = Platform.environment['BOBTV_DIAGNOSTIC_FIXTURE'];
      if (path != null)
        await File(path).writeAsString(
          jsonEncode({
            'schemaVersion': 2,
            'consentVersion': 2,
            'installationId': 'ab' * 16,
            'entries': [safe],
          }),
        );
    },
  );
}
