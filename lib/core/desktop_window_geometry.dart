import 'dart:math' as math;
import 'dart:ui';

/// Limits the OUTER frame, including native chrome and the app toolbar.
/// Inputs use window_manager coordinates; the cap uses physical screen pixels.
Rect boundedDesktopWindowBounds(
  Rect requested,
  List<Rect> workAreas, {
  double pixelRatio = 1,
  Size minimum = const Size(800, 500),
}) {
  final scale = pixelRatio.isFinite && pixelRatio > 0 ? pixelRatio : 1.0;
  final valid = [
    requested.left,
    requested.top,
    requested.width,
    requested.height,
  ].every((v) => v.isFinite);
  final frame = valid ? requested : const Rect.fromLTWH(0, 0, 1000, 650);
  final areas = workAreas
      .where(
        (r) =>
            !r.isEmpty &&
            [r.left, r.top, r.right, r.bottom].every((v) => v.isFinite),
      )
      .toList();
  Rect? area;
  double overlap = -1;
  double distance = double.infinity;
  for (final candidate in areas) {
    final intersection = frame.intersect(candidate);
    final amount = intersection.isEmpty
        ? 0.0
        : intersection.width * intersection.height;
    final offset = candidate.center - frame.center;
    final squaredDistance = offset.distanceSquared;
    if (amount > overlap || (amount == overlap && squaredDistance < distance)) {
      area = candidate;
      overlap = amount;
      distance = squaredDistance;
    }
  }
  final maxWidth = math.min(1920.0 / scale, area?.width ?? double.infinity);
  final maxHeight = math.min(1280.0 / scale, area?.height ?? double.infinity);
  final width = (frame.width > 0 ? frame.width : 1000.0)
      .clamp(math.min(minimum.width, maxWidth), maxWidth)
      .toDouble();
  final height = (frame.height > 0 ? frame.height : 650.0)
      .clamp(math.min(minimum.height, maxHeight), maxHeight)
      .toDouble();
  return Rect.fromLTWH(
    area == null
        ? frame.left
        : frame.left.clamp(area.left, area.right - width).toDouble(),
    area == null
        ? frame.top
        : frame.top.clamp(area.top, area.bottom - height).toDouble(),
    width,
    height,
  );
}
