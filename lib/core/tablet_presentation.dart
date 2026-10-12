import 'package:flutter/painting.dart';

/// One presentation policy for desktop windows and touch tablets.
class TabletPresentation {
  static const videoFit = BoxFit.contain;

  static bool useSimpleHome({
    required bool simpleMode,
    required bool television,
  }) => simpleMode && !television;

  static bool splitLayout({required double width, required double height}) =>
      width >= 1050 || (width >= 900 && width > height);

  static double previewHeight(double availableHeight) =>
      (availableHeight * .44).clamp(140.0, 340.0);
}
