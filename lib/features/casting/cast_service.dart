import 'dart:async';

import 'package:dlna_dart/dlna.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';

import 'lg_webos_client.dart';
import 'airplay_bridge.dart';

final _log = Logger(printer: SimplePrinter());

/// Represents a discovered cast target on the local network.
class CastDevice {
  final String id;
  final String name;
  final String type; // 'dlna' or 'webos'
  final DLNADevice? dlnaDevice;
  final LgWebOsClient? webosClient;
  final bool requiresPairing;
  bool paired;

  CastDevice({
    required this.id,
    required this.name,
    required this.type,
    this.dlnaDevice,
    this.webosClient,
    this.requiresPairing = false,
    this.paired = false,
  });

  @override
  String toString() => '$name ($type)';
}

/// Manages device discovery and casting of IPTV streams via DLNA/UPnP.
class CastService {
  final AirPlayBridge _airplay;
  final _status = StreamController<String?>.broadcast();
  Stream<String?> get statusStream => _status.stream;
  String? lastError;
  bool relayAirPlay = true;
  int _discoveryGeneration = 0;
  Future<void> _queue = Future.value();
  int _castGeneration = 0;
  bool _disposed = false;

  CastService({AirPlayBridge? airplay})
    : _airplay = airplay ?? AirPlayBridge() {
    _airplay.events.listen((event) {
      if (_disposed) return;
      if (event['event'] == 'error') {
        lastError = event['message'] as String?;
        if (_activeDevice?.type == 'airplay') _isCasting = false;
        _status.add(lastError);
      } else if (event['event'] == 'ended' &&
          _activeDevice?.type == 'airplay') {
        _isCasting = false;
        _status.add('AirPlay 播放已結束或未能啟動，請確認電視畫面與視頻格式。');
      }
    });
  }

  Future<void> _scanAirPlay(int generation, {String? host}) async {
    try {
      final result = await _airplay.request('scan', {
        if (host != null) 'host': host,
      });
      if (_disposed || generation != _discoveryGeneration) return;
      for (final item in result['devices'] as List) {
        final device = CastDevice(
          id: 'airplay_${item['id']}',
          name: item['name'] as String,
          type: 'airplay',
          paired: item['paired'] == true,
          requiresPairing: item['requiresPairing'] == true,
        );
        _devices[device.id] = device;
      }
      _devicesController.add(devices);
    } catch (error) {
      if (!_disposed && generation == _discoveryGeneration) {
        lastError = error.toString();
        _status.add(lastError);
      }
    }
  }

  Future<void> beginPairing(CastDevice device) async {
    final result = await _airplay.request('pair_start', {
      'device': device.id.substring(8),
    });
    if (result['deviceProvidesPin'] != true) {
      await cancelPairing();
      throw StateError('此設備需要在接收端輸入驗證碼，目前請使用電視顯示驗證碼的配對模式。');
    }
  }

  Future<void> finishPairing(CastDevice device, String pin) async {
    await _airplay.request('pair_finish', {'pin': pin});
    device.paired = true;
  }

  Future<void> cancelPairing() async {
    try {
      await _airplay.request('pair_cancel');
    } catch (_) {}
  }

  DLNAManager? _dlnaManager;
  DeviceManager? _deviceManager;
  StreamSubscription? _deviceSub;

  final _devicesController = StreamController<List<CastDevice>>.broadcast();
  final Map<String, CastDevice> _devices = {};

  CastDevice? _activeDevice;
  String? _activeUrl;
  bool _isCasting = false;

  /// Stream of discovered cast devices.
  Stream<List<CastDevice>> get devicesStream => _devicesController.stream;

  /// Currently available devices.
  List<CastDevice> get devices => _devices.values.toList();

  /// Whether we are actively casting.
  bool get isCasting => _isCasting;

  /// The device we are casting to.
  CastDevice? get activeDevice => _activeDevice;

  /// Start scanning for DLNA/UPnP devices on the local network.
  /// LG WebOS TVs can be slow to respond — uses fallback if needed.
  Future<void> startDiscovery() async {
    await stopDiscovery();
    _devices.clear();
    lastError = null;
    final generation = ++_discoveryGeneration;
    unawaited(_scanAirPlay(generation));
    _dlnaManager = DLNAManager();
    try {
      _deviceManager = await _dlnaManager!.start(reusePort: false);
      _listenToDevices();
      _log.i('DLNA discovery started');
    } catch (e) {
      _log.e('DLNA discovery failed: $e');
      // Retry with reusePort if bind fails (port already in use)
      try {
        _deviceManager = await _dlnaManager!.start(reusePort: true);
        _listenToDevices();
        _log.i('DLNA discovery started (reusePort fallback)');
      } catch (e2) {
        _log.e('DLNA discovery failed on retry: $e2');
      }
    }
  }

  void _listenToDevices() {
    _deviceSub = _deviceManager!.devices.stream.listen((deviceMap) {
      _devices.removeWhere((key, value) => value.type == 'dlna');
      for (final entry in deviceMap.entries) {
        final dlna = entry.value;
        final name = dlna.info.friendlyName;
        _devices[entry.key] = CastDevice(
          id: entry.key,
          name: name.isNotEmpty ? name : 'Unknown Device',
          type: 'dlna',
          dlnaDevice: dlna,
        );
      }
      _devicesController.add(_devices.values.toList());
    });
  }

  /// Stop scanning.
  Future<void> stopDiscovery() async {
    _discoveryGeneration++;
    _deviceSub?.cancel();
    _deviceSub = null;
    _dlnaManager?.stop();
    _dlnaManager = null;
    _deviceManager = null;
  }

