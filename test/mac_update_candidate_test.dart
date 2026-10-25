import 'package:clubtivi/data/services/mac_update_candidate.dart';
import 'package:crypto/crypto.dart';
import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:flutter_test/flutter_test.dart';

void main() {
  const app = '/Users/test/Applications/BobTV.app';
  const support = '/Users/test/Library/Application Support/com.briconbric.bobtv';
  String record(String path, String version) => '$version\n/backup\n0\n$path\n';
  test('different installations isolate every update and rollback file', () {
    final directory = macUpdateInstallationDirectory(support, app);
    expect(directory, p.join(support,'Update','Installations',sha256.convert(utf8.encode(app)).toString()));
    for (final other in ['/Applications/BobTV.app','/build/Release/BobTV.app','/Users/test/应用/BobTV.app']) {
      expect(macUpdateInstallationDirectory(support, other), isNot(directory));
    }
    expect(macUpdateInstallationDirectory(support, app), directory);
  });
  test('health proof requires the exact installation and running version', () {
    expect(macUpdateCandidateBelongsToApp(record(app,'1.1.13+108'), app, version:'1.1.13+108'), isTrue);
    expect(macUpdateCandidateBelongsToApp(record('/build/Release/BobTV.app','1.1.13+108'), app, version:'1.1.13+108'), isFalse);
    expect(macUpdateCandidateBelongsToApp(record(app,'1.1.12+107'), app, version:'1.1.13+108'), isFalse);
    expect(macUpdateCandidateBelongsToApp('', app, version:'1.1.13+108'), isFalse);
    expect(macUpdateCandidateBelongsToApp('1.1.13+108\nbackup\n0\n', app), isFalse);
  });
}
