import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:clubtivi/features/casting/lan_cast_relay.dart';
import 'package:clubtivi/features/casting/lg_webos_client.dart';
import 'package:clubtivi/features/casting/cast_service.dart';
import 'package:clubtivi/features/casting/dlna_discovery.dart';
import 'package:clubtivi/core/server_egress.dart';
import 'package:dlna_dart/dlna.dart';
import 'package:dlna_dart/xmlParser.dart';
import 'package:xml/xml.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
  });

  test('pairing waits for registered and reuses the saved key', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final registrations = <Map<String, dynamic>>[];
    final sockets = <WebSocket>[];
    server.listen((req) async {
      final ws = await WebSocketTransformer.upgrade(req);
      sockets.add(ws);
      ws.listen((data) {
        final msg = jsonDecode(data as String) as Map<String, dynamic>;
        if (msg['type'] == 'register') {
          registrations.add(msg);
          ws.add(
            jsonEncode({
              'id': msg['id'],
              'type': 'response',
              'payload': {'pairingType': 'PROMPT'},
            }),
          );
          Future.delayed(const Duration(milliseconds: 80), () {
            ws.add(
              jsonEncode({
                'id': msg['id'],
                'type': 'registered',
                'payload': {'client-key': 'test-key'},
              }),
            );
          });
        }
      });
    });
    final client = LgWebOsClient(host: '127.0.0.1', port: server.port);
    var completed = false;
    final pending = client.connect()..then((_) => completed = true);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(completed, isFalse);
    expect(await pending, isTrue);
    expect(client.isConnected, isTrue);
    await client.disconnect();
    expect(await client.connect(), isTrue);
    expect((registrations.last['payload'] as Map)['client-key'], 'test-key');
    await client.disconnect();
    for (final socket in sockets) {
      await socket.close();
    }
    await server.close(force: true);
  });

  test(
    'cast service sends a TV reachable relay and closes it on stop',
    () async {
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      upstream.listen((req) async {
        req.response.write('video');
        await req.response.close();
      });
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      Map<String, dynamic>? media;
      server.listen((request) async {
        final ws = await WebSocketTransformer.upgrade(request);
        ws.listen((data) {
          final msg = jsonDecode(data as String) as Map<String, dynamic>;
          if (msg['type'] == 'register') {
            ws.add(
              jsonEncode({
                'type': 'registered',
                'id': msg['id'],
                'payload': {'client-key': 'key'},
              }),
            );
          } else {
            if (msg['uri'] == 'ssap://media.viewer/open') media = msg;
            ws.add(
              jsonEncode({
                'type': 'response',
                'id': msg['id'],
                'payload': {'returnValue': true},
              }),
            );
          }
        });
      });
      final client = LgWebOsClient(host: '127.0.0.1', port: server.port);
      expect(await client.connect(), isTrue);
      final service = CastService();
      final device = CastDevice(
        id: 'test',
        name: 'LG',
        type: 'webos',
        webosClient: client,
      );
      ServerEgress.installGuard();
      expect(
        await service.castTo(device, 'http://127.0.0.1:${upstream.port}/'),
        isTrue,
      );
      final target = Uri.parse((media!['payload'] as Map)['target'] as String);
      expect(target.port, isNot(upstream.port));
      final http = HttpClient();
      final response = await (await http.getUrl(target)).close();
      expect(await utf8.decoder.bind(response).join(), 'video');
      await service.stopCasting();
      expect(service.isCasting, isFalse);
      http.close(force: true);
      service.dispose();
      await client.disconnect();
      await server.close(force: true);
      await upstream.close(force: true);
      HttpOverrides.global = null;
    },
  );

  test(
    'rejected pairing and timeout do not mark the client connected',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var reject = true;
      server.listen((req) async {
        final ws = await WebSocketTransformer.upgrade(req);
        ws.listen((data) {
          if (reject) {
            final msg = jsonDecode(data as String) as Map;
            ws.add(
              jsonEncode({
                'id': msg['id'],
                'type': 'error',
                'error': 'rejected',
              }),
            );
          }
        });
      });
      final client = LgWebOsClient(host: '127.0.0.1', port: server.port);
      expect(
        await client.connect(timeout: const Duration(seconds: 1)),
        isFalse,
      );
      expect(client.isConnected, isFalse);
      reject = false;
      expect(
        await client.connect(timeout: const Duration(milliseconds: 80)),
        isFalse,
      );
      expect(client.isConnected, isFalse);
      await server.close(force: true);
    },
  );

  test(
    'DLNA discovery processes replies on its search socket and deduplicates',
    () async {
      var descriptionRequests = 0;
      final description = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      description.listen((req) async {
        descriptionRequests++;
        req.response.write(
          '<root><device><deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>'
          '<friendlyName>Test TV</friendlyName><serviceList><service>'
          '<serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>'
          '<serviceId>urn:upnp-org:serviceId:AVTransport</serviceId>'
          '<controlURL>/control</controlURL></service></serviceList></device></root>',
        );
        await req.response.close();
      });
      final responder = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      responder.listen((event) {
        if (event != RawSocketEvent.read) return;
        final request = responder.receive();
        if (request == null) return;
        final reply = ascii.encode(
          'HTTP/1.1 200 OK\r\nLOCATION: http://127.0.0.1:${description.port}/device.xml\r\n\r\n',
        );
        responder.send(reply, request.address, request.port);
        responder.send(reply, request.address, request.port);
      });
      final discovery = DlnaDiscovery();
      ServerEgress.installGuard();
      final manager = await discovery.start(
        searchAddress: InternetAddress.loopbackIPv4,
        searchPort: responder.port,
      );
      final devices = await manager.devices.stream.first.timeout(
        const Duration(seconds: 3),
      );
      expect(devices.values.single.info.friendlyName, 'Test TV');
      expect(descriptionRequests, 1);
      await discovery.stop();
      responder.close();
      await description.close(force: true);
      HttpOverrides.global = null;
    },
  );

  test('DLNA discovery can stop before a listener is attached', () async {
    final discovery = DlnaDiscovery();
    await discovery.start(
      searchAddress: InternetAddress.loopbackIPv4,
      searchPort: 9999,
    );
    await discovery.stop().timeout(const Duration(seconds: 1));
  });

  test('DLNA sends valid metadata and a reachable relay before play', () async {
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    upstream.listen((req) async {
      req.response.write('video');
      await req.response.close();
    });
    final renderer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final actions = <String>[];
    String? mediaUrl;
    renderer.listen((req) async {
      final action = req.headers.value('SOAPAction') ?? '';
      actions.add(action);
      final xml = XmlDocument.parse(await utf8.decoder.bind(req).join());
      if (action.contains('SetAVTransportURI')) {
        mediaUrl = xml.findAllElements('CurrentURI').single.innerText;
        final metadata = XmlDocument.parse(
          xml.findAllElements('CurrentURIMetaData').single.innerText,
        );
        expect(metadata.findAllElements('dc:title').single.innerText, 'A & B');
        final resource = metadata.findAllElements('res').single;
        expect(resource.innerText, mediaUrl);
        expect(
          resource.getAttribute('protocolInfo'),
          'http-get:*:video/mp2t:*',
        );
      }
      req.response.headers.contentType = ContentType('text', 'xml');
      req.response.write('<ok/>');
      await req.response.close();
    });
    final base = 'http://127.0.0.1:${renderer.port}';
    final info = DeviceInfo(
      base,
      'urn:schemas-upnp-org:device:MediaRenderer:1',
      'TV',
      [
        {
          'serviceId': 'urn:upnp-org:serviceId:AVTransport',
          'controlURL': '/control',
        },
      ],
    );
    final service = CastService();
    final device = CastDevice(
      id: 'dlna',
      name: 'TV',
      type: 'dlna',
      dlnaDevice: DLNADevice(info),
    );
    ServerEgress.installGuard();
    expect(
      await service.castTo(
        device,
        'http://127.0.0.1:${upstream.port}/',
        title: 'A & B',
      ),
      isTrue,
    );
    expect(actions[0], contains('SetAVTransportURI'));
    expect(actions[1], contains('#Play'));
    final target = Uri.parse(mediaUrl!);
    expect(target.port, isNot(upstream.port));
    final http = HttpClient();
    expect(
      await utf8.decoder.bind(await (await http.getUrl(target)).close()).join(),
      'video',
    );
    await service.stopCasting();
    http.close(force: true);
    service.dispose();
    await renderer.close(force: true);
    await upstream.close(force: true);
    HttpOverrides.global = null;
  });

  test(
    'DLNA transport rejection is not reported as a successful cast',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      server.listen((req) async {
        requests++;
        await req.drain<void>();
        req.response.statusCode = HttpStatus.internalServerError;
        await req.response.close();
      });
      final info = DeviceInfo(
        'http://127.0.0.1:${server.port}',
        'urn:schemas-upnp-org:device:MediaRenderer:1',
        'TV',
        [
          {
            'serviceId': 'urn:upnp-org:serviceId:AVTransport',
            'controlURL': '/control',
          },
        ],
      );
      final service = CastService();
      final device = CastDevice(
        id: 'dlna',
        name: 'TV',
        type: 'dlna',
        dlnaDevice: DLNADevice(info),
      );
      expect(
        await service.castTo(device, 'https://example.test/live.m3u8'),
        isFalse,
      );
      expect(service.isCasting, isFalse);
      expect(requests, 1);
      service.dispose();
      await server.close(force: true);
    },
  );

  test('media viewer receives target and HLS type', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    Map<String, dynamic>? media;
    server.listen((request) async {
      final ws = await WebSocketTransformer.upgrade(request);
      ws.listen((data) {
        final message = jsonDecode(data as String) as Map<String, dynamic>;
        if (message['type'] == 'register') {
          ws.add(
            jsonEncode({
              'type': 'registered',
              'id': message['id'],
              'payload': {'client-key': 'key'},
            }),
          );
        } else {
          media = message;
          ws.add(
            jsonEncode({
              'type': 'response',
              'id': message['id'],
              'payload': {'returnValue': true},
            }),
          );
        }
      });
    });
    final client = LgWebOsClient(host: '127.0.0.1', port: server.port);
    expect(await client.connect(), isTrue);
    await client.playMedia('https://example.test/live.m3u8?x=1');
    expect(media?['uri'], 'ssap://media.viewer/open');
    expect(
      (media?['payload'] as Map)['target'],
      'https://example.test/live.m3u8?x=1',
    );
    expect(
      (media?['payload'] as Map)['mimeType'],
      'application/vnd.apple.mpegurl',
    );
    await client.disconnect();
    await server.close(force: true);
  });

  test('media rejection does not report a successful browser launch', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requests = 0;
    server.listen((request) async {
      final ws = await WebSocketTransformer.upgrade(request);
      ws.listen((data) {
        final msg = jsonDecode(data as String) as Map<String, dynamic>;
        if (msg['type'] == 'register') {
          ws.add(
            jsonEncode({
              'type': 'registered',
              'id': msg['id'],
              'payload': {'client-key': 'key'},
            }),
          );
        } else {
          requests++;
          ws.add(
            jsonEncode({
              'type': 'response',
              'id': msg['id'],
              'payload': {'returnValue': false},
            }),
          );
        }
      });
    });
    final client = LgWebOsClient(host: '127.0.0.1', port: server.port);
    expect(await client.connect(), isTrue);
    await expectLater(
      client.playMedia('https://example.test/live.m3u8'),
      throwsStateError,
    );
    expect(requests, 1);
    await client.disconnect();
    await server.close(force: true);
  });

  test(
    'relay serves only the secret path and forwards local playback',
    () async {
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      upstream.listen((req) async {
        req.response.headers.contentType = ContentType('video', 'mp2t');
        req.response.write('stream-data');
        await req.response.close();
      });
      final relay = LanCastRelay();
      final url = await relay.start(
        Uri.parse('http://127.0.0.1:${upstream.port}/'),
        '127.0.0.1',
        3000,
        localAddress: InternetAddress.loopbackIPv4,
      );
      final client = HttpClient();
      final response = await (await client.getUrl(Uri.parse(url))).close();
      expect(await utf8.decoder.bind(response).join(), 'stream-data');
      expect(response.headers.contentType?.mimeType, 'video/mp2t');
      final invalid = Uri.parse(url).replace(path: '/wrong.ts');
      final denied = await (await client.getUrl(invalid)).close();
      expect(denied.statusCode, HttpStatus.forbidden);
      await denied.drain<void>();
      await expectLater(
        relay.start(
          Uri.parse('http://example.com/'),
          '127.0.0.1',
          3000,
          localAddress: InternetAddress.loopbackIPv4,
        ),
        throwsArgumentError,
      );
      client.close(force: true);
      await relay.close();
      await upstream.close(force: true);
    },
  );
}
