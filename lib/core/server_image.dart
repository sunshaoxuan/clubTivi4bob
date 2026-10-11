import 'package:flutter/material.dart';
import 'server_egress.dart';

/// Render-only relay. Original logo URLs remain in the shared inventory.
class ServerImage {
  static Image network(
    String url, {
    Key? key,
    double? width,
    double? height,
    BoxFit? fit,
    int? cacheWidth,
    int? cacheHeight,
    Color? color,
    BlendMode? colorBlendMode,
    AlignmentGeometry alignment = Alignment.center,
    ImageErrorWidgetBuilder? errorBuilder,
    ImageLoadingBuilder? loadingBuilder,
    ImageFrameBuilder? frameBuilder,
    FilterQuality filterQuality = FilterQuality.medium,
    bool gaplessPlayback = false,
  }) => Image.network(
    ServerEgress.imageUrl(url),
    key: key,
    width: width,
    height: height,
    fit: fit,
    cacheWidth: cacheWidth,
    cacheHeight: cacheHeight,
    color: color,
    colorBlendMode: colorBlendMode,
    alignment: alignment,
    errorBuilder: errorBuilder,
    loadingBuilder: loadingBuilder,
    frameBuilder: frameBuilder,
    filterQuality: filterQuality,
    gaplessPlayback: gaplessPlayback,
  );
}
