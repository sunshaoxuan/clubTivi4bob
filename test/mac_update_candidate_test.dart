import 'package:clubtivi/data/services/mac_update_candidate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const installed = '/Users/test/Applications/BobTV.app';
  String record(String app) => '1.1.11+106\n/support/Update/Backups/previous\n0\n$app\n';
  test('only the installation owning a startup record can mark it healthy', () {
    expect(macUpdateCandidateBelongsToApp(record(installed), installed), isTrue);
    expect(macUpdateCandidateBelongsToApp(record('/build/Release/BobTV.app'), installed), isFalse);
    expect(macUpdateCandidateBelongsToApp(record('/Applications/BobTV.app'), installed), isFalse);
    expect(macUpdateCandidateBelongsToApp(record('$installed-copy'), installed), isFalse);
    expect(macUpdateCandidateBelongsToApp('', installed), isFalse);
    expect(macUpdateCandidateBelongsToApp('1.1.11+106\nbackup\n0\n', installed), isFalse);
  });
}
