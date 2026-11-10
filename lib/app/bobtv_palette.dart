import 'package:flutter/material.dart';

/// Shared BobTV colors for the app chrome and product screens.
abstract final class BobTvPalette {
  static const background = Color(0xFF101322);
  static const deep = Color(0xFF0B0C15);
  static const panel = Color(0xFF191C2E);
  static const raised = Color(0xFF20243A);
  static const selected = Color(0xFF30264B);
  static const outline = Color(0xFF5D5277);
  static const ink = Color(0xFFF8F7FF);
  static const muted = Color(0xFFB7BBD0);
  static const accent = Color(0xFFC3AAFF);
  static const pink = Color(0xFFFF9EE1);
  static const action = Color(0xFF7048AD);
  static const onAccent = Color(0xFF1A102C);
  static const glow = Color(0xFF272044);

  static const pageGradient = [glow, background, deep];
  static const panelGradient = [raised, panel, background];
  static const brandGradient = LinearGradient(colors: [accent, pink]);
}
