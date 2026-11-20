import 'dart:async';
import 'dart:convert';
import 'package:clubtivi/features/account/account_service.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:local_auth/local_auth.dart';

class FakeAuth extends LocalAuthentication {
  bool accepted = true;
  int prompts = 0;
  @override
  Future<bool> get canCheckBiometrics async => true;
  @override
  Future<List<BiometricType>> getAvailableBiometrics() async => [
    BiometricType.face,
  ];
  @override
  Future<bool> authenticate({
    required String localizedReason,
    Iterable<dynamic> authMessages = const [],
    bool biometricOnly = false,
    bool sensitiveTransaction = true,
    bool persistAcrossBackgrounding = false,
  }) async {
    prompts++;
    expect(biometricOnly, isTrue);
    return accepted;
  }
}

class SlowStorage extends FlutterSecureStorage {
  final started = Completer<void>();
  final release = Completer<void>();
  bool first = true;
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
    if (first && key == AccountService.tokenKey) {
      first = false;
      started.complete();
      await release.future;
    }
    await super.write(key: key, value: value);
  }
}

class MobileAccount extends AccountService {
  MobileAccount({
    required super.client,
    required super.localAuth,
    super.storage,
  });
  @override
  bool get supportsBiometrics => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const storage = FlutterSecureStorage();
  final user = {'id': 'one', 'email': 'a@example.com', 'verified': true};
  http.Response json(Object value, [int code = 200]) =>
      http.Response(jsonEncode(value), code);
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('optional startup does not call service without a credential', () async {
    final service = MobileAccount(
      client: MockClient((r) async => throw StateError('unexpected network')),
      localAuth: FakeAuth(),
    );
    await service.initialize();
    expect(service.ready, isTrue);
    expect(service.loggedIn, isFalse);
    service.dispose();
  });
  test(
    'email session is securely stored, bearer sent, logout clears storage',
    () async {
      final requests = <http.Request>[];
      final service = MobileAccount(
        client: MockClient((r) async {
          requests.add(r);
          if (r.url.path.endsWith('/verify')) {
            return json({'token': 'secret-session', 'user': user});
          }
          if (r.url.path.endsWith('/me')) return json(user);
          return json({'ok': true});
        }),
        localAuth: FakeAuth(),
      );
      await service.initialize();
      await service.signInEmail(' a@example.com ', '123456');
      expect(service.loggedIn, isTrue);
      expect(
        await storage.read(key: AccountService.tokenKey),
        'secret-session',
      );
      await service.refresh();
      expect(requests.last.headers['Authorization'], 'Bearer secret-session');
      expect(requests.last.followRedirects, isFalse);
      await service.logout();
      expect(service.loggedIn, isFalse);
      expect(await storage.read(key: AccountService.tokenKey), isNull);
      service.dispose();
    },
  );
  test(
    'biometric cancellation does not enable; resume requires unlock and server check',
    () async {
      final auth = FakeAuth();
      final service = MobileAccount(
        client: MockClient(
          (r) async => r.url.path.endsWith('/verify')
              ? json({'token': 'session', 'user': user})
              : json(user),
        ),
        localAuth: auth,
      );
      await service.initialize();
      await service.signInEmail('a@example.com', '123456');
      auth.accepted = false;
      await expectLater(
        service.setBiometric(true, 'unlock'),
        throwsA(isA<AccountException>()),
      );
      expect(service.biometric, isFalse);
      auth.accepted = true;
      await service.setBiometric(true, 'unlock');
      expect(service.biometric, isTrue);
      service.didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(service.locked, isTrue);
      expect(service.loggedIn, isFalse);
      auth.accepted = false;
      await expectLater(
        service.unlock('unlock'),
        throwsA(isA<AccountException>()),
      );
      expect(service.loggedIn, isFalse);
      auth.accepted = true;
      await service.unlock('unlock');
      expect(service.loggedIn, isTrue);
      await service.setBiometric(false, 'unlock');
      expect(service.biometric, isFalse);
      service.dispose();
    },
  );
  test(
    'stored biometric account never reads remote account before local unlock',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        AccountService.tokenKey: 'session',
        AccountService.biometricKey: 'on',
      });
      int requests = 0;
      final service = MobileAccount(
        client: MockClient((r) async {
          requests++;
          return json(user);
        }),
        localAuth: FakeAuth(),
      );
      await service.initialize();
      expect(service.locked, isTrue);
      expect(requests, 0);
      await service.unlock('unlock');
      expect(requests, 1);
      expect(service.loggedIn, isTrue);
      service.dispose();
    },
  );
  test('server revoked session is removed on biometric unlock', () async {
    FlutterSecureStorage.setMockInitialValues({
      AccountService.tokenKey: 'session',
      AccountService.biometricKey: 'on',
    });
    final service = MobileAccount(
      client: MockClient((r) async => json({'detail': 'login_required'}, 401)),
      localAuth: FakeAuth(),
    );
    await service.initialize();
    await expectLater(
      service.unlock('unlock'),
      throwsA(isA<AccountException>()),
    );
    expect(service.loggedIn, isFalse);
    expect(service.locked, isFalse);
    expect(await storage.read(key: AccountService.tokenKey), isNull);
    service.dispose();
  });
  test('closing login prevents late response from restoring account', () async {
    final response = Completer<http.Response>();
    final service = MobileAccount(
      client: MockClient((r) => response.future),
      localAuth: FakeAuth(),
    );
    await service.initialize();
    final login = service.signInEmail('a@example.com', '123456');
    service.cancelSignIn();
    response.complete(json({'token': 'late', 'user': user}));
    await expectLater(login, throwsA(isA<AccountException>()));
    expect(service.loggedIn, isFalse);
    expect(await storage.read(key: AccountService.tokenKey), isNull);
    service.dispose();
  });
  test('cancelled storage write cannot erase a newer login', () async {
    final slow = SlowStorage();
    int n = 0;
    final service = MobileAccount(
      storage: slow,
      client: MockClient(
        (r) async => json({'token': 'session-${++n}', 'user': user}),
      ),
      localAuth: FakeAuth(),
    );
    await service.initialize();
    final a = service.signInEmail('a@example.com', '123456');
    final cancelled = expectLater(a, throwsA(isA<AccountException>()));
    await slow.started.future;
    service.cancelSignIn();
    final b = service.signInEmail('b@example.com', '123456');
    slow.release.complete();
    await cancelled;
    await b;
    expect(service.loggedIn, isTrue);
    expect(await storage.read(key: AccountService.tokenKey), 'session-2');
    service.dispose();
  });
  test('an old rejected request does not sign out a newer session', () async {
    final response = Completer<http.Response>();
    final sent = Completer<void>();
    int n = 0;
    final service = MobileAccount(
      client: MockClient((r) async {
        if (r.url.path.endsWith('/verify')) {
          return json({'token': 'session-${++n}', 'user': user});
        }
        sent.complete();
        return response.future;
      }),
      localAuth: FakeAuth(),
    );
    await service.initialize();
    await service.signInEmail('a@example.com', '123456');
    final old = service.refresh();
    final rejected = expectLater(old, throwsA(isA<AccountException>()));
    await sent.future;
    await service.clearLocal();
    await service.signInEmail('b@example.com', '123456');
    response.complete(json({'detail': 'login_required'}, 401));
    await rejected;
    expect(service.loggedIn, isTrue);
    expect(await storage.read(key: AccountService.tokenKey), 'session-2');
    service.dispose();
  });
}
