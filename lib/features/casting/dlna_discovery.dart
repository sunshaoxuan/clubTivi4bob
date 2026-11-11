import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dlna_dart/dlna.dart';

/// SSDP search on an ephemeral socket, reading every unicast response.
class DlnaDiscovery {
  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _subscription;
  Timer? _timer;
  DeviceManager? _manager;
  final Map<String, DateTime> _seen = {};
  int _inFlight = 0;
  int _generation = 0;

  Future<DeviceManager> start({
    InternetAddress? searchAddress,
    int searchPort = 1900,
  }) async {
    await stop();
    final generation = ++_generation;
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    if (generation != _generation) {
      socket.close();
      throw StateError('Discovery stopped');
    }
    final manager = DeviceManager();
    _socket = socket;
    _manager = manager;
    final destination = searchAddress ?? InternetAddress('239.255.255.250');
    _subscription = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? datagram;
      while ((datagram = socket.receive()) != null) {
        final bytes = datagram!.data;
        if (bytes.length > 8192) continue;
        final text = utf8.decode(bytes, allowMalformed: true);
        if (!text.startsWith('HTTP/1.1 200') &&
            !text.startsWith('HTTP/1.0 200'))
          continue;
        final location = RegExp(
          r'^location:\s*(\S+)',
          caseSensitive: false,
          multiLine: true,
        ).firstMatch(text)?.group(1);
        if (location == null || _inFlight >= 5) continue;
        final previous = _seen[location];
        if (previous != null &&
            DateTime.now().difference(previous) < const Duration(seconds: 15))
          continue;
        if (_seen.length >= 512) _seen.clear();
        _seen[location] = DateTime.now();
        _inFlight++;
        unawaited(
          manager
              .onMessage(text)
              .catchError((_) {})
              .whenComplete(() => _inFlight--),
        );
      }
    });
    void search() {
      const request =
          'M-SEARCH * HTTP/1.1\r\n'
          'HOST: 239.255.255.250:1900\r\n'
          'MAN: "ssdp:discover"\r\n'
          'MX: 2\r\n'
          'ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n';
      socket.send(ascii.encode(request), destination, searchPort);
    }

    search();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => search());
    return manager;
  }

  Future<void> stop() async {
    ++_generation;
    _timer?.cancel();
    _timer = null;
    await _subscription?.cancel();
    _subscription = null;
    _socket?.close();
    _socket = null;
    _manager?.devices.close();
    _manager = null;
    _seen.clear();
  }
}
