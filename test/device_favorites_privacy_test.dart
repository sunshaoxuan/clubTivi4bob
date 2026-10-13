import 'dart:async';

import 'package:clubtivi/data/services/device_favorites_privacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'preserves existing online backup default and explicit user choices',
    () async {
      expect(await DeviceFavoritesPrivacy.enabled(), true);
      await DeviceFavoritesPrivacy.setEnabled(false);
      expect(await DeviceFavoritesPrivacy.enabled(), false);
      await DeviceFavoritesPrivacy.setEnabled(true);
      expect(await DeviceFavoritesPrivacy.enabled(), true);
    },
  );

  test('only the dedicated installer privacy section supplies defaults', () {
    expect(
      DeviceFavoritesPrivacy.installerDefault(
        '[BobTVPrivacy]\r\nFavoritesBackup=0',
      ),
      false,
    );
    expect(
      DeviceFavoritesPrivacy.installerDefault(
        '[BobTVPrivacy]\nFavoritesBackup=1',
      ),
      true,
    );
    expect(
      DeviceFavoritesPrivacy.installerDefault('[Other]\nFavoritesBackup=0'),
      null,
    );
    expect(
      DeviceFavoritesPrivacy.installerDefault(
        '\uFEFF[BobTVPrivacy]\n; comment\n FavoritesBackup = 0\n[Other]\nFavoritesBackup=1',
      ),
      false,
    );
    expect(
      DeviceFavoritesPrivacy.installerDefault(
        '[BobTVPrivacy]\nFavoritesBackup=unknown',
      ),
      false,
    );
    expect(
      DeviceFavoritesPrivacy.installerDefault(
        '[BobTVPrivacy]\nFavoritesBackup=1\nFavoritesBackup=0',
      ),
      false,
    );
  });

  test('a choice made during installation defaults loading wins', () async {
    final loading = Completer<bool?>();
    final started = Completer<void>();
    final initial = DeviceFavoritesPrivacy.enabled(
      installationChoice: () {
        started.complete();
        return loading.future;
      },
    );
    await started.future;
    await DeviceFavoritesPrivacy.setEnabled(false);
    loading.complete(true);
    expect(await initial, false);
    expect(await DeviceFavoritesPrivacy.enabled(), false);
  });
}
