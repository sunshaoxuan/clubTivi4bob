import 'dart:math' as math;

import 'package:flutter/painting.dart';

/// One presentation policy for desktop windows and touch tablets.
class TabletPresentation {
  static const videoFit = BoxFit.contain;

  static bool useSimpleHome({
    required bool simpleMode,
    required bool television,
  }) => simpleMode && !television;

  static bool splitLayout({
    required double width,
    required double height,
    bool touchPortrait = false,
  }) => width >= 640 && !touchPortrait;

  /// Allow a wide video plus its channel information above the browsing area.
  static double portraitPreviewHeight(double width, double height) => math.min(
    (width - 36).clamp(0.0, double.infinity) * 9 / 16 + 112,
    height * .52,
  );

  static double compactCardHeight(
    double availableHeight,
    double guideHeight, {
    bool tiny = false,
  }) => (availableHeight - guideHeight - 14).clamp(tiny ? 56.0 : 80.0, 140.0);

  static double previewHeight(double availableHeight) =>
      (availableHeight * .44).clamp(140.0, 340.0);

  static int channelColumns(
    double width, {
    required bool compact,
    bool tiny = false,
  }) =>
      (width /
              (tiny
                  ? 140
                  : compact
                  ? 180
                  : 250))
          .floor()
          .clamp(1, 5);
}
