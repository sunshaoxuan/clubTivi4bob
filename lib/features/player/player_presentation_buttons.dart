import 'package:flutter/material.dart';
import 'desktop_window_pin_button.dart';

/// Independent actions for filling the application window and native fullscreen.
class PlayerPresentationButtons extends StatelessWidget {
  const PlayerPresentationButtons({
    super.key,
    required this.onFullscreen,
    this.onWindowPlayback,
    this.compact = false,
    this.showWindowPin = false,
  });

  final VoidCallback onFullscreen;
  final VoidCallback? onWindowPlayback;
  final bool compact;
  final bool showWindowPin;

  @override
  Widget build(BuildContext context) {
    Widget button(String tooltip, IconData icon, VoidCallback onPressed) {
      final child = IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(icon, size: compact ? 16 : 24),
        color: compact ? Colors.white70 : const Color(0xFFADC5FF),
        padding: compact ? EdgeInsets.zero : const EdgeInsets.all(8),
      );
      return compact ? SizedBox(width: 28, height: 28, child: child) : child;
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showWindowPin) DesktopWindowPinButton(compact: compact),
        if (onWindowPlayback != null)
          button('全窗口播放', Icons.fit_screen_rounded, onWindowPlayback!),
        button('全屏播放', Icons.fullscreen_rounded, onFullscreen),
      ],
    );
  }
}
