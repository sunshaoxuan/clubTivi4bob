import 'dart:convert';
import 'dart:io';
import '../lib/core/server_egress.dart';

Future<void> main() async {
  ServerEgress.installGuard();
  await ServerEgress.nodes.refresh();
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    final request = await client.getUrl(
      Uri.parse('${ServerEgress.origin}/updates/windows-arm64/latest.json'),
    );
    request.followRedirects = false;
    request.headers.set('User-Agent', 'BobTV/1.1 resource-test');
    final response = await request.close().timeout(const Duration(seconds: 10));
    if (response.statusCode != 200)
      throw HttpException('Feed ${response.statusCode}');
    final feed = jsonDecode(await utf8.decoder.bind(response).join());
    final archive = Uri.parse(feed['archive'] as String);
    final transport = await ServerEgress.nodes.resolve(archive);
    final media = ServerEgress.mediaUrl(
      'https://live.streamingfast.net/osmflivech1.m3u8',
    );
    if (media != 'https://live.streamingfast.net/osmflivech1.m3u8')
      throw StateError('Video routing changed');
    print(
      jsonEncode({
        'selectedResourceNode': ServerEgress.nodes.selected.toString(),
        'responseNode': response.headers.value('x-bobtv-node') ?? 'origin',
        'version': feed['version'],
        'canonicalPackage': archive.toString(),
        'packageTransport': transport.toString(),
        'videoDirect': true,
      }),
    );
  } finally {
    client.close(force: true);
  }
}
