import 'package:flutter/material.dart';

import '../../core/app_diagnostics.dart';
import '../../core/desktop_window_pin.dart';

class DesktopWindowPinButton extends StatelessWidget {
  const DesktopWindowPinButton({
    super.key,
    this.controller,
    this.compact = false,
  });

  final DesktopWindowPin? controller;
  final bool compact;

  Future<void> _toggle(BuildContext context, DesktopWindowPin pin) async {
    try {
      await pin.toggle();
    } catch (error, stack) {
      AppDiagnostics.instance.recordError('desktop_window_pin', error, stack);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error is WindowPinRequiresWindowMode
                ? '请先退出全屏，再调整窗口置顶'
                : '窗口置顶切换失败，请重试',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final pin = controller ?? DesktopWindowPin.instance;
    return AnimatedBuilder(
      animation: pin,
      builder: (context, _) {
        final button = Semantics(
          toggled: pin.pinned,
          child: IconButton(
            tooltip: pin.pinned ? '取消置顶' : '窗口置顶',
            onPressed: pin.canToggle ? () => _toggle(context, pin) : null,
            icon: Icon(
              pin.pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
              size: compact ? 16 : 24,
            ),
            color: pin.pinned ? Colors.amber : const Color(0xFFADC5FF),
            padding: compact ? EdgeInsets.zero : const EdgeInsets.all(8),
          ),
        );
        return compact
            ? SizedBox(width: 28, height: 28, child: button)
            : button;
      },
    );
  }
}
