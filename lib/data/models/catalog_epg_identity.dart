import 'dart:convert';
import 'package:crypto/crypto.dart';

const publicCatalogProviderId = 'bobtv-channel-catalog';

/// Matches the server's sorted, UTF-8 JSON fingerprint without normalization.
/// Country, region, full ID and name remain distinct, including delay and +.
Map<String, Object?> catalogEpgIdentity(Map channel) {
  for (final key in ['id', 'name']) {
    final value = channel[key];
    if (value is! String ||
        value.trim().isEmpty ||
        value.length > 256 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
      throw const FormatException('Invalid catalog EPG identity');
    }
  }
  for (final key in ['countryCode', 'epgId', 'regionCode']) {
    final value = channel[key];
    if (value != null &&
        (value is! String ||
            value.length > 256 ||
            RegExp(r'[\x00-\x1f\x7f]').hasMatch(value))) {
      throw const FormatException('Invalid catalog EPG context');
    }
  }
  return {
    'countryCode': channel['countryCode'],
    'epgId': channel['epgId'],
    'id': channel['id'],
    'name': channel['name'],
    'regionCode': channel['regionCode'],
  };
}

String catalogEpgIdentityHash(Map channel) => sha256
    .convert(utf8.encode(jsonEncode(catalogEpgIdentity(channel))))
    .toString();
