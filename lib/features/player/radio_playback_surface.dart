import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import '../../core/server_image.dart';
import 'radio_audio_spectrum.dart';

/// Render-only radio artwork. Does not open media or change channel metadata.
class RadioPlaybackSurface extends StatelessWidget {
  const RadioPlaybackSurface({
    super.key,
    required this.channelName,
    this.logoUrl,
    this.playing = const Stream<bool>.empty(),
    this.buffering = const Stream<bool>.empty(),
    this.spectrum,
    this.initialPlaying = false,
    this.initialBuffering = false,
  });

  factory RadioPlaybackSurface.forPlayer({
    Key? key,
    required Player player,
    required String channelName,
    String? logoUrl,
  }) => RadioPlaybackSurface(
    key: key,
    channelName: channelName,
    logoUrl: logoUrl,
    spectrum: RadioAudioSpectrum.forPlayer(player),
    playing: player.stream.playing,
    buffering: player.stream.buffering,
    initialPlaying: player.state.playing,
    initialBuffering: player.state.buffering,
  );

  final String channelName;
  final String? logoUrl;
  final Stream<bool> playing;
  final Stream<bool> buffering;
  final RadioAudioSpectrum? spectrum;
  final bool initialPlaying;
  final bool initialBuffering;

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF142537), Color(0xFF050C13)],
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final height = constraints.maxHeight;
          if (height < 72 || width < 48) {
            return const Center(
              child: Icon(
                Icons.radio_rounded,
                color: Color(0xFF91D9E9),
                size: 24,
              ),
            );
          }
          final showName = height >= 220;
          final waveHeight = (height * 0.18).clamp(16.0, 70.0);
          final logoSize = math.min(
            math.min(width * 0.48, 180.0),
            math.max(24.0, height - waveHeight - (showName ? 96 : 48)),
          );
          final placeholder = Icon(
            Icons.radio_rounded,
            key: const ValueKey('radio-artwork-fallback'),
            size: logoSize * 0.54,
            color: const Color(0xFF91D9E9),
          );
          final url = logoUrl?.trim();
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Semantics(
                      label: '$channelName 台标',
                      image: true,
                      child: Container(
                        key: const ValueKey('radio-station-artwork'),
                        width: logoSize,
                        height: logoSize,
                        padding: EdgeInsets.all(logoSize * 0.1),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(logoSize * 0.18),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.1),
                          ),
                        ),
                        child: url == null || url.isEmpty
                            ? placeholder
                            : ServerImage.network(
                                url,
                                key: ValueKey(url),
                                fit: BoxFit.contain,
                                cacheWidth: 384,
                                cacheHeight: 384,
                                errorBuilder: (_, _, _) => placeholder,
                              ),
                      ),
                    ),
                  ),
                  if (showName) ...[
                    const SizedBox(height: 14),
                    Text(
                      channelName,
                      key: const ValueKey('radio-station-name'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Color(0xFFE4F1F5),
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  SizedBox(
                    width: math.min(width * 0.78, 1400),
                    height: waveHeight,
                    child: StreamBuilder<bool>(
                      stream: playing,
                      initialData: initialPlaying,
                      builder: (context, playback) => StreamBuilder<bool>(
                        stream: buffering,
                        initialData: initialBuffering,
                        builder: (context, loading) => RadioWaveform(
                          spectrum: spectrum,
                          playing:
                              playback.data == true && loading.data != true,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    ),
  );
}

/// Only measured band levels repaint this canvas. No synthetic paint clock.
class RadioWaveform extends StatefulWidget {
  const RadioWaveform({
    super.key,
    required this.playing,
    this.spectrum,
    this.signalOnly = false,
  });
  final bool playing;
  final RadioAudioSpectrum? spectrum;
  final bool signalOnly;

  static int bandCountForWidth(double width) => width < 180
      ? 16
      : width < 480
      ? 32
      : width < 900
      ? 64
      : 128;

  @override
  State<RadioWaveform> createState() => _RadioWaveformState();
}

class _RadioWaveformState extends State<RadioWaveform>
    with WidgetsBindingObserver {
  RadioAudioSpectrum? _attached;
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(RadioWaveform oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    setState(_sync);
  }

  bool get _enabled =>
      widget.playing &&
      _foreground &&
      TickerMode.valuesOf(context).enabled &&
      !MediaQuery.disableAnimationsOf(context);

  void _sync() {
    final next = _enabled ? widget.spectrum : null;
    if (identical(next, _attached)) return;
    _attached?.release();
    _attached = next;
    _attached?.acquire();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _attached?.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: '实时音频频谱',
    child: RepaintBoundary(
      key: const ValueKey('radio-waveform'),
      child: Stack(
        fit: StackFit.expand,
        children: [
          CustomPaint(
            painter: _RadioWavePainter(
              widget.spectrum,
              enabled: _enabled,
              signalOnly: widget.signalOnly,
            ),
          ),
          if (widget.spectrum != null)
            ValueListenableBuilder<bool?>(
              valueListenable: widget.spectrum!.supported,
              builder: (context, supported, _) => supported == false && _enabled
                  ? const Center(
                      child: Text(
                        '频谱暂不可用',
                        style: TextStyle(
                          color: Color(0xFF91D9E9),
                          fontSize: 12,
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
        ],
      ),
    ),
  );
}

class _RadioWavePainter extends CustomPainter {
  _RadioWavePainter(
    this.spectrum, {
    required this.enabled,
    required this.signalOnly,
  }) : super(repaint: spectrum);
  final RadioAudioSpectrum? spectrum;
  final bool enabled;
  final bool signalOnly;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final count = RadioWaveform.bandCountForWidth(size.width);
    final step = size.width / count;
    final barWidth = math.min(3.0, step * 0.45);
    final paint = Paint()..color = const Color(0xFF80D7E9);
    for (var index = 0; index < count; index++) {
      var level = 0.0;
      if (enabled && spectrum?.available == true) {
        final values = signalOnly ? spectrum!.signalLevels : spectrum!.levels;
        final start = index * values.length ~/ count;
        final end = (index + 1) * values.length ~/ count;
        for (var bin = start; bin < end; bin++) {
          level = math.max(level, values[bin]);
        }
      }
      final height = math.min(size.height, 3 + level * (size.height - 3));
      final rect = Rect.fromCenter(
        center: Offset(step * (index + 0.5), size.height - height / 2),
        width: barWidth,
        height: height,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(3)),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_RadioWavePainter oldDelegate) =>
      oldDelegate.spectrum != spectrum ||
      oldDelegate.enabled != enabled ||
      oldDelegate.signalOnly != signalOnly;
}
