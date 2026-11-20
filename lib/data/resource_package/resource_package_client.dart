import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/server_egress.dart';
import 'resource_package.dart';

/// Fetches only a URL explicitly entered by the user. No central relay, cookies,
/// authorization headers, remote executable content, or implicit discovery.
class ResourcePackageClient {
  Future<ResourcePackage> fetch(String address) async {
    var uri = ResourcePackage.url(address, 'package URL');
    final client = ServerEgress.createUserSourceClient();
    client.autoUncompress = false;
    client.connectionTimeout = const Duration(seconds: 10);
    try {
      return await (() async {
        for (var redirects = 0; redirects <= 3; redirects++) {
          final request = await client.getUrl(uri);
          request.followRedirects = false;
          request.headers.set(HttpHeaders.acceptHeader, 'application/json');
          request.headers.set(HttpHeaders.acceptEncodingHeader, 'gzip');
          final response = await request.close();
          if ({301, 302, 303, 307, 308}.contains(response.statusCode)) {
            final location = response.headers.value(HttpHeaders.locationHeader);
            if (location == null || redirects == 3) {
              throw const FormatException('Invalid resource redirect');
            }
            final next = ResourcePackage.url(
              uri.resolve(location).toString(),
              'redirect',
            );
            if (uri.scheme == 'https' && next.scheme != 'https') {
              throw const FormatException('Resource redirect requires HTTPS');
            }
            // Release this response without reading an unbounded redirect body.
            await response.listen((_) {}).cancel();
            uri = next;
            continue;
          }
          if (response.statusCode != 200) {
            throw HttpException('Resource HTTP ${response.statusCode}');
          }
          if (response.contentLength > ResourcePackage.maxBytes) {
            ResourcePackage.invalid('download size');
          }
          var wireBytes = 0;
          Stream<List<int>> stream = response.map((chunk) {
            wireBytes += chunk.length;
            if (wireBytes > ResourcePackage.maxBytes) {
              ResourcePackage.invalid('download size');
            }
            return chunk;
          });
          final encoding = response.headers.value(
            HttpHeaders.contentEncodingHeader,
          );
          if (encoding == 'gzip') {
            stream = gzip.decoder.bind(stream);
          } else if (encoding != null && encoding != 'identity') {
            ResourcePackage.invalid('content encoding');
          }
          final bytes = <int>[];
          await for (final chunk in stream) {
            if (bytes.length + chunk.length > ResourcePackage.maxBytes) {
              ResourcePackage.invalid('expanded size');
            }
            bytes.addAll(chunk);
          }
          return ResourcePackage.parse(utf8.decode(bytes));
        }
        throw const FormatException('Invalid resource redirect');
      })().timeout(const Duration(seconds: 25));
    } finally {
      client.close(force: true);
    }
  }
}
