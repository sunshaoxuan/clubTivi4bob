import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

/// Use the normal native close path so independent update workers can finish.
class DesktopExitButton extends StatefulWidget {
  const DesktopExitButton({super.key, this.onClose});

  final Future<void> Function()? onClose;

  @override
  State<DesktopExitButton> createState() => _DesktopExitButtonState();
}

class _DesktopExitButtonState extends State<DesktopExitButton> {
  bool _closing = false;

  Future<void> _close() async {
    if (_closing) return;
    setState(() => _closing = true);
    try {
      await (widget.onClose ?? windowManager.close)();
    } catch (_) {
      if (!mounted) return;
      setState(() => _closing = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('关闭未完成，请重试。')));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux) {
      return const SizedBox.shrink();
    }
    return Tooltip(
      message: '退出 BobTV',
      child: TextButton.icon(
        onPressed: _closing ? null : _close,
        icon: _closing
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.power_settings_new_rounded, size: 20),
        label: Text(_closing ? '正在退出' : '退出'),
        style: TextButton.styleFrom(foregroundColor: Colors.white70),
      ),
    );
  }
}
