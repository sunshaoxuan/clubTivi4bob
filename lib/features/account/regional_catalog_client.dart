import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as digest;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../data/resource_package/resource_package.dart';
import 'account_service.dart';

String _b64(List<int> data) => base64UrlEncode(data).replaceAll('=', '');

List<int> _unb64(Object? value, {int? length}) {
  if (value is! String || !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value)) {
    throw const FormatException('Invalid regional signature data');
  }
  final bytes = base64Url.decode(base64Url.normalize(value));
  if (length != null && bytes.length != length || _b64(bytes) != value) {
    throw const FormatException('Invalid regional signature encoding');
  }
  return bytes;
}

class RegionalCatalogBootstrap {
  RegionalCatalogBootstrap._(this.apiBase, this.keyId, this.publicKey);

  final Uri apiBase;
  final String keyId;
  final SimplePublicKey publicKey;

  factory RegionalCatalogBootstrap.parse(
    Map<String, dynamic> data,
    Uri accountOrigin,
  ) {
    final address = accountOrigin.resolve('/api/v1/regional-catalog');
    if (accountOrigin.scheme != 'https' ||
        data['format'] != 'bobtv-sync-bootstrap' ||
        data['schemaVersion'] != 1 ||
        data['apiBase'] != address.toString() ||
        data['algorithm'] != 'Ed25519') {
      throw const FormatException('Untrusted BobTV catalogue publisher');
    }
    final bytes = _unb64(data['publicKey'], length: 32);
    final keyId = digest.sha256.convert(bytes).toString();
    if (data['keyId'] != keyId) throw const FormatException('Invalid key ID');
    return RegionalCatalogBootstrap._(
      address,
      keyId,
      SimplePublicKey(bytes, type: KeyPairType.ed25519),
    );
  }

  Future<({List<int> bytes, Map<String, dynamic> data})> open(
    Map<String, dynamic> envelope,
  ) async {
    final bytes = _unb64(envelope['payload']);
    final signature = Signature(
      _unb64(envelope['signature'], length: 64),
      publicKey: publicKey,
    );
    if (!await Ed25519().verify(bytes, signature: signature)) {
      throw const FormatException('Invalid BobTV catalogue signature');
    }
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid BobTV catalogue payload');
    }
    return (bytes: bytes, data: decoded);
  }
}

/// Never uses a URL from the imported file for authentication. The trust
/// anchor is the already configured BobTV account origin over HTTPS.
class RegionalCatalogClient {
  RegionalCatalogClient(this.account, {FlutterSecureStorage? storage})
    : storage = storage ?? AccountService.credentialStorage;

  final AccountService account;
  final FlutterSecureStorage storage;
  final _keyLoads = <String, Future<SimpleKeyPair>>{};

  Future<RegionalCatalogBootstrap> verifyBootstrap(
    Map<String, dynamic> imported,
  ) async {
    final origin = Uri.parse(account.origin);
    final package = RegionalCatalogBootstrap.parse(imported, origin);
    final actual = RegionalCatalogBootstrap.parse(
      await account.regionalCatalogRequest('bootstrap.bobtv'),
      origin,
    );
    if (package.keyId != actual.keyId) {
      throw const FormatException('BobTV catalogue signing key mismatch');
    }
    return actual;
  }

  Future<SimpleKeyPair> _deviceKey(String user) =>
      _keyLoads.putIfAbsent(user, () async {
        try {
          final slot = 'bobtv.catalog.device.v1.$user';
          final current = await storage.read(key: slot);
          if (current != null) {
            return Ed25519().newKeyPairFromSeed(_unb64(current, length: 32));
          }
          final random = Random.secure();
          final seed = List<int>.generate(32, (_) => random.nextInt(256));
          await storage.write(key: slot, value: _b64(seed));
          return Ed25519().newKeyPairFromSeed(seed);
        } finally {
          _keyLoads.remove(user);
        }
      });

