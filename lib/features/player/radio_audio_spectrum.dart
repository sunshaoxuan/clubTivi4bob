import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

/// Log-spaced band levels measured on the active decoder's PCM.
/// The FFT reads the decoded samples; output is the original audio frame. Nothing opens a second stream or synthesizes animation frames.
class RadioSpectrumAnalysis {
  static const label = 'bobtv_radio_spectrum';
  static const bandCount = 128;
  static final frequencies = List<double>.unmodifiable(
    List.generate(bandCount, (i) => 40 * math.pow(400, i / (bandCount - 1))),
  );

  // One FFT reads PCM without modifying its samples. Analysis is capped to 25 Hz.
  static String get filter => '@$label:lavfi=[bobtv_spectrum]:o=[threads=1]';

  static double? _decibels(String value) =>
      value == '-inf' ? double.negativeInfinity : double.tryParse(value);

  /// mpv returns the FFT band energies as a JSON map. Scale -72..0 dBFS to 0..1.
  static List<double>? parse(String metadata, {double volume = 100}) {
    try {
      final values = jsonDecode(metadata);
      if (values is! Map || '${values['lavfi.bobtv_spectrum.ready']}' != '1') {
        return null;
      }
      final result = <double>[];
      for (var i = 0; i < bandCount; i++) {
        final db = _decibels('${values['lavfi.bobtv_spectrum.$i']}');
        if (db == null || db.isNaN) return null;
        final gain = volume > 0
            ? 20 * math.log(volume / 100) / math.ln10
            : double.negativeInfinity;
        result.add(((db + gain + 72) / 72).clamp(0.0, 1.0));
      }
      return result;
    } catch (_) {
      return null;
    }
  }
}

/// Signal levels remain measurable while a card preview is intentionally muted.
class RadioSpectrumMeasurement {
  RadioSpectrumMeasurement({
    required List<double> signalLevels,
    double volume = 100,
    bool muted = false,
  }) : signalLevels = List.unmodifiable(signalLevels),
       outputLevels = List.unmodifiable(
         signalLevels.map((level) {
           if (muted || volume <= 0) return 0.0;
           final gain = 20 * math.log(volume / 100) / math.ln10 / 72;
           return (level + gain).clamp(0.0, 1.0);
         }),
       );

  final List<double> signalLevels;
  final List<double> outputLevels;
}

abstract class RadioSpectrumReader {
  Future<bool> attach();
  Future<RadioSpectrumMeasurement?> read();
  Future<void> detach();
}

class _PlayerSpectrumReader implements RadioSpectrumReader {
  _PlayerSpectrumReader(this.player);
  final Player player;
  NativePlayer? get backend =>
      player.platform is NativePlayer ? player.platform as NativePlayer : null;

  @override
  Future<bool> attach() async {
    final target = backend;
    if (target == null) return false;
    await target.waitForPlayerInitialization;
    await target.command([
      'af',
      'add',
      RadioSpectrumAnalysis.filter,
    ], waitForInitialization: false);
    // Some backends silently reject commands. Never claim data is available
    // just because the command completed.
    final filters = await target.getProperty(
      'af',
      waitForInitialization: false,
    );
    return filters.contains(RadioSpectrumAnalysis.label);
  }

  @override
  Future<RadioSpectrumMeasurement?> read() async {
    final target = backend;
    if (target == null || !player.state.playing || player.state.buffering) {
      return null;
    }
    final signal = RadioSpectrumAnalysis.parse(
      await target.getProperty(
        'af-metadata/${RadioSpectrumAnalysis.label}',
        waitForInitialization: false,
      ),
    );
    if (signal == null) return null;
    return RadioSpectrumMeasurement(
      signalLevels: signal,
      volume: player.state.volume,
      muted:
          await target.getProperty('mute', waitForInitialization: false) ==
          'yes',
    );
  }

  @override
  Future<void> detach() async {
    final target = backend;
    if (target != null) {
      await target.command([
        'af',
        'remove',
        '@${RadioSpectrumAnalysis.label}',
      ], waitForInitialization: false);
    }
  }
}

/// One sampler per player shared by the preview and full player. Polling never
/// overlaps, and native mutations are serialized across UI handoffs/disposal.
class RadioAudioSpectrum extends ChangeNotifier {
  RadioAudioSpectrum(this.reader);
  static final _players = Expando<RadioAudioSpectrum>();
  static RadioAudioSpectrum forPlayer(Player player) =>
      _players[player] ??= RadioAudioSpectrum(_PlayerSpectrumReader(player));

  final RadioSpectrumReader reader;
  List<double> levels = List.filled(RadioSpectrumAnalysis.bandCount, 0);
  List<double> signalLevels = List.filled(RadioSpectrumAnalysis.bandCount, 0);
  bool available = false;
  final supported = ValueNotifier<bool?>(null);
  int _missingFrames = 0;
  int _users = 0;
  Timer? _timer;
  Future<void> _pending = Future.value();
  bool _attached = false;

  void acquire() {
    if (++_users != 1) return;
    _missingFrames = 0;
    _pending = _pending.then((_) async {
      if (_users == 0) return;
      try {
        if (!_attached) _attached = await reader.attach();
      } catch (_) {
        _attached = false;
      }
      if (_users > 0 && _attached) _schedule();
      if (!_attached) {
        supported.value = false;
        _publish(null);
      }
    });
  }

  void release() {
    assert(_users > 0);
    if (--_users != 0) return;
    _timer?.cancel();
    _timer = null;
    _pending = _pending.then((_) async {
      if (_users > 0) return;
      if (_attached) {
        try {
          await reader.detach();
        } catch (_) {
          // The player may already have been disposed during a channel switch.
        }
      }
      _attached = false;
      supported.value = null;
      _publish(null);
    });
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 50), () {
      _pending = _pending.then((_) async {
        if (_users == 0 || !_attached) return;
        try {
          final measured = await reader.read();
          if (_users > 0) {
            if (measured != null) {
              _missingFrames = 0;
              supported.value = true;
            } else if (++_missingFrames >= 40) {
              supported.value = false;
            }
            _publish(measured);
          }
        } catch (_) {
          if (_users > 0) _publish(null);
        }
        if (_users > 0 && _attached) _schedule();
      });
    });
  }

  void _publish(RadioSpectrumMeasurement? measured) {
    available = measured != null;
    levels =
        measured?.outputLevels ??
        List.filled(RadioSpectrumAnalysis.bandCount, 0);
    signalLevels =
        measured?.signalLevels ??
        List.filled(RadioSpectrumAnalysis.bandCount, 0);
    notifyListeners();
  }
}
