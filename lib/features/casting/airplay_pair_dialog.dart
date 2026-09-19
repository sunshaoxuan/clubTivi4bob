import 'package:flutter/material.dart';
import 'cast_service.dart';

Future<bool> pairAirPlay(
  BuildContext context,
  CastService service,
  CastDevice device,
) async {
  return await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _PairDialog(service: service, device: device),
      ) ??
      false;
}

class _PairDialog extends StatefulWidget {
  final CastService service;
  final CastDevice device;
  const _PairDialog({required this.service, required this.device});
  @override
  State<_PairDialog> createState() => _PairDialogState();
}

class _PairDialogState extends State<_PairDialog> {
  String _pin = '';
  String? _error;
  bool _busy = true;
  bool _ready = false;
  @override
  void initState() {
    super.initState();
    _begin();
  }

  Future<void> _begin() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.service.beginPairing(widget.device);
      if (mounted)
        setState(() {
          _ready = true;
          _busy = false;
        });
    } catch (error) {
      if (mounted)
        setState(() {
          _error = error.toString();
          _busy = false;
        });
    }
  }

  Future<void> _finish() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.service.finishPairing(widget.device, _pin);
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted)
        setState(() {
          _error = error.toString();
          _busy = false;
          _ready = false;
          _pin = '';
        });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    child: AlertDialog(
      title: Text('配對 ${widget.device.name}'),
      content: SizedBox(
        width: 310,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('請點選電視畫面上的四位驗證碼'),
            const SizedBox(height: 12),
            Text(
              _pin.padRight(4, '○'),
              style: const TextStyle(fontSize: 30, letterSpacing: 10),
            ),
            if (_busy) const LinearProgressIndicator(),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  _error!,
                  style: const TextStyle(color: Colors.orange),
                ),
              ),
            const SizedBox(height: 12),
            for (final row in ['123', '456', '789', '⌫0C'])
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: row
                    .split('')
                    .map(
                      (key) => SizedBox(
                        width: 88,
                        height: 48,
                        child: TextButton(
                          onPressed: !_ready || _busy
                              ? null
                              : () => setState(() {
                                  if (key == 'C') {
                                    _pin = '';
                                  } else if (key == '⌫') {
                                    if (_pin.isNotEmpty)
                                      _pin = _pin.substring(0, _pin.length - 1);
                                  } else if (_pin.length < 4) {
                                    _pin += key;
                                  }
                                }),
                          child: Text(
                            key,
                            style: const TextStyle(fontSize: 22),
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await widget.service.cancelPairing();
            if (context.mounted) Navigator.of(context).pop(false);
          },
          child: const Text('取消'),
        ),
        if (!_ready && !_busy)
          TextButton(onPressed: _begin, child: const Text('重新配對')),
        FilledButton(
          onPressed: _ready && !_busy && _pin.length == 4 ? _finish : null,
          child: const Text('配對'),
        ),
      ],
    ),
  );
}
