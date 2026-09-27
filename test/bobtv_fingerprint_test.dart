import 'package:clubtivi/data/services/client_fingerprint_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('keeps a 64-character installation fingerprint', () async {
    SharedPreferences.setMockInitialValues({});
    final service = ClientFingerprintService.instance;
    final first = await service.initialize();
    final second = await service.initialize();
    expect(first, second);
    expect(service.apiFingerprint, matches(RegExp(r'^[a-f0-9]{64}$')));
    expect(first, startsWith('btv1_'));
  });
}
