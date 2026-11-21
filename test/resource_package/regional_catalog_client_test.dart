import 'dart:convert';

import 'package:clubtivi/features/account/account_service.dart';
import 'package:clubtivi/features/account/regional_catalog_client.dart';
import 'package:crypto/crypto.dart' as digest;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

String b64(List<int> bytes) => base64UrlEncode(bytes).replaceAll('=', '');
List<int> fromB64(String value) => base64Url.decode(base64Url.normalize(value));

class RegionalFixture extends AccountService {
  RegionalFixture(this.publisher, this.publisherPublicKey) {
    user = {'id': 'a' * 32};
  }

  final SimpleKeyPair publisher;
  final SimplePublicKey publisherPublicKey;
  Map<String, dynamic>? claim;
  var calls = 0;
  bool corrupt = false;

  @override
  bool get loggedIn => true;

  Map<String, dynamic> bootstrap() => {
    'format': 'bobtv-sync-bootstrap',
    'schemaVersion': 1,
    'algorithm': 'Ed25519',
    'apiBase': '$origin/api/v1/regional-catalog',
    'keyId': digest.sha256.convert(publisherPublicKey.bytes).toString(),
    'publicKey': b64(publisherPublicKey.bytes),
  };

  Future<Map<String, dynamic>> envelope(Map<String, dynamic> data) async {
    final payload = utf8.encode(jsonEncode(data));
    final signature = (await Ed25519().sign(payload, keyPair: publisher)).bytes;
    return {
      'payload': b64(payload),
      'signature': b64(corrupt ? List.filled(64, 0) : signature),
    };
  }

  @override
  Future<Map<String, dynamic>> regionalCatalogRequest(
    String operation, {
    Map<String, dynamic>? body,
  }) async {
    calls++;
    if (operation == 'bootstrap.bobtv') return bootstrap();
    if (operation == 'challenge') {
      claim = {
        'domain': 'bobtv-regional-catalog-v1',
        'origin': origin,
        'userId': user!['id'],
        'nonce': b64(List.filled(32, 42)),
        'expires': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 90,
        ...body!,
      };
      return envelope(claim!);
    }
    final challenge = claim!;
    claim = null;
    final device = SimplePublicKey(
      fromB64(challenge['publicKey'] as String),
      type: KeyPairType.ed25519,
    );
    expect(body!['nonce'], challenge['nonce']);
    expect(
      await Ed25519().verify(
        utf8.encode(jsonEncode(challenge)),
        signature: Signature(
          fromB64(body['signature'] as String),
          publicKey: device,
        ),
      ),
      isTrue,
    );
    const regionRevision =
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
    final base = {
      ...bootstrap(),
      'format': 'bobtv-regional-catalog-v1',
      'nonce': challenge['nonce'],
      'userId': challenge['userId'],
      'action': challenge['action'],
      'region': challenge['region'],
    };
    if (challenge['action'] != 'sync') return envelope(base);
    final unchanged = challenge['knownRevision'] == regionRevision;
    return envelope({
      ...base,
      'revision': regionRevision,
      'unchanged': unchanged,
      if (!unchanged)
        'package': {
          'format': 'bobtv-resource',
          'schemaVersion': 1,
          'id': 'bobtv-region-JP',
          'name': 'BobTV / JP',
          'revision': regionRevision,
          'categories': [
            {'id': 'cat', 'name': 'TV'},
          ],
          'channels': [
            {
              'id': 'jp-tv',
              'name': 'Demo',
              'categoryId': 'cat',
              'routes': [
                {'id': 'r', 'url': 'https://example.org/demo.m3u8'},
              ],
            },
          ],
        },
    });
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'import verifies issuer before using an account and checks signatures',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final key = await Ed25519().newKeyPair();
      final account = RegionalFixture(key, await key.extractPublicKey());
      addTearDown(account.dispose);
      final client = RegionalCatalogClient(account);
      await expectLater(
        client.verifyBootstrap({
          ...account.bootstrap(),
          'apiBase': 'https://example.org/api/v1/regional-catalog',
        }),
        throwsFormatException,
      );
      expect(account.calls, 0);
      final trusted = await client.verifyBootstrap(account.bootstrap());
      await client.enroll(trusted);
      final package = await client.sync(trusted, 'JP');
      expect(package!.channels.single.id, 'jp-tv');
      expect(
        await client.sync(trusted, 'JP', knownRevision: package.revision),
        isNull,
      );
      account.corrupt = true;
      await expectLater(client.sync(trusted, 'JP'), throwsFormatException);
    },
  );
}
