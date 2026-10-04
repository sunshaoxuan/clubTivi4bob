import 'dart:io';

import 'package:clubtivi/core/app_version.dart';
import 'package:clubtivi/data/services/update_manifest.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final mirror = Uri.parse('https://bobtv.briconbric.com/updates/latest.json');

  test('application version matches the release source', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('version: $bobTvVersion'));
  });

  test('channel sidebar reads the shared application version', () {
    final channels = File(
      'lib/features/channels/channels_screen.dart',
    ).readAsStringSync();
    expect(channels, contains(r"'BobTV v$bobTvVersion'"));
    expect(channels, contains(r"'v$bobTvVersion'"));
    expect(RegExp(r'v\d+\.\d+\.\d+\+\d+').hasMatch(channels), isFalse);
  });

  test('newer build is newer even within the same release', () {
    expect(UpdateManifest.compareVersions('0.9.1+54', '0.9.1+53'), greaterThan(0));
    expect(UpdateManifest.compareVersions('0.9.2+1', '0.9.1+53'), greaterThan(0));
    expect(UpdateManifest.compareVersions('1.0.0+81', '0.9.1+80'), greaterThan(0));
    expect(UpdateManifest.compareVersions('0.9.1+52', '0.9.1+53'), lessThan(0));
  });

  test('manifest accepts only a same-host HTTPS package', () {
    final valid = '{"schema":1,"version":"0.9.2+54",'
        '"archive":"https://bobtv.briconbric.com/updates/BobTV.zip",'
        '"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",'
        '"bytes":64000000}';
    expect(UpdateManifest.parse(valid, mirror).version, '0.9.2+54');
    final testSignature = List.filled(96, 'A').join();
    final macSigned = valid.replaceFirst('"bytes":64000000}',
        '"bytes":64000000,"signature":"$testSignature"}');
    expect(UpdateManifest.parse(macSigned, mirror).signature, testSignature);
    expect(() => UpdateManifest.parse(
        valid.replaceFirst('"bytes":64000000}',
            '"bytes":64000000,"signature":"bad"}'), mirror),
        throwsFormatException);
    expect(
      () => UpdateManifest.parse(
        valid.replaceFirst('bobtv.briconbric.com/updates/BobTV.zip',
            'example.com/updates/BobTV.zip'),
        mirror,
      ),
      throwsFormatException,
    );
    expect(
      () => UpdateManifest.parse(valid.replaceFirst('https://', 'http://'), mirror),
      throwsFormatException,
    );
    expect(
      () => UpdateManifest.parse(
        valid.replaceFirst('bobtv.briconbric.com/updates/',
            'bobtv.briconbric.com:8443/updates/'),
        mirror,
      ),
      throwsFormatException,
    );
  });
}
