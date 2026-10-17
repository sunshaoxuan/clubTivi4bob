import 'dart:convert';
import 'dart:io';

import 'package:clubtivi/data/models/server_epg_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final late = Platform.environment['BOBTV_LIVE_EPG_LATE_CAPTURE'];
  final fresh = Platform.environment['BOBTV_LIVE_EPG_SECOND_CAPTURE'];

  Future<Map<String, Object>> input(String path) async {
    final capture = jsonDecode(await File(path).readAsString()) as Map;
    return {
      'bytes': base64Decode(capture['snapshotBase64'] as String),
      'manifest': capture['manifest'] as Map,
      'nowUtc': capture['verifiedAtUtc'] as int,
    };
  }

  test(
    'actual late old-version capture retains the historical-age guard',
    () async {
      await expectLater(
        decodeServerEpg(await input(late!)),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            'Invalid EPG UTC interval',
          ),
        ),
      );
    },
    skip: late == null ? 'Requires the actual late historical capture' : false,
  );

  test(
    'actual subsequent published capture passes without relaxed validation',
    () async {
      final message = await input(fresh!);
      final decoded = await decodeServerEpg(message);
      expect(
        decoded.guide.programmes.length,
        (message['manifest'] as Map)['programmeCount'],
      );
    },
    skip: fresh == null ? 'Requires the actual subsequent capture' : false,
  );
}