  Future<Map<String, dynamic>> _execute(
    RegionalCatalogBootstrap publisher,
    String operation, {
    String? region,
    String? revision,
  }) async {
    final user = account.user?['id'];
    if (!account.loggedIn ||
        user is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(user)) {
      throw const AccountException('login_required');
    }
    final keyPair = await _deviceKey(user);
    final publicKey = _b64((await keyPair.extractPublicKey()).bytes);
    final challenge = await publisher.open(
      await account.regionalCatalogRequest(
        'challenge',
        body: {
          'action': operation,
          'publicKey': publicKey,
          'region': ?region,
          'knownRevision': ?revision,
        },
      ),
    );
    final claim = challenge.data;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final nonce = claim['nonce'];
    final expires = claim['expires'];
    if (claim['domain'] != 'bobtv-regional-catalog-v1' ||
        claim['origin'] != account.origin ||
        claim['userId'] != user ||
        claim['action'] != operation ||
        claim['publicKey'] != publicKey ||
        claim['region'] != region ||
        claim['knownRevision'] != revision ||
        expires is! int ||
        expires <= now ||
        expires > now + 120 ||
        nonce is! String ||
        _unb64(nonce, length: 32).length != 32 ||
        account.user?['id'] != user) {
      throw const FormatException('Invalid BobTV catalogue challenge');
    }
    final signature = await Ed25519().sign(challenge.bytes, keyPair: keyPair);
    final response = await publisher.open(
      await account.regionalCatalogRequest(
        'complete',
        body: {'nonce': nonce, 'signature': _b64(signature.bytes)},
      ),
    );
    final result = response.data;
    if (account.user?['id'] != user ||
        result['format'] != 'bobtv-regional-catalog-v1' ||
        result['nonce'] != nonce ||
        result['userId'] != user ||
        result['action'] != operation ||
        result['apiBase'] != publisher.apiBase.toString() ||
        result['region'] != region ||
        result['keyId'] != publisher.keyId ||
        result['publicKey'] != _b64(publisher.publicKey.bytes) ||
        result['schemaVersion'] != 1) {
      throw const FormatException('Invalid BobTV catalogue scope');
    }
    return result;
  }

  Future<void> enroll(RegionalCatalogBootstrap publisher) async {
    await _execute(publisher, 'enroll');
  }

  Future<Map<String, int>> regions(RegionalCatalogBootstrap publisher) async {
    final data = await _execute(publisher, 'regions');
    final result = <String, int>{};
    for (final row in ResourcePackage.list(data['regions'], 'regions', 256)) {
      if (row is! Map ||
          row['code'] is! String ||
          row['channelCount'] is! int ||
          !RegExp(r'^[A-Z]{2}$').hasMatch(row['code'] as String) ||
          (row['channelCount'] as int) <= 0 ||
          result.containsKey(row['code'])) {
        ResourcePackage.invalid('region');
      }
      result[row['code'] as String] = row['channelCount'] as int;
    }
    return result;
  }

  Future<Map<String, dynamic>?> syncSnapshot(
    RegionalCatalogBootstrap publisher,
    String region, {
    String? knownRevision,
  }) async {
    if (!RegExp(r'^[A-Z]{2}$').hasMatch(region)) {
      ResourcePackage.invalid('region code');
    }
    final data = await _execute(
      publisher,
      'sync',
      region: region,
      revision: knownRevision,
    );
    if (data['unchanged'] == true &&
        knownRevision != null &&
        data['revision'] == knownRevision &&
        data['catalog'] == null)
      return null;
    final catalog = data['catalog'];
    final package = ResourcePackage.parse(jsonEncode(data['package']));
    if (data['unchanged'] != false ||
        catalog is! Map<String, dynamic> ||
        catalog['version'] != data['catalogVersion'] ||
        package.id != 'bobtv-region-$region' ||
        package.revision != data['revision'] ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(package.revision)) {
      ResourcePackage.invalid('regional snapshot scope');
    }
    return {'revision': package.revision, 'catalog': catalog};
  }

  Future<ResourcePackage?> sync(
    RegionalCatalogBootstrap publisher,
    String region, {
    String? knownRevision,
  }) async {
    if (!RegExp(r'^[A-Z]{2}$').hasMatch(region)) {
      ResourcePackage.invalid('region code');
    }
    final data = await _execute(
      publisher,
      'sync',
      region: region,
      revision: knownRevision,
    );
    if (data['unchanged'] == true &&
        knownRevision != null &&
        data['revision'] == knownRevision &&
        data['package'] == null) {
      return null;
    }
    final package = ResourcePackage.parse(jsonEncode(data['package']));
    if (data['unchanged'] != false ||
        package.id != 'bobtv-region-$region' ||
        package.revision != data['revision'] ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(package.revision)) {
      ResourcePackage.invalid('revision or package scope');
    }
    return package;
  }
}
