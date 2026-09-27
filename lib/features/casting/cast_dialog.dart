import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'cast_service.dart';
import 'airplay_pair_dialog.dart';

/// Shows a dialog to discover and select a cast target device.
Future<CastDevice?> showCastDialog(BuildContext context, WidgetRef ref) async {
  return showDialog<CastDevice>(
    context: context,
    builder: (ctx) => _CastDialog(ref: ref),
  );
}

class _CastDialog extends StatefulWidget {
  final WidgetRef ref;
  const _CastDialog({required this.ref});

  @override
  State<_CastDialog> createState() => _CastDialogState();
}

class _CastDialogState extends State<_CastDialog> {
  late final CastService _castService;
  StreamSubscription? _sub;
  StreamSubscription? _statusSub;
  Timer? _scanTimer;
  String? _error;
  List<CastDevice> _devices = [];
  bool _scanning = true;

  @override
  void initState() {
    super.initState();
    _castService = widget.ref.read(castServiceProvider);
    _statusSub = _castService.statusStream.listen((message) {
      if (mounted) setState(() => _error = message);
    });
    _startScan();
  }

  void _startScan() async {
    await _sub?.cancel();
    _scanTimer?.cancel();
    _sub = _castService.devicesStream.listen((devices) {
      if (mounted) setState(() => _devices = devices);
    });
    await _castService.startDiscovery();
    // Stop auto-scanning after 30 seconds
    if (!mounted) return;
    _scanTimer = Timer(const Duration(seconds: 15), () {
      if (mounted) {
        setState(() => _scanning = false);
        _castService.stopDiscovery();
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _statusSub?.cancel();
    _scanTimer?.cancel();
    _castService.stopDiscovery();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1A1A2E),
      title: Row(
        children: [
          const Icon(Icons.cast_rounded, color: Colors.amber, size: 22),
          const SizedBox(width: 8),
          const Text(
            '投屏到電視',
            style: TextStyle(color: Colors.white, fontSize: 16),
          ),
          const Spacer(),
          if (_scanning)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.amber,
              ),
            ),
        ],
      ),
      content: SizedBox(
        width: 320,
        height: 390,
        child: Column(
          children: [
            SwitchListTile(
              title: const Text(
                '由本機轉發 AirPlay 視頻',
                style: TextStyle(color: Colors.white, fontSize: 13),
              ),
              subtitle: const Text(
                '接收設備從 BobTV 取得視頻',
                style: TextStyle(color: Colors.white54, fontSize: 11),
              ),
              value: _castService.relayAirPlay,
              onChanged: (value) =>
                  setState(() => _castService.relayAirPlay = value),
            ),
            if (_error != null && _devices.isNotEmpty)
              Text(
                _error!,
                style: const TextStyle(color: Colors.orange, fontSize: 12),
              ),
            Expanded(
              child: _devices.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _scanning
                                ? Icons.radar_rounded
                                : Icons.cast_connected_rounded,
                            size: 48,
                            color: Colors.white24,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            _scanning
                                ? '正在搜尋 AirPlay / DLNA 設備…'
                                : _error ?? '未找到設備。\n請確認電視開啟投屏，且位於同一網路。',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 13,
                            ),
                          ),
                          if (!_scanning) ...[
                            const SizedBox(height: 16),
                            TextButton.icon(
                              onPressed: () {
                                setState(() {
                                  _scanning = true;
                                  _devices.clear();
                                });
                                _startScan();
                              },
                              icon: const Icon(Icons.refresh_rounded, size: 16),
                              label: const Text('重新搜尋'),
                              style: TextButton.styleFrom(
                                foregroundColor: Colors.amber,
                              ),
                            ),
                          ],
                        ],
                      ),
                    )
                  : ListView.builder(
                      itemCount: _devices.length,
                      itemBuilder: (ctx, i) {
                        final device = _devices[i];
                        final isActive =
                            _castService.activeDevice?.id == device.id;
                        return ListTile(
                          leading: Icon(
                            _iconForDevice(device),
                            color: isActive ? Colors.amber : Colors.white54,
                            size: 28,
                          ),
                          title: Text(
                            device.name,
                            style: TextStyle(
                              color: isActive ? Colors.amber : Colors.white,
                              fontSize: 14,
                              fontWeight: isActive
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                          ),
                          subtitle: Text(
                            device.unavailableReason ?? device.type.toUpperCase(),
                            style: const TextStyle(
                              color: Colors.white38,
                              fontSize: 11,
                            ),
                          ),
                          trailing: device.type == 'airplay'
                              ? IconButton(
                                  tooltip: '配對或重新配對',
                                  icon: const Icon(Icons.password),
                                  onPressed: device.unavailableReason != null ? null : () async {
                                    await pairAirPlay(
                                      context,
                                      _castService,
                                      device,
                                    );
                                    if (mounted) setState(() {});
                                  },
                                )
                              : isActive
                              ? const Icon(
                                  Icons.check_circle_rounded,
                                  color: Colors.amber,
                                  size: 20,
                                )
                              : null,
                          onTap: () => _selectDevice(device),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          hoverColor: Colors.white.withValues(alpha: 0.05),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: _addManualDevice,
          icon: const Icon(Icons.add_rounded, size: 16),
          label: const Text('輸入 IP'),
          style: TextButton.styleFrom(foregroundColor: Colors.amber),
        ),
        if (_castService.isCasting)
          TextButton.icon(
            onPressed: () async {
              await _castService.stopCasting();
              if (context.mounted) Navigator.of(context).pop();
            },
            icon: const Icon(Icons.cast_connected_rounded, size: 16),
            label: const Text('停止投屏'),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('關閉', style: TextStyle(color: Colors.white54)),
        ),
      ],
    );
  }

