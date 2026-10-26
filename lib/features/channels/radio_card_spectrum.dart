import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import '../player/radio_audio_spectrum.dart';
import '../player/radio_playback_surface.dart';

/// The card visualizes the decoder's input signal even when preview output is
/// muted. Main artwork and the card share one sampler when a player is promoted.
class RadioCardSpectrum extends StatelessWidget {
  const RadioCardSpectrum({
    super.key,
    required this.spectrum,
    this.playing = const Stream.empty(),
    this.buffering = const Stream.empty(),
    this.initialPlaying = false,
    this.initialBuffering = false,
  });

  factory RadioCardSpectrum.forPlayer(Player player) => RadioCardSpectrum(
    key: ValueKey(player),
    spectrum: RadioAudioSpectrum.forPlayer(player),
    playing: player.stream.playing,
    buffering: player.stream.buffering,
    initialPlaying: player.state.playing,
    initialBuffering: player.state.buffering,
  );

  final RadioAudioSpectrum spectrum;
  final Stream<bool> playing;
  final Stream<bool> buffering;
  final bool initialPlaying;
  final bool initialBuffering;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 120, maxHeight: 28),
          child: StreamBuilder<bool>(
            stream: playing,
            initialData: initialPlaying,
            builder: (context, playback) => StreamBuilder<bool>(
              stream: buffering,
              initialData: initialBuffering,
              builder: (context, loading) => RadioWaveform(
                key: const ValueKey('radio-card-spectrum'),
                playing: playback.data == true && loading.data != true,
                spectrum: spectrum,
                signalOnly: true,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
