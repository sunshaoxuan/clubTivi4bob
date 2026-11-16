import 'dart:async';
import 'dart:io';

import 'package:media_kit/media_kit.dart';

import 'app_diagnostics.dart';
import '../features/player/native_subtitle_selection.dart';
import '../features/player/live_subtitle_session.dart';
import '../features/player/hls_buffer_proxy.dart';
// Structured mpv updates preserve the SDK's existing demuxer options.
// ignore: implementation_imports
import 'package:media_kit/src/player/native/player/real.dart' as native_player;

/// Owns every decoder, including disposals whose caller stopped waiting.
/// A UI timeout never cancels the native disposal or removes it from this set.
class PlayerResourceRegistry {
  static final instance = PlayerResourceRegistry();
  final _resources = <Object, _PlayerResource>{};
  bool _closing = false;

  bool get closing => _closing;
  int get resourceCount => _resources.length;

  void requireOpen() {
    if (_closing) throw StateError('Application player cleanup has started');
  }

  void register(Object owner, Future<void> Function() dispose, String role) {
    requireOpen();
    _resources[owner] = _PlayerResource(dispose, role);
  }

  Future<void> dispose(Object owner) {
    final resource = _resources[owner];
    if (resource == null) return Future<void>.value();
    return resource.pending ??= Future<void>.sync(() async {
      AppDiagnostics.instance.log('player_cleanup_begin', {
        'role': resource.role,
      });
      await resource.dispose();
      _resources.remove(owner);
      AppDiagnostics.instance.log('player_cleanup_completed', {
        'role': resource.role,
        'remaining': resourceCount,
      });
    });
  }

  void beginShutdown() => _closing = true;

  Future<void> disposeAll() async {
    beginShutdown();
    while (_resources.isNotEmpty) {
      await Future.wait(_resources.keys.toList().map(dispose));
    }
  }
}

class _PlayerResource {
  _PlayerResource(this.dispose, this.role);
  final Future<void> Function() dispose;
  final String role;
  Future<void>? pending;
}

/// Idempotent native ownership shared by main, warm, preview and multi-view.
class ManagedPlayer extends Player {
  factory ManagedPlayer({
    PlayerConfiguration configuration = const PlayerConfiguration(),
    PlatformPlayer? platformPlayer,
    String role = 'player',
    PlayerResourceRegistry? registry,
  }) {
    final resources = registry ?? PlayerResourceRegistry.instance;
    resources.requireOpen();
    return ManagedPlayer._(configuration, platformPlayer, resources, role);
  }

  ManagedPlayer._(
    PlayerConfiguration configuration,
    PlatformPlayer? platformPlayer,
    this._resources,
    String role,
  ) : super(configuration: configuration, platformPlayer: platformPlayer) {
    subtitles = NativeSubtitleSelection(this);
    liveSubtitles = LiveSubtitleSession(this, subtitles);
    _resources.register(this, () async {
      ++_openGeneration;
      await _hlsBuffer.stop();
      await liveSubtitles.dispose();
      await subtitles.dispose();
      await super.dispose();
    }, role);
  }

  final PlayerResourceRegistry _resources;
  late final NativeSubtitleSelection subtitles;
  late final LiveSubtitleSession liveSubtitles;
  int _openGeneration = 0;
  final _hlsBuffer = HlsBufferProxy();
  bool _liveStartOptionApplied = false;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    final generation = ++_openGeneration;
    // Explicit native acceptance runs must never emit audio, including warm
    // and preview decoders. This diagnostic flag does not change preferences.
    if (Platform.environment['BOBTV_TEST_MUTE'] == '1') {
      await super.setVolume(0);
      final native = platform;
      if (native is native_player.NativePlayer) {
        await native.setProperty('mute', 'yes');
      }
    }
    liveSubtitles.clear();
    if (playable is Media) {
      var uri = await liveSubtitles.prepare(playable.uri);
      if (generation != _openGeneration) return;
      final native = platform;
      if (native is native_player.NativePlayer) {
        if (isActionMoviesUk(playable.uri)) {
          // A string round-trip loses escaping inside protocol_whitelist.
          // Mutate only this key through mpv's structured list operation.
          await native.command([
            'change-list',
            'demuxer-lavf-o',
            'append',
            'prefer_x_start=1',
          ]);
          _liveStartOptionApplied = true;
        } else if (_liveStartOptionApplied) {
          await native.command([
            'change-list',
            'demuxer-lavf-o',
            'remove',
            'prefer_x_start',
          ]);
          _liveStartOptionApplied = false;
        }
        uri = await _hlsBuffer.start(uri, playable.httpHeaders);
      }
      if (generation != _openGeneration) return;
      await super.open(
        uri == playable.uri
            ? playable
            : Media(
                uri,
                httpHeaders: playable.httpHeaders,
                extras: playable.extras,
                start: playable.start,
                end: playable.end,
              ),
        play: play,
      );
    } else {
      await _hlsBuffer.stop();
      await super.open(playable, play: play);
    }
    if (generation == _openGeneration) liveSubtitles.activate();
  }

  @override
  Future<void> stop() async {
    ++_openGeneration;
    liveSubtitles.clear();
    await _hlsBuffer.stop();
    await super.stop();
  }

  @override
  Future<void> dispose() => _resources.dispose(this);
}
