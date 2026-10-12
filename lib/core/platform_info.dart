import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';

/// Detects the current platform type for UI adaptation.
///
/// Android's native device mode selects the TV presentation. Touch tablets
/// retain the desktop-style simple home in both orientations and at all DPIs.
class PlatformInfo {
  PlatformInfo._();

  static bool? _isTvOverride;
  static const _device = MethodChannel('bobtv/device');

  /// Query the native device mode before constructing routes. Screen density
  /// never identifies a television: low-density touch tablets also exist.
  static Future<void> initialize() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      final info = await _device.invokeMapMethod<String, dynamic>('info');
      _detectedAsTV = info?['television'] == true;
    } catch (_) {
      _detectedAsTV = false;
    }
  }

  /// Force TV mode (useful for testing on desktop with keyboard).
  static void setTvOverride(bool value) => _isTvOverride = value;

  /// True when running on Android TV (or overridden for testing).
  static bool get isTV {
    if (_isTvOverride != null) return _isTvOverride!;
    if (kIsWeb) return false;
    return Platform.isAndroid && _detectedAsTV;
  }

  static bool get isMobile =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS) && !isTV;

  static bool get isDesktop =>
      !kIsWeb && (Platform.isMacOS || Platform.isLinux || Platform.isWindows);

  /// Cached native TV detection result, initialized before constructing routes.
  static bool _detectedAsTV = false;

  /// Retained for callers; native device detection is initialized before routes.
  static void detectFromContext(BuildContext context) {
    if (_isTvOverride != null) return;
    if (!Platform.isAndroid) return;

    // Native UiModeManager detection owns this state. Accessing MediaQuery
    // here must not turn a tablet into a TV after rotation or DPI changes.
  }
}
