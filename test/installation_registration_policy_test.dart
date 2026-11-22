import 'package:clubtivi/data/services/installation_registration_policy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'clean install retains the new-install flow across subsequent starts',
    () async {
      SharedPreferences.setMockInitialValues({});
      final first = InstallationRegistrationPolicy(
        existingData: () async => false,
      );
      await first.initialize();
      expect(first.legacyAccess, isFalse);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'bobtv_install_fingerprint_v1',
        'created after startup',
      );
      final restart = InstallationRegistrationPolicy(
        existingData: () async => true,
      );
      await restart.initialize();
      expect(restart.legacyAccess, isFalse);
    },
  );

  test(
    'existing preferences permanently exempt upgrades without an account',
    () async {
      SharedPreferences.setMockInitialValues({'last_channel_id': 'news'});
      final policy = InstallationRegistrationPolicy(
        existingData: () async => false,
      );
      await policy.initialize();
      expect(policy.legacyAccess, isTrue);
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('last_channel_id');
      final restart = InstallationRegistrationPolicy(
        existingData: () async => false,
      );
      await restart.initialize();
      expect(restart.legacyAccess, isTrue);
    },
  );

  test(
    'existing database or identity exempts installations with empty preferences',
    () async {
      SharedPreferences.setMockInitialValues({});
      final policy = InstallationRegistrationPolicy(
        existingData: () async => true,
      );
      await policy.initialize();
      expect(policy.legacyAccess, isTrue);
    },
  );

  test(
    'failed installation detection never blocks existing playback',
    () async {
      SharedPreferences.setMockInitialValues({});
      final policy = InstallationRegistrationPolicy(
        existingData: () async => throw StateError('unreadable'),
      );
      await policy.initialize();
      expect(policy.legacyAccess, isTrue);
    },
  );
}
