import 'dart:io';
import 'package:clubtivi/data/services/ai_runtime_settings.dart';
import 'package:clubtivi/data/services/app_credential_store.dart';
import 'package:clubtivi/data/services/device_favorites_identity.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class RecordingStorage extends FlutterSecureStorage {
  int reads = 0, writes = 0, deletes = 0;
  bool deny = false;
  String? value = 'existing-secret';
  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    reads++;
    if (deny) throw PlatformException(code: '-128');
    return value;
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    writes++;
    if (deny) throw PlatformException(code: '-25308');
    this.value = value;
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    deletes++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('disabled AI load and save never touch credential storage', () async {
    SharedPreferences.setMockInitialValues({'bobtv_ai_enabled_v1': false});
    final storage = RecordingStorage()..deny = true;
    final settings = AiRuntimeSettings(storage: storage);
    expect((await settings.load()).apiKey, '');
    await settings.save(
      baseUrl: '',
      model: '',
      enabled: false,
      replacementKey: 'ignored-while-disabled',
    );
    expect([storage.reads, storage.writes, storage.deletes], [0, 0, 0]);
  });
  test(
    'denied AI access stays paused across new instances and repeated loads',
    () async {
      SharedPreferences.setMockInitialValues({'bobtv_ai_enabled_v1': true});
      final storage = RecordingStorage()..deny = true;
      for (var i = 0; i < 10; i++) {
        expect((await AiRuntimeSettings(storage: storage).load()).ready, false);
      }
      expect(storage.reads, 1);
      expect(await AppCredentialStore('ai', storage: storage).paused, true);
    },
  );
  test(
    'favorites denial survives force-like retries and new identity instances',
    () async {
      final storage = RecordingStorage()..deny = true;
      for (var i = 0; i < 10; i++) {
        await expectLater(
          DeviceFavoritesIdentity(
            storage: storage,
            fingerprintLoader: () async => 'a' * 64,
          ).load(),
          throwsA(isA<CredentialAccessPaused>()),
        );
      }
      expect(storage.reads, 1);
      expect(storage.writes, 0);
      expect(storage.deletes, 0);
      storage.deny = false;
      storage.value = 'btvf1_${'1' * 64}';
      final identity = DeviceFavoritesIdentity(
        storage: storage,
        fingerprintLoader: () async => 'a' * 64,
      );
      await identity.authorize();
      expect(
        await AppCredentialStore('favorites', storage: storage).paused,
        false,
      );
      expect((await identity.load())!.token, storage.value);
    },
  );
  test(
    'native channel only allows interaction on explicit authorization',
    skip: !Platform.isMacOS,
    () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(AppCredentialStore.channel, (call) async {
            calls.add(call);
            throw PlatformException(code: 'keychain_access', details: -128);
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(AppCredentialStore.channel, null),
      );
      final store = AppCredentialStore('favorites');
      for (var i = 0; i < 3; i++) {
        await expectLater(
          store.read('bobtv_private_favorites_v1_${'a' * 64}'),
          throwsA(isA<CredentialAccessPaused>()),
        );
      }
      expect(calls.length, 1);
      expect(calls.single.arguments['interactive'], false);
      await expectLater(
        store.read('bobtv_private_favorites_v1_${'a' * 64}', interactive: true),
        throwsA(isA<CredentialAccessPaused>()),
      );
      expect(calls.length, 2);
      expect(calls.last.arguments['interactive'], true);
      expect(await store.paused, true);
    },
  );
}
