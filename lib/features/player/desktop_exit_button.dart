import 'dart:io';

import 'package:flutter/material.dart';
import '../../core/desktop_app_exit.dart';
import '../../core/i18n/app_language.dart';

/// Use the normal native close path so independent update workers can finish.
class DesktopExitButton extends StatefulWidget {
  const DesktopExitButton({super.key, this.onClose, this.compact = false});

  final Future<void> Function()? onClose;
  final bool compact;

  @override
  State<DesktopExitButton> createState() => _DesktopExitButtonState();
}

class _DesktopExitButtonState extends State<DesktopExitButton> {
  bool _closing = false;

  Future<void> _close() async {
    if (_closing) return;
    setState(() => _closing = true);
    try {
      await (widget.onClose ??
          () => DesktopAppExit.request('header_exit_button'))();
    } catch (_) {
      if (!mounted) return;
      setState(() => _closing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppMessages.text(context, "关闭未完成，请重试。"))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux) {
      return const SizedBox.shrink();
    }
    final tooltip = AppMessages.text(context, "退出 BobTV");
    final icon = _closing
        ? const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : const Icon(Icons.power_settings_new_rounded, size: 20);
    if (widget.compact) {
      return IconButton(
        tooltip: tooltip,
        onPressed: _closing ? null : _close,
        color: Colors.white70,
        icon: icon,
      );
    }
    return Tooltip(
      message: tooltip,
      child: TextButton.icon(
        onPressed: _closing ? null : _close,
        icon: icon,
        label: Text(
          _closing
              ? AppMessages.text(context, "正在退出")
              : AppMessages.text(context, "退出"),
        ),
        style: TextButton.styleFrom(foregroundColor: Colors.white70),
      ),
    );
  }
}
