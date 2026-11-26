import 'dart:async';
import 'package:flutter/material.dart';
import 'cast_service.dart';
import '../../core/i18n/app_language.dart';

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
  final _password = TextEditingController();
  String? _mode;
  bool get _passwordMode => _mode == 'password';
  String? _error;
  bool _busy = true;
  bool _ready = false;
  @override
  void initState() {
    super.initState();
    if (widget.device.nativeMac) {
      _busy = false;
    } else {
      _mode = widget.device.passwordRequired ? 'password' : 'pin';
      _begin();
    }
  }

  Future<void> _begin() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.service.beginPairing(widget.device, mode: _mode);
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
      await widget.service.finishPairing(
        widget.device,
        _passwordMode ? _password.text : _pin,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted)
        setState(() {
          _error = error.toString();
          _busy = false;
          _ready = false;
          _pin = '';
          _password.clear();
        });
    }
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    child: AlertDialog(
      title: Text(AppMessages.text(context, "配對 {0}", [widget.device.name])),
      content: SizedBox(
        width: 310,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.device.nativeMac)
              SegmentedButton<String>(
                segments: [
                  ButtonSegment(
                    value: 'pin',
                    label: Text(AppMessages.text(context, '屏幕验证码')),
                  ),
                  ButtonSegment(
                    value: 'password',
                    label: Text(AppMessages.text(context, '接收密码')),
                  ),
                ],
                selected: {if (_mode != null) _mode!},
                emptySelectionAllowed: true,
                onSelectionChanged: _busy
                    ? null
                    : (selection) async {
                        if (selection.isEmpty) return;
                        setState(() => _busy = true);
                        await widget.service.cancelPairing();
                        if (!mounted) return;
                        setState(() {
                          _mode = selection.single;
                          _ready = false;
                          _pin = '';
                          _password.clear();
                        });
                        await _begin();
                      },
              ),
            if (widget.device.nativeMac && _mode == null)
              Text(
                AppMessages.text(
                  context,
                  '请选择 Mac 当前使用的认证方式。已开启“需要密码”时选择接收密码。',
                ),
              ),
            if (_mode != null)
              Text(
                _busy
                    ? AppMessages.text(context, "正在向接收設備請求配對…")
                    : _ready && _passwordMode
                    ? AppMessages.text(
                        context,
                        '请输入接收端设置的 AirPlay 密码。密码仅在本次应用运行期间使用，不写入日志或保存到磁盘。',
                      )
                    : _ready
                    ? AppMessages.text(
                        context,
                        "如果接收設備顯示了四位驗證碼，請在下方輸入。沒有顯示請取消。",
                      )
                    : AppMessages.text(context, "接收設備未能進入配對流程。"),
              ),
            const SizedBox(height: 12),
            if (_passwordMode)
              TextField(
                controller: _password,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                maxLength: 64,
                enabled: _ready && !_busy,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: AppMessages.text(context, 'AirPlay 密码'),
                ),
                onSubmitted: (_) {
                  if (_ready && !_busy && _password.text.isNotEmpty) _finish();
                },
              )
            else if (_mode != null)
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
            if (_mode != null && !_passwordMode)
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
                                        _pin = _pin.substring(
                                          0,
                                          _pin.length - 1,
                                        );
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
          onPressed: () {
            unawaited(widget.service.cancelPairing());
            Navigator.of(context).pop(false);
          },
          child: Text(AppMessages.text(context, "取消")),
        ),
        if (_mode != null && !_ready && !_busy)
          TextButton(
            onPressed: _begin,
            child: Text(AppMessages.text(context, "重新配對")),
          ),
        FilledButton(
          onPressed:
              _ready &&
                  !_busy &&
                  (_passwordMode ? _password.text.isNotEmpty : _pin.length == 4)
              ? _finish
              : null,
          child: Text(AppMessages.text(context, "配對")),
        ),
      ],
    ),
  );
}
