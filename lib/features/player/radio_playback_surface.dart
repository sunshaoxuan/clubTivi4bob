import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import '../../core/server_image.dart';

/// Render-only radio artwork. Does not open media or change channel metadata.
class RadioPlaybackSurface extends StatelessWidget {
  const RadioPlaybackSurface({
    super.key,
    required this.channelName,
    this.logoUrl,
    this.playing = const Stream<bool>.empty(),
    this.buffering = const Stream<bool>.empty(),
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
    playing: player.stream.playing,
    buffering: player.stream.buffering,
    initialPlaying: player.state.playing,
    initialBuffering: player.state.buffering,
  );

  final String channelName;
  final String? logoUrl;
  final Stream<bool> playing;
  final Stream<bool> buffering;
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
                    width: math.min(width * 0.74, 400),
                    height: waveHeight,
                    child: StreamBuilder<bool>(
                      stream: playing,
                      initialData: initialPlaying,
                      builder: (context, playback) => StreamBuilder<bool>(
                        stream: buffering,
                        initialData: initialBuffering,
                        builder: (context, loading) => RadioWaveform(
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

/// Playback-state animation, deliberately not labelled as a real audio spectrum.
/// Only this small canvas repaints, at most 20 times per second.
class RadioWaveform extends StatefulWidget {
  const RadioWaveform({super.key, required this.playing});
  final bool playing;

  @override
  State<RadioWaveform> createState() => _RadioWaveformState();
}

class _RadioWaveformState extends State<RadioWaveform>
    with WidgetsBindingObserver {
  final _clock = RadioWaveClock();
  bool _visible = true;
  bool _foreground = true;
  bool _reduceMotion = false;

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
    _visible = TickerMode.valuesOf(context).enabled;
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
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
    _sync();
  }

  void _sync() => _clock.setRunning(
    widget.playing && _visible && _foreground && !_reduceMotion,
  );

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: '播放状态音波动画，非实时频谱',
    child: RepaintBoundary(
      key: const ValueKey('radio-waveform'),
      child: CustomPaint(painter: _RadioWavePainter(_clock)),
    ),
  );
}

/// Small paint clock with no widget-tree rebuilds or player/native calls.
class RadioWaveClock extends ChangeNotifier {
  Timer? _timer;
  double phase = 0;
  bool get running => _timer != null;

  void setRunning(bool value) {
    if (value == running) return;
    _timer?.cancel();
    _timer = null;
    if (value) {
      _timer = Timer.periodic(const Duration(milliseconds: 50), (_) {
        phase = (phase + 0.12) % (math.pi * 2);
        notifyListeners();
      });
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }
}

class _RadioWavePainter extends CustomPainter {
  _RadioWavePainter(this.clock) : super(repaint: clock);
  final RadioWaveClock clock;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    const count = 32;
    final step = size.width / count;
    final barWidth = math.min(5.0, step * 0.45);
    final paint = Paint()..color = const Color(0xFF80D7E9);
    for (var index = 0; index < count; index++) {
      final edge = math.sin(math.pi * (index + 0.5) / count);
      final pulse = clock.running
          ? (math.sin(index * 0.68 + clock.phase) * 0.5 + 0.5) *
                (math.sin(index * 0.21 - clock.phase * 2) * 0.25 + 0.75)
          : 0.0;
      final height = math.min(
        size.height,
        3 + pulse * edge * (size.height - 3),
      );
      final rect = Rect.fromCenter(
        center: Offset(step * (index + 0.5), size.height / 2),
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
      oldDelegate.clock != clock;
}
