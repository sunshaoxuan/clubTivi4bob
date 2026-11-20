import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Keep light and dark transparent broadcaster marks legible without tinting
/// or stretching the original artwork.
class ChannelLogoSurface extends StatefulWidget {
  const ChannelLogoSurface({
    super.key,
    required this.image,
    required this.fallback,
  });
  final ImageProvider<Object>? image;
  final Widget fallback;

  @override
  State<ChannelLogoSurface> createState() => _ChannelLogoSurfaceState();
}

class _ChannelLogoSurfaceState extends State<ChannelLogoSurface> {
  static const _light = Color(0xFFF4F6FA);
  static const _dark = Color(0xFF29374D);
  static final _backgrounds = <ImageProvider<Object>, Color>{};
  ImageStream? _stream;
  ImageStreamListener? _listener;
  Color _background = _dark;
  int _generation = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(ChannelLogoSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image != widget.image) _resolve();
  }

  void _resolve() {
    if (_listener != null) _stream?.removeListener(_listener!);
    final provider = widget.image;
    final generation = ++_generation;
    _background = provider == null ? _light : _backgrounds[provider] ?? _dark;
    if (provider == null || _backgrounds.containsKey(provider)) return;
    _stream = provider.resolve(createLocalImageConfiguration(context));
    _listener = ImageStreamListener(
      (info, _) {
        unawaited(_inspect(info, provider, generation));
      },
      onError: (Object _, StackTrace? _) {
        if (mounted && generation == _generation) {
          setState(() => _background = _light);
        }
      },
    );
    _stream!.addListener(_listener!);
  }

  Future<void> _inspect(
    ImageInfo info,
    ImageProvider<Object> provider,
    int generation,
  ) async {
    try {
      final bytes = await info.image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      if (bytes == null) return;
      final pixels = bytes.buffer.asUint8List();
      var weight = 0.0;
      var luminance = 0.0;
      // Sample at most roughly 2048 pixels and ignore transparent margins.
      final step = ((pixels.length ~/ 4) ~/ 2048).clamp(1, 100000);
      for (var i = 0; i + 3 < pixels.length; i += step * 4) {
        final alpha = pixels[i + 3] / 255;
        if (alpha < .5) continue;
        luminance +=
            (.2126 * pixels[i] +
                .7152 * pixels[i + 1] +
                .0722 * pixels[i + 2]) /
            255;
        weight += alpha;
      }
      final color = weight > 0 && luminance / weight > .55 ? _dark : _light;
      if (_backgrounds.length >= 256) {
        _backgrounds.remove(_backgrounds.keys.first);
      }
      _backgrounds[provider] = color;
      if (mounted && generation == _generation) {
        setState(() => _background = color);
        if (_listener != null) {
          _stream?.removeListener(_listener!);
          _listener = null;
        }
      }
    } finally {
      info.dispose();
    }
  }

  @override
  void dispose() {
    ++_generation;
    if (_listener != null) _stream?.removeListener(_listener!);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Container(
    width: 68,
    height: 32,
    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
    decoration: BoxDecoration(
      color: _background,
      borderRadius: BorderRadius.circular(9),
    ),
    child: ExcludeSemantics(
      child: widget.image == null
          ? widget.fallback
          : Image(
              image: widget.image!,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => widget.fallback,
            ),
    ),
  );
}