  /// Cast a stream URL to the given device.
  Future<bool> castTo(
    CastDevice device,
    String url, {
    String title = '',
  }) async {
    final generation = ++_castGeneration;
    final result = Completer<bool>();
    _queue = _queue
        .then((_) async {
          if (_disposed || generation != _castGeneration) {
            result.complete(false);
            return;
          }
          result.complete(await _castTo(device, url, title: title));
        })
        .catchError((Object error) {
          if (!result.isCompleted) result.complete(false);
        });
    return result.future;
  }

  Future<bool> _castTo(
    CastDevice device,
    String url, {
    String title = '',
  }) async {
    lastError = null;
    try {
      if (_activeDevice != null && _activeDevice!.id != device.id)
        await _stopActive();
      if (device.type == 'airplay') {
        await _airplay.request('play', {
          'device': device.id.substring(8),
          'url': url,
          'relay': relayAirPlay,
        });
        _activeDevice = device;
        _activeUrl = url;
        _isCasting = true;
        _status.add(null);
        return true;
      } else if (device.type == 'webos' && device.webosClient != null) {
        await device.webosClient!.playMedia(url, title: title);
        _activeDevice = device;
        _activeUrl = url;
        _isCasting = true;
        _log.i('Casting via WebOS');
        return true;
      } else if (device.dlnaDevice != null) {
        await device.dlnaDevice!.setUrl(url, title: title);
        await device.dlnaDevice!.play();
        _activeDevice = device;
        _activeUrl = url;
        _isCasting = true;
        _log.i('Casting via DLNA');
        return true;
      }
      return false;
    } catch (e) {
      _isCasting = false;
      lastError = device.type == 'airplay' ? e.toString() : '投屏失敗，請確認電視與網路連接。';
      _status.add(lastError);
      return false;
    }
  }

  /// Stop casting on the active device.
  Future<void> stopCasting() async {
    ++_castGeneration;
    _queue = _queue.then((_) => _stopActive());
    await _queue;
  }

  Future<void> _stopActive() async {
    try {
      if (_activeDevice?.type == 'airplay') {
        await _airplay.request('stop');
      } else if (_activeDevice?.type == 'webos') {
        await _activeDevice?.webosClient?.stop();
      } else if (_activeDevice?.dlnaDevice != null) {
        await _activeDevice!.dlnaDevice!.stop();
      }
    } catch (e) {
      _log.e('Stop cast error: $e');
    }
    _activeDevice = null;
    _activeUrl = null;
    _isCasting = false;
    if (!_disposed) _status.add(null);
  }

  /// Pause playback on the active device.
  Future<void> pause() async {
    try {
      if (_activeDevice?.type == 'airplay') {
        await _airplay.request('pause');
      } else if (_activeDevice?.type == 'webos') {
        await _activeDevice?.webosClient?.pause();
      } else {
        await _activeDevice?.dlnaDevice?.pause();
      }
    } catch (e) {
      if (!_disposed) _status.add('此接收設備未能暫停播放，請使用電視遙控器。');
    }
  }

  /// Resume playback on the active device.
  Future<void> resume() async {
    try {
      if (_activeDevice?.type == 'airplay') {
        await _airplay.request('resume');
      } else if (_activeDevice?.type == 'webos') {
        await _activeDevice?.webosClient?.play();
      } else {
        await _activeDevice?.dlnaDevice?.play();
      }
    } catch (e) {
      if (!_disposed) _status.add('此接收設備未能恢復播放，請使用電視遙控器。');
    }
  }

  /// Set volume (0-100) on the active device.
  Future<void> setVolume(int volume) async {
    try {
      if (_activeDevice?.type == 'airplay') {
        await _airplay.request('volume', {'volume': volume});
      } else if (_activeDevice?.type == 'webos') {
        await _activeDevice?.webosClient?.setVolume(volume.clamp(0, 100));
      } else {
        await _activeDevice?.dlnaDevice?.volume(volume.clamp(0, 100));
      }
    } catch (e) {
      if (!_disposed) _status.add('此接收設備未能調整音量，請使用電視遙控器。');
    }
  }

  /// Switch channel: cast a new URL to the same device.
  Future<bool> switchChannel(String url, {String title = ''}) async {
    if (_activeDevice == null || !_isCasting) return false;
    if (_activeUrl == url) return true;
    return castTo(_activeDevice!, url, title: title);
  }

  /// Add a device manually by IP address.
  /// Probes for LG WebOS (port 3000) first, then adds as generic DLNA.
  Future<CastDevice?> addManualDevice(String ip) async {
    final previous = _devices.keys.toSet();
    await _scanAirPlay(_discoveryGeneration, host: ip);
    final added = _devices.values.where(
      (d) => d.type == 'airplay' && !previous.contains(d.id),
    );
    if (added.isNotEmpty) return added.first;
    // Try LG WebOS first
    final isWebOs = await LgWebOsClient.probe(ip);
    if (isWebOs) {
      final client = LgWebOsClient(host: ip);
      final connected = await client.connect();
      String name = 'LG TV ($ip)';
      if (connected) {
        try {
          final info = await client.getSystemInfo();
          final model = info['modelName'] as String? ?? '';
          if (model.isNotEmpty) name = 'LG $model';
        } catch (_) {}
      }
      final device = CastDevice(
        id: 'webos_$ip',
        name: name,
        type: 'webos',
        webosClient: client,
      );
      _devices[device.id] = device;
      _devicesController.add(_devices.values.toList());
      return device;
    }
    return null;
  }

  void dispose() {
    _disposed = true;
    ++_castGeneration;
    _airplay.dispose();
    stopDiscovery();
    _status.close();
    _devicesController.close();
  }
}

/// Riverpod provider for the cast service (singleton).
final castServiceProvider = Provider<CastService>((ref) {
  final service = CastService();
  ref.onDispose(() => service.dispose());
  return service;
});
