import 'dart:convert';
import 'dart:io';

import 'package:clubtivi/core/app_version.dart';
import 'package:clubtivi/core/resource_node_router.dart';
import 'package:clubtivi/data/services/bobtv_api_client.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// Explicit synthetic traffic only. Never reads device logs or opens media.
void main() {
  test(
    'shared client accepts private public-node receipts and catalog hashes',
    () async {
      HttpOverrides.global = null;
      final api = BobTvApiClient(recordDiagnostics: false);
      addTearDown(api.close);
      final body = utf8.encode(
        jsonEncode({
          'schemaVersion': 2,
          'consentVersion': 2,
          'installationId': 'e' * 32,
          'entries': [
            {
              'time': DateTime.now().toUtc().toIso8601String(),
              'event': 'diagnostic_canary',
              'platform': 'macos',
              'appVersion': bobTvVersion,
              'phase': 'complete',
              'node': 'local',
              'endpoint': 'catalog_manifest',
            },
          ],
        }),
      );
      final digest = sha256.convert(body).toString();
      final primary = await api.uploadDiagnosticBatch(
        body,
        node: ResourceNodeRouter.primary,
      );
      expect(primary['state'], 'origin_accepted');
      final relay = await api.uploadDiagnosticBatch(
        body,
        node: ResourceNodeRouter.relay,
      );
      expect(relay['id'], digest);
      Map<String, dynamic>? receipt;
      for (var attempt = 0; attempt < 12; attempt++) {
        receipt = await api.diagnosticReceipt(
          digest,
          node: ResourceNodeRouter.relay,
        );
        if (receipt?['state'] == 'origin_accepted') break;
        await Future<void>.delayed(const Duration(seconds: 6));
      }
      expect(receipt?['state'], 'origin_accepted');
      final manifest = await api.fetchChannelCatalogManifest();
      expect(manifest, isNotNull);
      final snapshot = await api.downloadChannelCatalog(manifest!);
      expect(sha256.convert(snapshot).toString(), manifest.sha256);
      final output = Platform.environment['BOBTV_DIAGNOSTIC_CANARY_RECEIPT'];
      if (output != null) {
        await File(output).writeAsString(
          jsonEncode({
            'passed': true,
            'version': bobTvVersion,
            'id': digest,
            'primaryReceipt': primary,
            'relayReceipt': receipt,
            'catalogVersion': manifest.version,
            'snapshotSha256': manifest.sha256,
            'snapshotBytes': snapshot.length,
            'syntheticOnly': true,
            'logsRead': false,
            'mediaOpened': false,
          }),
        );
      }
    },
    skip: Platform.environment['BOBTV_DIAGNOSTICS_CANARY'] != '1',
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