  IconData _iconForDevice(CastDevice device) {
    if (device.type == 'webos') return Icons.tv_rounded;
    final name = device.name.toLowerCase();
    if (name.contains('apple tv') || name.contains('airplay')) {
      return Icons.tv_rounded;
    } else if (name.contains('chromecast') || name.contains('google')) {
      return Icons.cast_rounded;
    } else if (name.contains('samsung') ||
        name.contains('lg') ||
        name.contains('sony') ||
        name.contains('tv')) {
      return Icons.tv_rounded;
    } else if (name.contains('sonos') || name.contains('speaker')) {
      return Icons.speaker_rounded;
    }
    return Icons.devices_rounded;
  }

  Future<void> _selectDevice(CastDevice device) async {
    if (device.unavailableReason != null) {
      setState(() => _error = device.unavailableReason);
      return;
    }
    if (device.type == 'airplay' && device.requiresPairing && !device.paired) {
      if (!await pairAirPlay(context, _castService, device)) return;
    }
    if (mounted) Navigator.of(context).pop(device);
  }

  Future<void> _addManualDevice() async {
    final controller = TextEditingController();
    final ip = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: const Text(
          '輸入設備 IP',
          style: TextStyle(color: Colors.white, fontSize: 16),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '輸入 AirPlay 或 LG WebOS 電視的 IP 地址。',
              style: TextStyle(color: Colors.white54, fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: '192.168.1.xxx',
                hintStyle: const TextStyle(color: Colors.white24),
                filled: true,
                fillColor: Colors.white.withValues(alpha: 0.05),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('連接', style: TextStyle(color: Colors.amber)),
          ),
        ],
      ),
    );
    controller.dispose();

    if (ip == null || ip.isEmpty) return;

    setState(() => _scanning = true);
    final device = await _castService.addManualDevice(ip);
    if (mounted) {
      setState(() => _scanning = false);
      if (device != null) {
        if (device.type == 'airplay') {
          await _selectDevice(device);
        } else if (device.type == 'webos' &&
            device.webosClient?.isConnected == true) {
          Navigator.of(context).pop(device);
        } else if (device.type == 'webos') {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('請在電視上接受配對請求'),
              backgroundColor: Color(0xFF2D2D44),
            ),
          );
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('在 $ip 未找到相容設備'),
            backgroundColor: Colors.red.shade800,
          ),
        );
      }
    }
  }
}
