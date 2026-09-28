import 'dart:async';
import 'dart:io' show HttpClient, Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit/src/player/native/player/real.dart' as native_player;
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/app_diagnostics.dart';
import 'adaptive_buffer.dart';
import 'playback_stall_detector.dart';
import 'stream_proxy.dart';
import '../../data/services/channel_name_normalizer.dart';
import '../../data/services/stream_alternatives_service.dart';
import '../../data/services/stream_health_tracker.dart';
import '../../data/services/bobtv_community_service.dart';
import '../providers/provider_manager.dart';
import '../casting/cast_service.dart';
import '../casting/local_cast_mute.dart';

class RouteSearchProgress {
  const RouteSearchProgress({
    required this.stage,
    required this.index,
    required this.total,
    this.label = '',
    this.active = false,
    this.background = false,
  });

  final String stage;
  final int index;
  final int total;
  final String label;
  final bool active;
  final bool background;
}

class AlternativePreviewState {
  const AlternativePreviewState({
    required this.stage,
    required this.index,
    required this.total,
    this.controller,
  });

  final String stage;
  final int index;
  final int total;
  final VideoController? controller;
  bool get ready => controller != null;
}

/// Manages video playback with stream failover support.
class PlayerService {
  CastService? castService;
  LocalCastMute? _localCastMute;

  Future<void> syncLocalCastMute(bool casting) async {
    // Ordinary playback and pre-initialization status events are untouched.
    final p = _player;
    if (p == null || !_playerReady) return;
    final np = p.platform;
    if (np is! native_player.NativePlayer) return;
    _localCastMute ??= LocalCastMute(
      readMute: () async => await np.getProperty('mute') == 'yes',
      writeMute: (muted) => np.setProperty('mute', muted ? 'yes' : 'no'),
    );
    try {
      await _localCastMute!.update(casting);
    } catch (error) {
      AppDiagnostics.instance.log('cast_local_mute_error', {
        'errorType': error.runtimeType.toString(),
      });
    }
  }
  static const minimumUltraHdVideoBitrate = 8000000.0;

  Player? _player;
  VideoController? _videoController;
  final ValueNotifier<VideoController?> activeVideoController = ValueNotifier(null);
  final ValueNotifier<VideoController?> previewVideoController = ValueNotifier(null);
  final ValueNotifier<RouteSearchProgress?> channelPreviewProgress =
      ValueNotifier(null);
  final ValueNotifier<RouteSearchProgress?> routeSearchProgress =
      ValueNotifier(null);
  final ValueNotifier<AlternativePreviewState?> alternativePreviewState =
      ValueNotifier(null);
  _PreparedChannel? _preparedChannel;
  Timer? _preparedChannelTimeout;
  String? get preparedChannelId => _preparedChannel?.channelId;
  String? get preparedChannelUrl => _preparedChannel?.url;
  final _activePlayerController = StreamController<Player>.broadcast();
  Stream<Player> get activePlayerStream => _activePlayerController.stream;
  final ValueNotifier<bool> channelSwitching = ValueNotifier(false);
  int _channelSwitchGeneration = 0;
  bool _preparingChannelSwitch = false;
  final AdaptiveBufferManager _bufferManager = AdaptiveBufferManager();
  bool _isBuffering = false;
  DateTime? _bufferStartTime;
  StreamSubscription<Tracks>? _tracksSub;
  StreamSubscription<String>? _playbackErrorLogSub;
  StreamSubscription<bool>? _playingLogSub;
  StreamSubscription<PlayerLog>? _macAudioLogSub;
  DateTime? _bufferLogStart;

  // Buffer health tracking (persists across info dialog opens)
  final List<bool> bufferHistory = List.filled(60, false, growable: true);
  int bufferEventCount = 0;
  int bufferingSeconds = 0;
  bool _trackingBuffering = false;
  Timer? _bufferTrackTimer;
  StreamSubscription<bool>? _bufferTrackSub;

  /// Buffer stall threshold before triggering failover.
  static const bufferStallThreshold = Duration(seconds: 3);

  // Auto-failover state
  String? _currentUrl;
  String? _currentChannelId;
  String? _currentEpgChannelId;
  String? _currentTvgId;
  String? _currentChannelName;
  String? _currentVanityName;
  String? _currentOriginalName;
  StreamAlternativesService? _alternatives;
  StreamHealthTracker? _healthTracker;
  Timer? _failoverCheckTimer;
  final PlaybackStallDetector _stallDetector = PlaybackStallDetector();
  final RepeatedShortBufferDetector _shortBufferDetector =
      RepeatedShortBufferDetector();
  DateTime? _briefFreezeStartedAt;
  bool _failoverMonitorBusy = false;
  final StreamProxy _streamProxy = StreamProxy();
  bool _proxyActive = false;

  // ── Warm failover: background pre-buffer player ──
  Player? _warmPlayer;
  String? _warmUrl;
  bool _warmReady = false;
  StreamSubscription<bool>? _warmBufferSub;
  Timer? _warmTimeoutTimer;
  Future<void>? _warmSetupFuture;
  int _warmGeneration = 0;
  bool _autoFailoverInProgress = false;
  DateTime? _failoverRetryNotBefore;
  Player? _alternativePreviewPlayer;
  String? _alternativePreviewUrl;
  Timer? _alternativePreviewMonitor;
  int _alternativePreviewGeneration = 0;
  final Set<String> _alternativeTriedUrls = {};
  DateTime? _alternativeRetryNotBefore;
  int _playGeneration = 0;
  int _rewardedPlaybackGeneration = -1;
  final Set<String> _rewardedPlaybackUrls = {};
  final Set<String> _failedFailoverUrls = {};
  final Set<String> _manuallyRejectedUrls = {};
  bool _requiresUltraHd = false;
  bool _allowsAudioOnly = false;
  bool _compatibilityDecoding = false;
  bool get compatibilityDecoding => _compatibilityDecoding;
  Timer? _qualityCheckTimer;
  Timer? _videoCheckTimer;
  Timer? _staticFrameTimer;
  List<int>? _lastFrameFingerprint;
  int _staticFrameMatches = 0;
  bool _staticFrameSampleBusy = false;

  /// Broadcast current stream URL changes (for UI like failover dialog).
  final _currentUrlController = StreamController<String?>.broadcast();
  final _failoverSwitchingController = StreamController<bool>.broadcast();
  bool _failoverSwitching = false;
  Stream<String?> get currentUrlStream => _currentUrlController.stream;
  Stream<bool> get failoverSwitchingStream =>
      _failoverSwitchingController.stream;
  bool get failoverSwitching => _failoverSwitching;
  String? get currentUrl => _currentUrl;
  List<String> get currentAlternativeUrls => _getFailoverAlternatives();
  List<String> get retirementAlternativeUrls =>
      _getFailoverAlternatives(includePreviouslyFailed: true);
  int get currentCandidateCount => _currentUrl == null ? 0 :
      1 + _getFailoverAlternatives(includePreviouslyFailed: true).length;

  static String routeLabel(String url) {
    final uri = Uri.tryParse(url.split('|').first.trim());
    if (uri == null || uri.host.isEmpty) return '未知来源';
    final segments = uri.pathSegments.where((part) => part.isNotEmpty).toList();
    final tail = segments.isEmpty ? '' : segments.last;
    final concise = tail.length > 24 ? '${tail.substring(0, 24)}…' : tail;
    return concise.isEmpty ? uri.host : '${uri.host} / $concise';
  }
  String? get castUrl =>
      _proxyActive ? (_streamProxy.localUrl ?? _currentUrl) : _currentUrl;
  String? get currentChannelId => _currentChannelId;

  Future<bool> switchCurrentRoute(String url, {
    bool onlyRequestedRoute = false,
  }) async {
    final current = _currentUrl;
    if (current == null || url.isEmpty) return false;
    if (current == url) return true;
    final switched = await switchChannel(
      url,
      channelId: _currentChannelId,
      epgChannelId: _currentEpgChannelId,
      tvgId: _currentTvgId,
      channelName: _currentChannelName,
      vanityName: _currentVanityName,
      originalName: _currentOriginalName,
      failoverGroupUrls: _getFailoverAlternatives()
          .where((candidate) => candidate != url)
          .toList(),
      allowAudioOnly: _allowsAudioOnly,
      preferRequestedRoute: true,
      onlyRequestedRoute: onlyRequestedRoute,
    );
    if (switched && _currentUrl != null && _currentUrl != current) {
      // A manual skip is a quality verdict. Keep automatic failover from
      // immediately returning to the skipped route.
      _healthTracker?.recordStall(current);
      _failedFailoverUrls.add(current);
      _manuallyRejectedUrls.add(current);
      AppDiagnostics.instance.log('manual_route_skipped', {
        'channel': _currentChannelName,
        'skippedStream': AppDiagnostics.summarizeStreamUrl(current),
        'activeStream': AppDiagnostics.summarizeStreamUrl(_currentUrl!),
      });
    }
    return switched;
  }

  /// Starts a replacement after the rejected route has been stopped.
  Future<bool> playRetirementReplacement(
    String url,
    List<String> remainingAlternatives,
  ) async {
    final candidates = _rankCandidateUrls([url, ...remainingAlternatives])
        .where((candidate) => candidate.isNotEmpty &&
            !_manuallyRejectedUrls.contains(candidate))
        .toList();
    if (candidates.isEmpty) {
      routeSearchProgress.value = const RouteSearchProgress(
          stage: '当前频道没有其他候选线路', index: 0, total: 0);
      if (_currentChannelName != null) {
        onSourcesExhausted?.call(_currentChannelName!);
      }
      return false;
    }
    final generation = _playGeneration;
    _failoverGroupUrls = candidates;
    _setFailoverSwitching(true);
    try {
      for (var index = 0; index < candidates.length; index++) {
        if (generation != _playGeneration) return false;
        final candidate = candidates[index];
        routeSearchProgress.value = RouteSearchProgress(
          stage: '淘汰后寻找新线路', index: index + 1,
          total: candidates.length, label: routeLabel(candidate), active: true,
        );
        if (await _switchWithVerification(candidate, generation)) {
          _currentUrlController.add(candidate);
          startBufferTracking();
          _startFailoverMonitor();
          _startStaticFrameMonitor(candidate, generation);
          AppDiagnostics.instance.updatePlaybackContext(
              channelName: _currentChannelName, streamUrl: candidate);
          routeSearchProgress.value = null;
          return true;
        }
      }
      if (generation == _playGeneration) {
        await stop();
        routeSearchProgress.value = RouteSearchProgress(
          stage: '候选线路均未播放成功',
          index: candidates.length, total: candidates.length,
        );
        if (_currentChannelName != null) {
          onSourcesExhausted?.call(_currentChannelName!);
        }
      }
      return false;
    } finally {
      _setFailoverSwitching(false);
    }
  }

  void rejectCurrentRoute() {
    final url = _currentUrl;
    if (url == null) return;
    _healthTracker?.recordStall(url);
    _failedFailoverUrls.add(url);
    _manuallyRejectedUrls.add(url);
  }

  void _setFailoverSwitching(bool value) {
    if (_failoverSwitching == value) return;
    _failoverSwitching = value;
    if (!_failoverSwitchingController.isClosed) {
      _failoverSwitchingController.add(value);
    }
  }

  /// Callback invoked when auto-failover switches streams.
  /// Provides the provider name or URL fragment for UI toast.
  void Function(String message)? onFailover;
  void Function(String channelName)? onSourcesExhausted;
  void Function(String? channelId, String url, bool playable)?
      onReviewedPlaybackVerdict;

  /// Called after four matching frame samples show a route has displayed the
  /// same picture for roughly one minute.
  Future<int> Function(String channelId, String streamUrl)?
  onStaticStreamDetected;

  /// The channel ID that failover most recently switched to, if available.
  String? lastFailoverChannelId;

  bool _playerReady = false;
  final _playerReadyCompleter = Completer<void>();

  Player get player {
    if (_player == null) {
      _player = Player(
        configuration: const PlayerConfiguration(
          bufferSize: 96 * 1024 * 1024,
          logLevel: MPVLogLevel.warn,
        ),
      );
      _initPlayer(_player!);
      _bindPlayerLogs(_player!);
      AppDiagnostics.instance.log('player_created', {
        'bufferSizeBytes': 96 * 1024 * 1024,
      });
    }
    return _player!;
  }

  void _bindPlayerLogs(Player active) {
    unawaited(_playbackErrorLogSub?.cancel());
    unawaited(_playingLogSub?.cancel());
    unawaited(_macAudioLogSub?.cancel());
    _playbackErrorLogSub = active.stream.error.listen((message) {
        AppDiagnostics.instance.log('player_error', {
          'message': message,
          'channel': _currentChannelName,
          'stream': _currentUrl == null
              ? null
              : AppDiagnostics.summarizeStreamUrl(_currentUrl!),
        });
      });
      _playingLogSub = active.stream.playing.distinct().listen((playing) {
        AppDiagnostics.instance.log('playing_changed', {
          'playing': playing,
          'channel': _currentChannelName,
        });
      });
    if (Platform.isMacOS) {
      _macAudioLogSub = active.stream.log.listen((entry) {
        final message = entry.text.toLowerCase();
        if (!message.contains('underrun') &&
            !message.contains('underflow') &&
            !message.contains('audio device') &&
            !message.contains('aac') &&
            !message.contains('audio decoder')) return;
        AppDiagnostics.instance.log('mac_audio_warning', {
          'prefix': entry.prefix,
          'level': entry.level,
          'message': entry.text.trim(),
          'channel': _currentChannelName,
        });
      });
    }
  }

  Future<void> _initPlayer(Player p) async {
    final np = p.platform;
    if (np is native_player.NativePlayer) {
      if (Platform.isMacOS) {
        // Keep the device's channel layout, test integer CoreAudio output,
        // and retain the buffer that reduced audible interruptions.
        await np.setProperty('audio-buffer', '0.8');
        await np.setProperty('audio-samplerate', '48000');
        await np.setProperty('audio-format', 's16');
        await np.setProperty('audio-normalize-downmix', 'no');
        await np.setProperty('af', '');
      } else {
        await np.setProperty('audio-channels', 'stereo');
        await np.setProperty('audio-normalize-downmix', 'yes');
        await np.setProperty('af', 'loudnorm=I=-14:TP=-1:LRA=13');
      }
      // Disable SPDIF passthrough which can cause silent output
      await np.setProperty('audio-spdif', '');
      // Volume
      await np.setProperty('volume', '100');
      await np.setProperty('mute', 'no');
      // Android TV: enable hardware decoding and optimize buffering
      if (Platform.isAndroid) {
        await np.setProperty('hwdec', 'mediacodec-copy');
        await np.setProperty('vo', 'gpu');
        await np.setProperty('framedrop', 'vo');
      }
    }
    await p.setVolume(100);
    _playerReady = true;
    _playerReadyCompleter.complete();
    AppDiagnostics.instance.log('player_ready', {
      'audioProfile': Platform.isMacOS
          ? 'macos_48khz_s16_buffer_0_8'
          : 'normalized',
    });
  }

  /// Wait for player properties to be applied before playback.
  Future<void> _ensureReady() async {
    if (!_playerReady) {
      // Access player to trigger creation if needed
      player; // ignore: unnecessary_statements
      await _playerReadyCompleter.future;
    }
  }

  VideoController get videoController {
    _videoController ??= _createVideoController(player);
    if (activeVideoController.value == null) {
      activeVideoController.value = _videoController;
    }
    return _videoController!;
  }

  VideoController _createVideoController(Player target) => VideoController(
        target,
        configuration: VideoControllerConfiguration(
          hwdec: Platform.isMacOS && _compatibilityDecoding ? 'no' : null,
        ),
      );

  /// Switches the current Mac decoder for a controlled comparison on the
  /// same stream. New preview and main players inherit this session setting.
  Future<bool> setCompatibilityDecoding(bool enabled) async {
    if (!Platform.isMacOS) return false;
    final active = _player;
    final native = active?.platform;
    if (native is! native_player.NativePlayer) return false;
    try {
      await native.setProperty('hwdec', enabled ? 'no' : 'auto');
    } catch (error) {
      AppDiagnostics.instance.log('video_decoder_mode_failed', {
        'error': error.toString(),
      });
      return false;
    }
    _compatibilityDecoding = enabled;
    for (final other in <Player?>[
      _preparedChannel?.player,
      _alternativePreviewPlayer,
    ]) {
      final otherNative = other?.platform;
      if (otherNative is native_player.NativePlayer) {
        try {
          await otherNative.setProperty('hwdec', enabled ? 'no' : 'auto');
        } catch (_) {}
      }
    }
    final url = _currentUrl;
    AppDiagnostics.instance.log('video_decoder_mode_changed', {
      'mode': enabled ? 'software' : 'auto',
      'channel': _currentChannelName,
      'stream': url == null ? null : AppDiagnostics.summarizeStreamUrl(url),
    });
    if (url != null && active != null) {
      Timer(const Duration(seconds: 5), () {
        if (identical(_player, active) && _currentUrl == url) {
          unawaited(_logVideoMetrics(active, url,
              _currentChannelName, 'main_after_decoder_change'));
        }
      });
    }
    return true;
  }

  /// Inject services for auto-failover (call once at startup).
  void configureFailover(
    StreamAlternativesService alternatives,
    StreamHealthTracker health,
  ) {
    _alternatives = alternatives;
    _healthTracker = health;
  }

  void _recordPlaybackReadyOnce(String url, int generation, {
    bool alreadyCredited = false,
  }) {
    if (generation != _playGeneration || _currentUrl != url) return;
    if (_rewardedPlaybackGeneration != generation) {
      _rewardedPlaybackGeneration = generation;
      _rewardedPlaybackUrls.clear();
    }
    if (_rewardedPlaybackUrls.add(url)) {
      if (!alreadyCredited) _healthTracker?.recordPlaybackSuccess(url);
      onReviewedPlaybackVerdict?.call(_currentChannelId, url, true);
      if (Platform.isMacOS) {
        unawaited(_logMacAudioOutput(url, generation));
      }
      final currentPlayer = player;
      unawaited(_logVideoMetrics(currentPlayer, url,
          _currentChannelName, 'main'));
      Timer(const Duration(seconds: 10), () {
        if (generation == _playGeneration &&
            _currentUrl == url && identical(_player, currentPlayer)) {
          unawaited(_logVideoMetrics(currentPlayer, url,
              _currentChannelName, 'main_after_10s'));
        }
      });
      if (routeSearchProgress.value?.active == true) {
        routeSearchProgress.value = null;
      }
    }
  }

  Future<void> _logMacAudioOutput(String url, int generation) async {
    final results = await Future.wait([
      getMpvProperty('current-ao'),
      getMpvProperty('audio-codec-name'),
      getMpvProperty('audio-params'),
      getMpvProperty('audio-out-params'),
    ]);
    if (generation != _playGeneration || _currentUrl != url) return;
    AppDiagnostics.instance.log('mac_audio_output', {
      'channel': _currentChannelName,
      'stream': AppDiagnostics.summarizeStreamUrl(url),
      'output': results[0],
      'codec': results[1],
      'inputParams': results[2],
      'outputParams': results[3],
    });
  }

  /// Capture decoder and presentation data for a specific player. This also
  /// covers card previews, which do not use the active player accessor.
  Future<void> _logVideoMetrics(
      Player target, String url, String? channel, String role) async {
    final native = target.platform;
    if (native is! native_player.NativePlayer) return;
    const properties = <String>[
      'video-codec-name',
      'hwdec-current',
      'video-params/pixelformat',
      'video-frame-info/interlaced',
      'video-frame-info/tff',
      'container-fps',
      'estimated-vf-fps',
      'decoder-frame-drop-count',
      'frame-drop-count',
      'vo-delayed-frame-count',
    ];
    final values = <String, String?>{};
    for (final property in properties) {
      try {
        values[property] = await native.getProperty(property);
      } catch (_) {
        values[property] = null;
      }
    }
    AppDiagnostics.instance.log('video_decoder_metrics', {
      'role': role,
      'channel': channel,
      'stream': AppDiagnostics.summarizeStreamUrl(url),
      'width': target.state.width,
      'height': target.state.height,
      'buffering': target.state.buffering,
      'properties': values,
    });
  }

  /// Replaces screen-supplied alternatives after a source visibility filter
  /// changes and drops any route that was already warming in the background.
  Future<void> updateFailoverAlternatives(List<String>? urls) async {
    _failoverGroupUrls = urls;
    await _disposeWarmPlayer();
  }

  // Failover group override: manual alternatives from user-created groups
  List<String>? _failoverGroupUrls;

  /// Keep the active programme running while a silent decoder prepares the
  /// requested channel. Only one candidate is decoded at a time.
  Future<bool> switchChannel(
    String url, {
    String? channelId,
    String? epgChannelId,
    String? tvgId,
    String? channelName,
    String? vanityName,
    String? originalName,
    List<String>? failoverGroupUrls,
    bool allowAudioOnly = false,
    bool previewOnly = false,
    bool preferRequestedRoute = false,
    bool onlyRequestedRoute = false,
  }) async {
    final request = ++_channelSwitchGeneration;
    await discardAlternativePreview();
    await discardPreparedChannel(invalidateRequest: false);
    if (request != _channelSwitchGeneration) return false;
    if (_currentUrl == null ||
        !(player.state.playing || player.state.buffering)) {
      await play(url,
          channelId: channelId,
          epgChannelId: epgChannelId,
          tvgId: tvgId,
          channelName: channelName,
          vanityName: vanityName,
          originalName: originalName,
          failoverGroupUrls: failoverGroupUrls,
          allowAudioOnly: allowAudioOnly);
      return _currentUrl != null;
    }
    if (_currentChannelId == channelId && _currentUrl == url) return true;

    _preparingChannelSwitch = true;
    channelSwitching.value = true;
    final candidateUrls = <String>[
      url,
      if (!onlyRequestedRoute) ...?failoverGroupUrls,
    ];
    if (!onlyRequestedRoute && _alternatives != null) {
      candidateUrls.addAll(_alternatives!.getAlternatives(
        channelId: channelId ?? '',
        epgChannelId: epgChannelId,
        tvgId: tvgId,
        channelName: channelName,
        vanityName: vanityName,
        originalName: originalName,
        excludeUrl: url,
      ));
    }
    final candidates = _rankCandidateUrls(
      candidateUrls.where((route) => route.isNotEmpty &&
          (!preferRequestedRoute || route != _currentUrl)),
      preferredUrl: preferRequestedRoute ? url : null,
    ).toList();
    AppDiagnostics.instance.log('channel_preload_started', {
      'channel': channelName,
      'candidateCount': candidates.length,
    });
    await _disposeWarmPlayer();

    try {
      for (var candidateIndex = 0;
          candidateIndex < candidates.length;
          candidateIndex++) {
        if (request != _channelSwitchGeneration) return false;
        final candidateUrl = candidates[candidateIndex];
        AppDiagnostics.instance.log('channel_preload_candidate_started', {
          'channel': channelName,
          'index': candidateIndex + 1,
          'stream': AppDiagnostics.summarizeStreamUrl(candidateUrl),
        });
        if (previewOnly) {
          channelPreviewProgress.value = RouteSearchProgress(
            stage: '正在检查线路',
            index: candidateIndex + 1,
            total: candidates.length,
            active: true,
          );
        } else {
          routeSearchProgress.value = RouteSearchProgress(
            stage: '正在切换频道',
            index: candidateIndex + 1,
            total: candidates.length,
            label: routeLabel(candidateUrl),
            active: true,
          );
        }
        final candidate = Player(
          configuration: const PlayerConfiguration(
            bufferSize: 48 * 1024 * 1024,
            logLevel: MPVLogLevel.warn,
          ),
        );
        var promoted = false;
        try {
          final native = candidate.platform;
          if (native is native_player.NativePlayer) {
            await native.setProperty('mute', 'yes');
            if (Platform.isMacOS) {
              await native.setProperty('audio-buffer', '0.8');
              await native.setProperty('audio-samplerate', '48000');
              await native.setProperty('audio-format', 's16');
            } else {
              await native.setProperty('audio-channels', 'stereo');
            }
          }
          await candidate.setVolume(0);
          final controller = _createVideoController(candidate);
          await candidate.open(Media(candidateUrl))
              .timeout(const Duration(seconds: 6));
          final ready = await _waitForPreparedChannel(
            candidate,
            request,
            allowAudioOnly: allowAudioOnly,
            requireUltraHd: ChannelNameNormalizer.isUltraHd(
                    channelName ?? '') ||
                ChannelNameNormalizer.isUltraHd(originalName ?? '') ||
                ChannelNameNormalizer.isUltraHd(tvgId ?? ''),
          );
          if (ready && request == _channelSwitchGeneration) {
            if (previewOnly) {
              _healthTracker?.recordPlaybackSuccess(candidateUrl);
              // Ownership passes to the service while the preview is visible.
              promoted = true;
              _preparedChannel = _PreparedChannel(
                player: candidate,
                controller: controller,
                url: candidateUrl,
                channelId: channelId,
                epgChannelId: epgChannelId,
                tvgId: tvgId,
                channelName: channelName,
                vanityName: vanityName,
                originalName: originalName,
                failoverGroupUrls: failoverGroupUrls,
                allowAudioOnly: allowAudioOnly,
              );
              previewVideoController.value = controller;
              _preparedChannelTimeout = Timer(const Duration(minutes: 2), () {
                unawaited(discardPreparedChannel());
              });
              AppDiagnostics.instance.log('channel_preview_ready', {
                'channel': channelName,
                'stream': AppDiagnostics.summarizeStreamUrl(candidateUrl),
              });
              unawaited(_logVideoMetrics(candidate, candidateUrl,
                  channelName, 'card_preview'));
              Timer(const Duration(seconds: 10), () {
                if (identical(_preparedChannel?.player, candidate)) {
                  unawaited(_logVideoMetrics(candidate, candidateUrl,
                      channelName, 'card_preview_after_10s'));
                }
              });
              return true;
            }
            await candidate.setVolume(player.state.volume)
                .timeout(const Duration(seconds: 2));
            promoted = true;
            await _promotePreparedChannel(
              candidate,
              controller,
              candidateUrl,
              channelId: channelId,
              epgChannelId: epgChannelId,
              tvgId: tvgId,
              channelName: channelName,
              vanityName: vanityName,
              originalName: originalName,
              failoverGroupUrls: failoverGroupUrls,
              allowAudioOnly: allowAudioOnly,
            );
            _recordPlaybackReadyOnce(candidateUrl, _playGeneration);
            AppDiagnostics.instance.log('channel_preload_committed', {
              'channel': channelName,
              'stream': AppDiagnostics.summarizeStreamUrl(candidateUrl),
            });
            return true;
          }
        } catch (error) {
          AppDiagnostics.instance.log('channel_preload_candidate_failed', {
            'channel': channelName,
            'error': error.toString(),
          });
        } finally {
          if (!promoted) {
            try {
              await candidate.dispose().timeout(const Duration(seconds: 2));
            } catch (_) {}
          }
        }
        _healthTracker?.recordProbeFailure(candidateUrl);
      }
      if (request == _channelSwitchGeneration) {
        AppDiagnostics.instance.log('channel_preload_failed', {
          'channel': channelName,
          'candidateCount': candidates.length,
        });
      }
      return false;
    } finally {
      if (request == _channelSwitchGeneration) {
        _preparingChannelSwitch = false;
        channelSwitching.value = false;
        channelPreviewProgress.value = null;
        if (!previewOnly) routeSearchProgress.value = null;
      }
    }
  }

  Future<void> discardPreparedChannel({bool invalidateRequest = true}) async {
    if (invalidateRequest) ++_channelSwitchGeneration;
    _preparingChannelSwitch = false;
    channelSwitching.value = false;
    if (invalidateRequest) routeSearchProgress.value = null;
    _preparedChannelTimeout?.cancel();
    _preparedChannelTimeout = null;
    final prepared = _preparedChannel;
    _preparedChannel = null;
    previewVideoController.value = null;
    channelPreviewProgress.value = null;
    if (prepared != null) {
      try {
        await prepared.player.dispose().timeout(const Duration(seconds: 2));
      } catch (error) {
        AppDiagnostics.instance.log('channel_preview_dispose_failed', {
          'error': error.toString(),
        });
      }
    }
  }

  Future<bool> commitPreparedChannel(String? channelId) async {
    final prepared = _preparedChannel;
    if (prepared == null || prepared.channelId != channelId) return false;
    final state = prepared.player.state;
    final hasVideo = state.tracks.video.any(
      (track) => track.id != 'auto' && track.id != 'no',
    );
    final hasAudio = state.tracks.audio.any(
      (track) => track.id != 'auto' && track.id != 'no',
    );
    if (!state.playing || state.buffering ||
        !(prepared.allowAudioOnly
            ? hasAudio
            : hasVideo && (state.width ?? 0) > 0 &&
                (state.height ?? 0) > 0)) {
      await discardPreparedChannel();
      return false;
    }
    _preparedChannelTimeout?.cancel();
    _preparedChannelTimeout = null;
    _preparedChannel = null;
    previewVideoController.value = null;
    ++_channelSwitchGeneration;
    _preparingChannelSwitch = true;
    try {
      await prepared.player.setVolume(player.state.volume)
          .timeout(const Duration(seconds: 2));
      await _promotePreparedChannel(
        prepared.player,
        prepared.controller,
        prepared.url,
        channelId: prepared.channelId,
        epgChannelId: prepared.epgChannelId,
        tvgId: prepared.tvgId,
        channelName: prepared.channelName,
        vanityName: prepared.vanityName,
        originalName: prepared.originalName,
        failoverGroupUrls: prepared.failoverGroupUrls,
        allowAudioOnly: prepared.allowAudioOnly,
      );
      _recordPlaybackReadyOnce(
        prepared.url, _playGeneration, alreadyCredited: true);
      AppDiagnostics.instance.log('channel_preview_committed', {
        'channel': prepared.channelName,
      });
      return true;
    } catch (error) {
      AppDiagnostics.instance.log('channel_preview_commit_failed', {
        'error': error.toString(),
      });
      if (!identical(_player, prepared.player)) {
        unawaited(prepared.player.dispose());
      }
      return false;
    } finally {
      _preparingChannelSwitch = false;
    }
  }

  Future<bool> _waitForPreparedChannel(
    Player candidate,
    int? request, {
    required bool allowAudioOnly,
    required bool requireUltraHd,
    bool Function()? stillValid,
  }) async {
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    final stopwatch = Stopwatch()..start();
    var startingPosition = candidate.state.position;
    var positionAdvanced = false;
    DateTime? readySince;
    while (DateTime.now().isBefore(deadline)) {
      if (request != null && request != _channelSwitchGeneration) return false;
      if (stillValid != null && !stillValid()) return false;
      final state = candidate.state;
      if (state.position < startingPosition) {
        startingPosition = state.position;
        positionAdvanced = false;
      } else if (state.position - startingPosition >=
          const Duration(milliseconds: 250)) {
        positionAdvanced = true;
      }
      final hasVideo = state.tracks.video.any(
        (track) => track.id != 'auto' && track.id != 'no',
      );
      final hasAudio = state.tracks.audio.any(
        (track) => track.id != 'auto' && track.id != 'no',
      );
      final width = state.width ?? 0;
      final height = state.height ?? 0;
      final ready = preparedMediaReady(
        playing: state.playing,
        buffering: state.buffering,
        hasVideoTrack: hasVideo,
        hasAudioTrack: hasAudio,
        width: width,
        height: height,
        advanced: positionAdvanced,
        allowAudioOnly: allowAudioOnly,
      );
      if (requireUltraHd && width > 0 && height > 0 &&
          width < 3000 && height < 1700) {
        AppDiagnostics.instance.log('channel_preload_rejected_resolution', {
          'width': width,
          'height': height,
        });
        return false;
      }
      if (!allowAudioOnly && positionAdvanced && hasAudio && !hasVideo &&
          stopwatch.elapsed >= const Duration(seconds: 5)) {
        AppDiagnostics.instance.log('channel_preload_audio_only', {
          'positionMs': state.position.inMilliseconds,
          'width': width,
          'height': height,
          'videoTracks': state.tracks.video.map((track) => track.id).toList(),
        });
        return false;
      }
      if (state.buffering && !hasAudio && !hasVideo &&
          state.position == Duration.zero &&
          stopwatch.elapsed >= const Duration(seconds: 10)) {
        AppDiagnostics.instance.log('channel_preload_no_signal');
        return false;
      }
      readySince = ready ? (readySince ?? DateTime.now()) : null;
      if (readySince != null &&
          DateTime.now().difference(readySince) >=
              const Duration(milliseconds: 700)) return true;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    final state = candidate.state;
    AppDiagnostics.instance.log('channel_preload_timeout_state', {
      'playing': state.playing,
      'buffering': state.buffering,
      'positionMs': state.position.inMilliseconds,
      'positionAdvanced': positionAdvanced,
      'videoTracks': state.tracks.video.map((track) => track.id).toList(),
      'audioTracks': state.tracks.audio.map((track) => track.id).toList(),
      'width': state.width,
      'height': state.height,
    });
    return false;
  }

  /// Decodes a discovered route in a separate muted player before import.
  Future<bool> verifyDiscoveredVideoRoute(
    String url, {
    bool requireUltraHd = false,
  }) async {
    final candidate = Player(
      configuration: const PlayerConfiguration(
        bufferSize: 24 * 1024 * 1024,
        logLevel: MPVLogLevel.warn,
      ),
    );
    try {
      final native = candidate.platform;
      if (native is native_player.NativePlayer) {
        await native.setProperty('mute', 'yes');
        if (Platform.isMacOS) {
          await native.setProperty('audio-buffer', '0.8');
          await native.setProperty('audio-samplerate', '48000');
          await native.setProperty('audio-format', 's16');
        }
      }
      await candidate.setVolume(0);
      _createVideoController(candidate);
      await candidate.open(Media(url)).timeout(const Duration(seconds: 6));
      return await _waitForPreparedChannel(
        candidate,
        null,
        allowAudioOnly: false,
        requireUltraHd: requireUltraHd,
      );
    } catch (error) {
      AppDiagnostics.instance.log('discovered_video_probe_failed', {
        'errorType': error.runtimeType.toString(),
      });
      return false;
    } finally {
      try {
        await candidate.dispose().timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
  }

  @visibleForTesting
  static bool preparedMediaReady({
    required bool playing,
    required bool buffering,
    required bool hasVideoTrack,
    required bool hasAudioTrack,
    required int width,
    required int height,
    required bool advanced,
    required bool allowAudioOnly,
  }) =>
      playing && !buffering && advanced &&
      (allowAudioOnly
          ? hasAudioTrack
          : hasVideoTrack && width > 0 && height > 0);

  Future<void> _promotePreparedChannel(
    Player candidate,
    VideoController controller,
    String url, {
    String? channelId,
    String? epgChannelId,
    String? tvgId,
    String? channelName,
    String? vanityName,
    String? originalName,
    List<String>? failoverGroupUrls,
    required bool allowAudioOnly,
  }) async {
    if (!identical(candidate, _alternativePreviewPlayer)) {
      await discardAlternativePreview();
    }
    final previous = player;
    final generation = ++_playGeneration;
    _qualityCheckTimer?.cancel();
    _videoCheckTimer?.cancel();
    _failoverCheckTimer?.cancel();
    _resetStaticFrameMonitor();
    await _tracksSub?.cancel();
    _tracksSub = null;
    _bufferManager.stop();
    await _bufferTrackSub?.cancel();
    _bufferTrackSub = null;
    _bufferTrackTimer?.cancel();
    _trackingBuffering = false;
    final native = candidate.platform;
    try {
      await previous.setVolume(0).timeout(const Duration(seconds: 2));
    } catch (error) {
      AppDiagnostics.instance.log('previous_player_mute_failed', {
        'error': error.toString(),
      });
    }
    _player = candidate;
    _videoController = controller;
    _currentUrl = url;
    _currentChannelId = channelId;
    _currentEpgChannelId = epgChannelId;
    _currentTvgId = tvgId;
    _currentChannelName = channelName;
    _currentVanityName = vanityName;
    _currentOriginalName = originalName;
    _failoverGroupUrls = failoverGroupUrls;
    _allowsAudioOnly = allowAudioOnly;
    _requiresUltraHd = ChannelNameNormalizer.isUltraHd(channelName ?? '') ||
        ChannelNameNormalizer.isUltraHd(originalName ?? '') ||
        ChannelNameNormalizer.isUltraHd(tvgId ?? '');
    _proxyActive = false;
    _failedFailoverUrls.clear();
    _stallDetector.reset();
    _shortBufferDetector.reset();
    _briefFreezeStartedAt = null;
    _alternativeRetryNotBefore = null;
    _isBuffering = false;
    _bufferStartTime = null;
    _failoverRetryNotBefore = null;
    _bindPlayerLogs(candidate);
    activeVideoController.value = controller;
    _activePlayerController.add(candidate);
    if (native is native_player.NativePlayer) {
      try {
        await native.setProperty('mute', 'no');
      } catch (error) {
        AppDiagnostics.instance.log('prepared_player_unmute_failed', {
          'error': error.toString(),
        });
      }
    }
    unawaited(_streamProxy.stop());
    unawaited(previous.dispose().timeout(const Duration(seconds: 3))
        .catchError((_) {}));
    unawaited(_bufferManager.applyForStream(url, this).catchError((error) {
      AppDiagnostics.instance.log('prepared_player_buffer_error', {
        'error': error.toString(),
      });
    }));
    AppDiagnostics.instance.updatePlaybackContext(
      channelName: channelName,
      streamUrl: url,
    );
    bufferHistory.fillRange(0, 60, false);
    bufferEventCount = 0;
    bufferingSeconds = 0;
    startBufferTracking();
    _startFailoverMonitor();
    _scheduleAudioCheck(url);
    _scheduleVideoCheck(url, generation);
    _startStaticFrameMonitor(url, generation);
    _scheduleQualityCheck(url, generation);
    _currentUrlController.add(url);
  }

  /// Start playing a stream URL with optional channel metadata for failover.
  Future<void> play(
    String url, {
    String? channelId,
    String? epgChannelId,
    String? tvgId,
    String? channelName,
    String? vanityName,
    String? originalName,
    List<String>? failoverGroupUrls,
    bool allowAudioOnly = false,
  }) async {
    ++_channelSwitchGeneration;
    unawaited(discardPreparedChannel());
    unawaited(discardAlternativePreview());
    routeSearchProgress.value = null;
    _preparingChannelSwitch = false;
    channelSwitching.value = false;
    final playGeneration = ++_playGeneration;
    _failoverRetryNotBefore = null;
    _setFailoverSwitching(false);
    _isBuffering = false;
    _bufferStartTime = null;
    _stallDetector.reset();
    _shortBufferDetector.reset();
    _briefFreezeStartedAt = null;
    _alternativeRetryNotBefore = null;
    _failedFailoverUrls.clear();
    _currentUrl = url;
    _currentChannelId = channelId;
    _currentEpgChannelId = epgChannelId;
    _currentTvgId = tvgId;
    _currentChannelName = channelName;
    _currentVanityName = vanityName;
    _currentOriginalName = originalName;
    _allowsAudioOnly = allowAudioOnly;
    _requiresUltraHd =
        ChannelNameNormalizer.isUltraHd(channelName ?? '') ||
        ChannelNameNormalizer.isUltraHd(originalName ?? '') ||
        ChannelNameNormalizer.isUltraHd(tvgId ?? '');
    _failoverGroupUrls = failoverGroupUrls;
    AppDiagnostics.instance.updatePlaybackContext(
      channelName: channelName,
      streamUrl: url,
    );
    AppDiagnostics.instance.log('play_requested', {
      'channel': channelName,
      'stream': AppDiagnostics.summarizeStreamUrl(url),
      'alternativeCount': failoverGroupUrls?.length ?? 0,
      'requiresUltraHd': _requiresUltraHd,
      'allowsAudioOnly': _allowsAudioOnly,
    });
    _qualityCheckTimer?.cancel();
    _videoCheckTimer?.cancel();
    _resetStaticFrameMonitor();
    final tracksSub = _tracksSub;
    _tracksSub = null;
    await _runPlayStep(
      tracksSub?.cancel() ?? Future<void>.value(),
      generation: playGeneration,
      step: 'cancel_tracks',
      timeout: const Duration(seconds: 1),
      continueOnError: true,
    );
    if (playGeneration != _playGeneration) return;
    _failoverCheckTimer?.cancel();
    await _runPlayStep(
      _disposeWarmPlayer(),
      generation: playGeneration,
      step: 'dispose_warm_player',
      timeout: const Duration(seconds: 3),
      continueOnError: true,
    );
    if (playGeneration != _playGeneration) return;
    _proxyActive = false;
    await _runPlayStep(
      _streamProxy.stop(),
      generation: playGeneration,
      step: 'stop_stream_proxy',
      timeout: const Duration(seconds: 2),
      continueOnError: true,
    );
    if (playGeneration != _playGeneration) return;
    final ready = await _runPlayStep(
      _ensureReady(),
      generation: playGeneration,
      step: 'ensure_player_ready',
      timeout: const Duration(seconds: 4),
    );
    if (!ready) return;
    await _runPlayStep(
      _enableVideoOutput(),
      generation: playGeneration,
      step: 'enable_video_output',
      timeout: const Duration(seconds: 1),
      continueOnError: true,
    );
    if (playGeneration != _playGeneration) return;

    routeSearchProgress.value = RouteSearchProgress(
      stage: '正在快速探测前 ${currentCandidateCount > 24 ? 24 : currentCandidateCount} 路',
      index: 0, total: currentCandidateCount,
      label: '随后会逐条验证画面', active: true,
    );
    final selectedUrl = await _selectFastestStream(url);
    if (playGeneration != _playGeneration) return;
    var activeUrl = selectedUrl;
    _currentUrl = activeUrl;
    routeSearchProgress.value = RouteSearchProgress(
      stage: '正在连接线路', index: 1,
      total: currentCandidateCount, label: routeLabel(activeUrl), active: true,
    );
    AppDiagnostics.instance.updatePlaybackContext(
      channelName: channelName,
      streamUrl: activeUrl,
    );
    AppDiagnostics.instance.log('stream_selected', {
      'channel': channelName,
      'stream': AppDiagnostics.summarizeStreamUrl(activeUrl),
      'changedFromRequested': selectedUrl != url,
    });
    final opened = await _runPlayStep(
      player.open(Media(activeUrl)),
      generation: playGeneration,
      step: 'open_media',
      timeout: const Duration(seconds: 5),
    );
    if (!opened) {
      _failedFailoverUrls.add(activeUrl);
      _healthTracker?.recordProbeFailure(activeUrl);
      if (_getFailoverAlternatives().isNotEmpty) {
        unawaited(_autoFailover());
      } else {
        routeSearchProgress.value = const RouteSearchProgress(
          stage: '线路无法连接，没有其他候选线路', index: 0, total: 0);
        if (_currentChannelName != null) {
          onSourcesExhausted?.call(_currentChannelName!);
        }
      }
      return;
    }
    await _runPlayStep(
      _bufferManager.applyForStream(activeUrl, this),
      generation: playGeneration,
      step: 'apply_buffer',
      timeout: const Duration(seconds: 2),
      continueOnError: true,
    );
    if (playGeneration != _playGeneration) return;
    await _runPlayStep(
      player.setVolume(100.0),
      generation: playGeneration,
      step: 'set_volume',
      timeout: const Duration(seconds: 2),
      continueOnError: true,
    );
    if (playGeneration != _playGeneration) return;

    if (selectedUrl != url) {
      final ready = await _waitForPlayable(
        selectedUrl,
        timeout: const Duration(seconds: 5),
      );
      if (playGeneration != _playGeneration) return;
      if (!ready) {
        _failedFailoverUrls.add(selectedUrl);
        _healthTracker?.recordStall(selectedUrl);
        activeUrl = url;
        _currentUrl = activeUrl;
        AppDiagnostics.instance.updatePlaybackContext(
          channelName: channelName,
          streamUrl: activeUrl,
        );
        AppDiagnostics.instance.log('selected_stream_rejected', {
          'channel': channelName,
          'rejectedStream': AppDiagnostics.summarizeStreamUrl(selectedUrl),
          'restoredStream': AppDiagnostics.summarizeStreamUrl(activeUrl),
        });
        final restored = await _runPlayStep(
          player.open(Media(activeUrl)),
          generation: playGeneration,
          step: 'restore_requested_media',
          timeout: const Duration(seconds: 5),
        );
        if (!restored) {
          _failedFailoverUrls.add(activeUrl);
          if (_getFailoverAlternatives().isNotEmpty) {
            unawaited(_autoFailover());
          }
          return;
        }
        await _runPlayStep(
          _bufferManager.applyForStream(activeUrl, this),
          generation: playGeneration,
          step: 'restore_requested_buffer',
          timeout: const Duration(seconds: 2),
          continueOnError: true,
        );
        if (playGeneration != _playGeneration) return;
        await _runPlayStep(
          player.setVolume(100.0),
          generation: playGeneration,
          step: 'restore_requested_volume',
          timeout: const Duration(seconds: 2),
          continueOnError: true,
        );
        if (playGeneration != _playGeneration) return;
      }
    }

    // Check for missing audio after a brief delay and retry through
    // ffmpeg proxy if needed (fixes EAC-3 with non-standard codec tags)
    _scheduleAudioCheck(activeUrl);
    _scheduleVideoCheck(activeUrl, playGeneration);
    routeSearchProgress.value = RouteSearchProgress(
      stage: '已连接，正在等待画面', index: 1,
      total: currentCandidateCount, label: routeLabel(activeUrl), active: true,
    );
    _startStaticFrameMonitor(activeUrl, playGeneration);

    // Reset and start buffer tracking for the new stream
    bufferHistory.fillRange(0, 60, false);
    bufferEventCount = 0;
    bufferingSeconds = 0;
    startBufferTracking();
    _startFailoverMonitor();
    _scheduleQualityCheck(activeUrl, playGeneration);
    _currentUrlController.add(activeUrl);
  }

  Future<bool> _runPlayStep(
    Future<void> operation, {
    required int generation,
    required String step,
    required Duration timeout,
    bool continueOnError = false,
  }) async {
    try {
      await operation.timeout(timeout);
    } catch (error, stackTrace) {
      AppDiagnostics.instance.log('play_step_failed', {
        'step': step,
        'timeout': error is TimeoutException,
        'channel': _currentChannelName,
        'stream': _currentUrl == null
            ? null
            : AppDiagnostics.summarizeStreamUrl(_currentUrl!),
        'error': error.toString(),
      });
      if (!continueOnError) {
        AppDiagnostics.instance.recordError('player_$step', error, stackTrace);
        if (error is! TimeoutException &&
            generation == _playGeneration && _currentUrl != null &&
            (step == 'open_media' || step == 'restore_requested_media')) {
          onReviewedPlaybackVerdict?.call(
            _currentChannelId, _currentUrl!, false,
          );
        }
      }
      return continueOnError && generation == _playGeneration;
    }
    return generation == _playGeneration;
  }

  Future<bool> _waitForPlayable(
    String expectedUrl, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final stopwatch = Stopwatch()..start();
    var sawBuffering = false;
    var observedPosition = player.state.position;
    var positionAdvanced = false;
    while (stopwatch.elapsed < timeout) {
      if (_currentUrl != expectedUrl) return false;
      final buffering = player.state.buffering;
      if (buffering) sawBuffering = true;

      final tracks = player.state.tracks;
      final hasVideo = tracks.video.any(
        (track) => track.id != 'auto' && track.id != 'no',
      );
      final hasAudio = tracks.audio.any(
        (track) => track.id != 'auto' && track.id != 'no',
      );
      final width = player.state.width ?? 0;
      final height = player.state.height ?? 0;
      final hasUsableMedia = isUsablePlaybackMedia(
        hasVideoTrack: hasVideo,
        hasAudioTrack: hasAudio,
        width: width,
        height: height,
        allowAudioOnly: _allowsAudioOnly,
      );
      final rawCache = await getMpvProperty('demuxer-cache-duration');
      final cacheSeconds = double.tryParse(rawCache ?? '') ?? 0.0;
      final currentPosition = player.state.position;
      if (currentPosition < observedPosition) {
        observedPosition = currentPosition;
      } else if (currentPosition - observedPosition >=
          const Duration(milliseconds: 250)) {
        positionAdvanced = true;
      }
      final settled = sawBuffering || stopwatch.elapsedMilliseconds >= 900;
      if (settled &&
          !buffering &&
          hasUsableMedia &&
          (cacheSeconds >= 0.15 || positionAdvanced)) {
        if (_requiresUltraHd && hasVideo && _hasKnownSubUltraHdResolution()) {
          debugPrint(
            '[Failover] Rejected a mislabeled Ultra HD route at '
            '${player.state.width}x${player.state.height}',
          );
          return false;
        }
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return false;
  }

  @visibleForTesting
  static bool isUsableTelevisionVideo({
    required bool hasVideoTrack,
    required int width,
    required int height,
  }) {
    return hasVideoTrack && width > 0 && height > 0;
  }

  @visibleForTesting
  static bool isUsablePlaybackMedia({
    required bool hasVideoTrack,
    required bool hasAudioTrack,
    required int width,
    required int height,
    required bool allowAudioOnly,
  }) {
    return isUsableTelevisionVideo(
          hasVideoTrack: hasVideoTrack,
          width: width,
          height: height,
        ) ||
        (allowAudioOnly && hasAudioTrack);
  }

  Future<void> _enableVideoOutput({bool reload = false}) async {
    final np = player.platform;
    if (np is! native_player.NativePlayer) return;
    await np.setProperty('vid', 'auto');
    if (reload) {
      try {
        await np.command(['video-reload']);
      } catch (_) {}
    }
  }

  void _scheduleVideoCheck(
    String expectedUrl,
    int playGeneration, {
    int attempt = 0,
  }) {
    _videoCheckTimer?.cancel();
    _videoCheckTimer = Timer(Duration(seconds: attempt == 0 ? 8 : 4), () async {
      if (playGeneration != _playGeneration || _currentUrl != expectedUrl) {
        return;
      }
      final tracks = player.state.tracks;
      final hasVideoTrack = tracks.video.any(
        (track) => track.id != 'auto' && track.id != 'no',
      );
      final hasAudioTrack = tracks.audio.any(
        (track) => track.id != 'auto' && track.id != 'no',
      );
      final width = player.state.width ?? 0;
      final height = player.state.height ?? 0;
      if (isUsablePlaybackMedia(
        hasVideoTrack: hasVideoTrack,
        hasAudioTrack: hasAudioTrack,
        width: width,
        height: height,
        allowAudioOnly: _allowsAudioOnly,
      )) {
        if (player.state.playing && !player.state.buffering) {
          _recordPlaybackReadyOnce(expectedUrl, playGeneration);
        }
        AppDiagnostics.instance.log(
          hasVideoTrack ? 'video_ready' : 'audio_ready',
          {'channel': _currentChannelName, 'width': width, 'height': height},
        );
        return;
      }

      if (attempt == 0 && hasVideoTrack) {
        try {
          await _enableVideoOutput(
            reload: true,
          ).timeout(const Duration(seconds: 1), onTimeout: () {});
        } catch (error) {
          AppDiagnostics.instance.log('video_reload_failed', {
            'channel': _currentChannelName,
            'error': error.toString(),
          });
        }
      }
      if (attempt < 2) {
        _scheduleVideoCheck(expectedUrl, playGeneration, attempt: attempt + 1);
        return;
      }

      AppDiagnostics.instance.log('video_missing', {
        'channel': _currentChannelName,
        'stream': AppDiagnostics.summarizeStreamUrl(expectedUrl),
        'hasVideoTrack': hasVideoTrack,
        'hasAudioTrack': hasAudioTrack,
        'width': width,
        'height': height,
      });
      _failedFailoverUrls.add(expectedUrl);
      _healthTracker?.recordProbeFailure(expectedUrl);
      onReviewedPlaybackVerdict?.call(_currentChannelId, expectedUrl, false);
      onFailover?.call(
        _allowsAudioOnly ? '当前音频线路无法播放，正在切换其他线路' : '当前线路只有声音，正在切换有画面的线路',
      );
      await _autoFailover();
    });
  }

  bool _hasKnownSubUltraHdResolution() {
    final width = player.state.width ?? 0;
    final height = player.state.height ?? 0;
    if (width <= 0 && height <= 0) return false;
    return !isAcceptableUltraHdMedia(width: width, height: height);
  }

  @visibleForTesting
  static bool isAcceptableUltraHdMedia({
    required int width,
    required int height,
    double? videoBitrate,
  }) {
    if (width > 0 || height > 0) {
      if (width < 3200 && height < 1800) return false;
    }
    if (videoBitrate != null &&
        videoBitrate > 0 &&
        videoBitrate < minimumUltraHdVideoBitrate) {
      return false;
    }
    return true;
  }

  Future<double?> _currentVideoBitrate() async {
    final values = await Future.wait([
      getMpvProperty('video-bitrate'),
      getMpvProperty('demuxer-bitrate'),
    ]);
    final bitrates = values
        .map((value) => double.tryParse(value ?? ''))
        .whereType<double>()
        .where((value) => value > 0)
        .toList();
    if (bitrates.isEmpty) return null;
    return bitrates.reduce((first, second) => first > second ? first : second);
  }

  void _scheduleQualityCheck(
    String expectedUrl,
    int playGeneration, {
    int attempt = 0,
  }) {
    _qualityCheckTimer?.cancel();
    if (!_requiresUltraHd) return;
    _qualityCheckTimer = Timer(const Duration(seconds: 3), () async {
      if (playGeneration != _playGeneration || _currentUrl != expectedUrl) {
        return;
      }
      final width = player.state.width ?? 0;
      final height = player.state.height ?? 0;
      if (width <= 0 && height <= 0) {
        if (attempt < 2) {
          _scheduleQualityCheck(
            expectedUrl,
            playGeneration,
            attempt: attempt + 1,
          );
        }
        return;
      }
      final videoBitrate = await _currentVideoBitrate();
      if (playGeneration != _playGeneration || _currentUrl != expectedUrl) {
        return;
      }
      if (isAcceptableUltraHdMedia(
        width: width,
        height: height,
        videoBitrate: videoBitrate,
      )) {
        return;
      }

      debugPrint(
        '[Failover] $expectedUrl advertised Ultra HD but decoded at '
        '${width}x$height and ${videoBitrate ?? 0} bit/s',
      );
      _failedFailoverUrls.add(expectedUrl);
      _healthTracker?.recordProbeFailure(expectedUrl);
      onFailover?.call('检测到低清或低码率4K线路，正在寻找高清晰度线路');
      await _autoFailover();
    });
  }

  /// Tests a small, bounded set of equivalent streams in parallel and returns
  /// the quickest usable route. The original URL remains the fallback.
  Future<String> _selectFastestStream(String originalUrl) async {
    final candidates = <String>[originalUrl];
    for (final url in _getFailoverAlternatives()) {
      if (_failedFailoverUrls.contains(url)) continue;
      if (!candidates.contains(url)) candidates.add(url);
      if (candidates.length >= 24) break;
    }
    if (candidates.length < 2) return originalUrl;

    final probes = candidates
        .map(
          (url) => _probeStream(url).timeout(
            const Duration(milliseconds: 2800),
            onTimeout: () => _StreamProbe.unusable(url),
          ),
        )
        .toList();
    List<_StreamProbe> results;
    try {
      results = await Future.wait(probes).timeout(
        const Duration(milliseconds: 3200),
        onTimeout: () => const <_StreamProbe>[],
      );
    } catch (_) {
      return originalUrl;
    }

    final usable = results.where((probe) => probe.usable).toList();
    if (usable.isEmpty) return originalUrl;
    usable.sort((a, b) => b.score.compareTo(a.score));
    final best = usable.first;
    _healthTracker?.recordTTFF(best.url, best.firstByteMs);
    debugPrint(
      '[Failover] Preflight selected ${best.url} '
      '(${best.firstByteMs}ms, ${best.bytesPerSecond.round()} B/s)',
    );
    return best.url;
  }

  Future<_StreamProbe> _probeStream(String url) async {
    final cleanUrl = url.split('|').first.trim();
    final uri = Uri.tryParse(cleanUrl);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      _healthTracker?.recordProbeFailure(url);
      return _StreamProbe.unusable(url);
    }

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 1);
    final stopwatch = Stopwatch()..start();
    var firstByteMs = 3200;
    var bytes = 0;
    var statusOk = false;
    final prefix = <int>[];
    try {
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(milliseconds: 1400));
      request.followRedirects = true;
      request.maxRedirects = 4;
      request.headers.set('Range', 'bytes=0-65535');
      request.headers.set('User-Agent', 'HotelTV/0.4');
      final response = await request.close().timeout(
        const Duration(milliseconds: 1600),
      );
      statusOk = response.statusCode >= 200 && response.statusCode < 300;
      final contentType = response.headers.contentType?.mimeType.toLowerCase() ?? '';
      if (contentType.contains('text/html') ||
          contentType.contains('application/json') ||
          contentType.contains('text/xml')) {
        statusOk = false;
      }
      if (!statusOk) {
        _healthTracker?.recordProbeFailure(url);
        return _StreamProbe.unusable(url);
      }

      await for (final chunk in response.timeout(
        const Duration(milliseconds: 1700),
      )) {
        if (bytes == 0) firstByteMs = stopwatch.elapsedMilliseconds;
        bytes += chunk.length;
        if (prefix.length < 64) {
          prefix.addAll(chunk.take(64 - prefix.length));
        }
        if (bytes >= 64 * 1024) break;
      }
    } catch (_) {
      if (bytes == 0) {
        _healthTracker?.recordProbeFailure(url);
        return _StreamProbe.unusable(url);
      }
    } finally {
      stopwatch.stop();
      client.close(force: true);
    }

    final elapsedMs = stopwatch.elapsedMilliseconds.clamp(1, 3200);
    final bytesPerSecond = bytes * 1000.0 / elapsedMs;
    if (!statusOk || bytes == 0 || !looksLikeMediaPrefix(prefix)) {
      _healthTracker?.recordProbeFailure(url);
      return _StreamProbe.unusable(url);
    }
    _healthTracker?.recordProbeSuccess(url, firstByteMs, bytesPerSecond);
    final health = _healthTracker?.getScore(url) ?? 0.5;
    final responseScore = 1.0 / (1.0 + firstByteMs / 1000.0);
    final throughputScore = bytesPerSecond / (bytesPerSecond + 750000.0);
    final score = throughputScore * 0.45 + responseScore * 0.25 + health * 0.30;
    return _StreamProbe(
      url: url,
      usable: statusOk && bytes > 0,
      firstByteMs: firstByteMs,
      bytesPerSecond: bytesPerSecond,
      score: score,
    );
  }

  @visibleForTesting
  static bool looksLikeMediaPrefix(List<int> bytes) {
    if (bytes.isEmpty) return false;
    final text = String.fromCharCodes(bytes.take(16));
    if (text.startsWith('#EXTM3U') || text.startsWith('FLV') ||
        text.startsWith('ID3') || text.startsWith('OggS')) return true;
    if (bytes[0] == 0x47) return true;
    if (bytes.length >= 8 &&
        String.fromCharCodes(bytes.skip(4).take(4)) == 'ftyp') return true;
    return bytes.length >= 2 && bytes[0] == 0xff &&
        (bytes[1] & 0xf0) == 0xf0;
  }

  /// Check audio tracks after playback starts; retry through ffmpeg proxy
  /// if no real audio tracks are detected.
  void _scheduleAudioCheck(String originalUrl) {
    _tracksSub?.cancel();
    // Allow live streams time to establish video before considering a proxy.
    _tracksSub =
        Stream<void>.fromFuture(
          Future<void>.delayed(const Duration(seconds: 8)),
        ).asyncMap((_) => player.state.tracks).listen((tracks) {
          _tracksSub?.cancel();
          if (_proxyActive || _currentUrl != originalUrl) return;

          final hasVideo = tracks.video.any(
            (track) => track.id != 'auto' && track.id != 'no',
          );
          if (!_allowsAudioOnly &&
              (!hasVideo || player.state.buffering || !player.state.playing)) {
            return;
          }

          final realAudio = tracks.audio
              .where((a) => a.id != 'auto' && a.id != 'no')
              .length;
          if (realAudio > 0) {
            debugPrint('[Player] Audio OK: $realAudio tracks detected');
            return;
          }

          // No real audio detected — try ffmpeg proxy
          debugPrint(
            '[Player] No audio tracks after video started, trying ffmpeg proxy for $originalUrl',
          );
          _retryWithProxy(originalUrl);
        });
  }

  /// Re-open the stream through the local ffmpeg proxy.
  Future<void> _retryWithProxy(String originalUrl) async {
    if (_proxyActive) return; // Avoid recursive retry
    final playGeneration = _playGeneration;
    final proxyUrl = await _streamProxy.start(originalUrl);
    if (proxyUrl == null) {
      debugPrint('[Player] ffmpeg proxy unavailable, keeping direct playback');
      return;
    }
    // Verify the stream URL hasn't changed while we were starting the proxy
    if (playGeneration != _playGeneration || _currentUrl != originalUrl) {
      await _streamProxy.stop();
      return;
    }
    _proxyActive = true;
    debugPrint('[Player] Switching to proxied stream: $proxyUrl');
    await _enableVideoOutput();
    if (playGeneration != _playGeneration || _currentUrl != originalUrl) {
      await _streamProxy.stop();
      return;
    }
    await player.open(Media(proxyUrl));
    if (playGeneration != _playGeneration || _currentUrl != originalUrl) {
      if (_currentUrl == originalUrl) await player.stop();
      await _streamProxy.stop();
      return;
    }
    _currentUrlController.add(originalUrl);
    await _bufferManager.applyForStream(originalUrl, this);
    await player.setVolume(100.0);
  }

  /// Whether audio tracks are available on the current stream.
  Stream<bool> get hasAudioStream =>
      player.stream.tracks.map((t) => t.audio.length > 1);

  /// Number of audio tracks.
  Stream<int> get audioTrackCountStream =>
      player.stream.tracks.map((t) => t.audio.length);

  /// Stop playback.
  Future<void> stop() async {
    ++_channelSwitchGeneration;
    ++_playGeneration;
    _currentUrl = null;
    routeSearchProgress.value = null;
    if (!_currentUrlController.isClosed) _currentUrlController.add(null);
    _preparingChannelSwitch = false;
    channelSwitching.value = false;
    _setFailoverSwitching(false);
    _failoverRetryNotBefore = null;
    _stallDetector.reset();
    _shortBufferDetector.reset();
    _briefFreezeStartedAt = null;
    _alternativeRetryNotBefore = null;
    _bufferManager.stop();
    _qualityCheckTimer?.cancel();
    _videoCheckTimer?.cancel();
    _failoverCheckTimer?.cancel();
    _resetStaticFrameMonitor();
    await _tracksSub?.cancel();
    _tracksSub = null;
    await player.stop();
    await discardPreparedChannel();
    await discardAlternativePreview();
    await _disposeWarmPlayer();
    await _streamProxy.stop();
    _proxyActive = false;
    AppDiagnostics.instance.log('playback_stopped', {
      'channel': _currentChannelName,
    });
    AppDiagnostics.instance.updatePlaybackContext();
  }

  /// Pause playback.
  Future<void> pause() async {
    if (castService?.isCasting == true) unawaited(castService!.pause());
    await player.pause();
  }

  /// Resume playback.
  Future<void> resume() async {
    if (castService?.isCasting == true) unawaited(castService!.resume());
    await player.play();
  }

  /// Set volume (0.0 - 100.0).
  Future<void> setVolume(double volume) async {
    if (castService?.isCasting == true)
      unawaited(castService!.setVolume(volume.round()));
    await player.setVolume(volume.clamp(0.0, 100.0));
  }

  /// Stream of buffering state changes.
  Stream<bool> get bufferingStream => player.stream.buffering;

  /// Stream of playback position.
  Stream<Duration> get positionStream => player.stream.position;

  /// Stream of duration.
  Stream<Duration> get durationStream => player.stream.duration;

  /// Stream of whether playback is playing.
  Stream<bool> get playingStream => player.stream.playing;

  /// Check if buffer stall exceeds threshold (for failover trigger).
  bool get shouldFailover {
    if (!_isBuffering || _bufferStartTime == null) return false;
    return DateTime.now().difference(_bufferStartTime!) > bufferStallThreshold;
  }

  /// Called when buffering state changes — used by failover engine.
  void onBufferingChanged(bool buffering) {
    if (buffering && !_isBuffering) {
      _isBuffering = true;
      _bufferStartTime = DateTime.now();
      _bufferLogStart = _bufferStartTime;
      AppDiagnostics.instance.log('buffering_started', {
        'channel': _currentChannelName,
        'stream': _currentUrl == null
            ? null
            : AppDiagnostics.summarizeStreamUrl(_currentUrl!),
      });
    } else if (!buffering) {
      if (_isBuffering) {
        final recoveredAt = DateTime.now();
        final duration = _bufferStartTime == null
            ? Duration.zero : recoveredAt.difference(_bufferStartTime!);
        AppDiagnostics.instance.log('buffering_ended', {
          'channel': _currentChannelName,
          'durationMs': _bufferLogStart == null
              ? null
              : DateTime.now().difference(_bufferLogStart!).inMilliseconds,
        });
        if (_shortBufferDetector.addRecoveredBuffer(
                recoveredAt, duration)) {
          _startAlternativePreviewIfNeeded();
        }
      }
      _isBuffering = false;
      _bufferStartTime = null;
      _bufferLogStart = null;
    }
  }

  /// Read an mpv property from the underlying native player.
  /// Returns null if unavailable (e.g. on web or before player init).
  Future<String?> getMpvProperty(String name) async {
    final np = player.platform;
    if (np is native_player.NativePlayer) {
      try {
        return await np.getProperty(name);
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  /// Take a screenshot via mpv's screenshot-to-file command.
  Future<String?> takeScreenshot(String path) async {
    final np = player.platform;
    if (np is native_player.NativePlayer) {
      try {
        await np.setProperty('screenshot-format', 'png');
        await np.command(['screenshot-to-file', path, 'video']);
        return path;
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  void _resetStaticFrameMonitor() {
    _staticFrameTimer?.cancel();
    _staticFrameTimer = null;
    _lastFrameFingerprint = null;
    _staticFrameMatches = 0;
    _staticFrameSampleBusy = false;
  }

  void _startStaticFrameMonitor(String expectedUrl, int playGeneration) {
    _resetStaticFrameMonitor();
    _staticFrameTimer = Timer.periodic(const Duration(seconds: 15), (_) async {
      if (_staticFrameSampleBusy) return;
      if (playGeneration != _playGeneration || _currentUrl != expectedUrl) {
        _resetStaticFrameMonitor();
        return;
      }
      if (!player.state.playing || player.state.buffering) return;
      final width = player.state.width ?? 0;
      final height = player.state.height ?? 0;
      if (width <= 0 || height <= 0) return;
      _staticFrameSampleBusy = true;
      try {
        final pixels = await player.screenshot(format: null);
        if (pixels == null || pixels.isEmpty) return;
        final fingerprint = frameFingerprint(pixels, width, height);
        if (fingerprint.isEmpty) return;
        final previous = _lastFrameFingerprint;
        _lastFrameFingerprint = fingerprint;
        if (previous != null &&
            framesAreNearlyIdentical(previous, fingerprint)) {
          _staticFrameMatches++;
        } else {
          _staticFrameMatches = 0;
        }
        if (_staticFrameMatches < 3) return;

        _staticFrameTimer?.cancel();
        _staticFrameTimer = null;
        for (var i = 0; i < 4; i++) {
          _healthTracker?.recordStall(expectedUrl);
        }
        AppDiagnostics.instance.log('static_stream_detected', {
          'channel': _currentChannelName,
          'stream': AppDiagnostics.summarizeStreamUrl(expectedUrl),
          'sampleSeconds': 60,
        });
        final channelId = _currentChannelId;
        if (channelId != null && onStaticStreamDetected != null) {
          final deleted = await onStaticStreamDetected!(channelId, expectedUrl);
          AppDiagnostics.instance.log('static_stream_removed', {
            'channel': _currentChannelName,
            'deletedRoutes': deleted,
          });
        }
        onFailover?.call('检测到长期静止画面，已移除该线路');
        await _autoFailover();
      } catch (error, stackTrace) {
        AppDiagnostics.instance.recordError(
          'static_frame_monitor',
          error,
          stackTrace,
        );
      } finally {
        _staticFrameSampleBusy = false;
      }
    });
  }

  @visibleForTesting
  static List<int> frameFingerprint(Uint8List bgra, int width, int height) {
    if (width <= 0 || height <= 0 || bgra.length < height * 4) return const [];
    final stride = bgra.length ~/ height;
    if (stride < width * 4) return const [];
    const columns = 16;
    const rows = 10;
    final result = <int>[];
    for (var row = 0; row < rows; row++) {
      final y = ((row + 0.5) * height / rows).floor().clamp(0, height - 1);
      for (var column = 0; column < columns; column++) {
        final x = ((column + 0.5) * width / columns).floor().clamp(
          0,
          width - 1,
        );
        final offset = y * stride + x * 4;
        final blue = bgra[offset];
        final green = bgra[offset + 1];
        final red = bgra[offset + 2];
        result.add((red * 30 + green * 59 + blue * 11) ~/ 100);
      }
    }
    return result;
  }

  @visibleForTesting
  static bool framesAreNearlyIdentical(List<int> first, List<int> second) {
    if (first.isEmpty || first.length != second.length) return false;
    var totalDifference = 0;
    var changedCells = 0;
    for (var index = 0; index < first.length; index++) {
      final difference = (first[index] - second[index]).abs();
      totalDifference += difference;
      if (difference > 6) changedCells++;
    }
    final meanDifference = totalDifference / first.length;
    return meanDifference <= 2.5 && changedCells <= first.length * 0.08;
  }

  /// Current adaptive buffer manager for UI access.
  AdaptiveBufferManager get bufferManager => _bufferManager;

  /// Start tracking buffer events and accumulating buffering time.
  void startBufferTracking() {
    if (_trackingBuffering) return;
    _trackingBuffering = true;

    _bufferTrackSub?.cancel();
    _bufferTrackSub = player.stream.buffering.listen((isBuffering) {
      bufferHistory.removeAt(0);
      bufferHistory.add(isBuffering);
      if (isBuffering && !_isBuffering) bufferEventCount++;
      onBufferingChanged(isBuffering);
    });

    _bufferTrackTimer?.cancel();
    _bufferTrackTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (player.state.buffering) bufferingSeconds++;
    });
  }

  void _startAlternativePreviewIfNeeded() {
    if (!(Platform.isWindows || Platform.isMacOS) ||
        _currentUrl == null || _allowsAudioOnly ||
        _preparingChannelSwitch ||
        _autoFailoverInProgress || alternativePreviewState.value != null) {
      return;
    }
    final retryAt = _alternativeRetryNotBefore;
    if (retryAt != null && DateTime.now().isBefore(retryAt)) return;
    final candidates = _getFailoverAlternatives()
        .where((url) => !_alternativeTriedUrls.contains(url)).toList();
    if (candidates.isEmpty) {
      _alternativeTriedUrls.clear();
      _alternativeRetryNotBefore = DateTime.now().add(
          const Duration(minutes: 2));
      return;
    }
    final generation = ++_alternativePreviewGeneration;
    final playGeneration = _playGeneration;
    final mainUrl = _currentUrl!;
    alternativePreviewState.value = AlternativePreviewState(
      stage: '正在寻找备用线路', index: 0, total: candidates.length,
    );
    unawaited(_searchAlternativePreview(
      candidates, generation, playGeneration, mainUrl,
    ));
  }

  Future<void> _searchAlternativePreview(List<String> candidates,
      int generation, int playGeneration, String mainUrl) async {
    bool valid() => generation == _alternativePreviewGeneration &&
        playGeneration == _playGeneration && _currentUrl == mainUrl;
    await _disposeWarmPlayer();
    if (!valid()) return;
    for (var index = 0; index < candidates.length; index++) {
      if (!valid()) return;
      final url = candidates[index];
      _alternativeTriedUrls.add(url);
      alternativePreviewState.value = AlternativePreviewState(
        stage: '正在尝试备用线路', index: index + 1,
        total: candidates.length,
      );
      final candidate = Player(configuration: const PlayerConfiguration(
        bufferSize: 32 * 1024 * 1024,
        logLevel: MPVLogLevel.warn,
      ));
      _alternativePreviewPlayer = candidate;
      var keepPlayer = false;
      try {
        final native = candidate.platform;
        if (native is native_player.NativePlayer) {
          await native.setProperty('mute', 'yes');
          if (Platform.isMacOS) {
            await native.setProperty('audio-buffer', '0.8');
            await native.setProperty('audio-samplerate', '48000');
            await native.setProperty('audio-format', 's16');
          }
        }
        await candidate.setVolume(0);
        final controller = _createVideoController(candidate);
        await candidate.open(Media(url)).timeout(const Duration(seconds: 6));
        final ready = await _waitForPreparedChannel(
          candidate, null,
          allowAudioOnly: false,
          requireUltraHd: _requiresUltraHd,
          stillValid: valid,
        );
        if (ready && valid() &&
            await _waitForStableAlternative(candidate, valid)) {
          if (!valid()) return;
          _alternativePreviewUrl = url;
          _healthTracker?.recordPlaybackSuccess(url);
          alternativePreviewState.value = AlternativePreviewState(
            stage: '备用线路已稳定', index: index + 1,
            total: candidates.length, controller: controller,
          );
          keepPlayer = true;
          _monitorAlternativePreview(candidate, generation, playGeneration,
              mainUrl);
          AppDiagnostics.instance.log('alternative_preview_ready', {
            'channel': _currentChannelName,
            'stream': AppDiagnostics.summarizeStreamUrl(url),
            'attempt': index + 1,
          });
          return;
        }
      } catch (error) {
        AppDiagnostics.instance.log('alternative_preview_candidate_failed', {
          'stream': AppDiagnostics.summarizeStreamUrl(url),
          'errorType': error.runtimeType.toString(),
        });
      } finally {
        if (!keepPlayer) {
          if (identical(_alternativePreviewPlayer, candidate)) {
            _alternativePreviewPlayer = null;
          }
          try {
            await candidate.dispose().timeout(const Duration(seconds: 2));
          } catch (_) {}
          if (valid()) _healthTracker?.recordProbeFailure(url);
        }
      }
    }
    if (!valid()) return;
    _alternativeTriedUrls.clear();
    _alternativeRetryNotBefore = DateTime.now().add(
        const Duration(minutes: 2));
    alternativePreviewState.value = AlternativePreviewState(
      stage: '暂未找到稳定备用线路',
      index: candidates.length, total: candidates.length,
    );
    Timer(const Duration(seconds: 8), () {
      if (valid() && alternativePreviewState.value?.controller == null) {
        alternativePreviewState.value = null;
      }
    });
  }

  Future<bool> _waitForStableAlternative(
      Player candidate, bool Function() valid) async {
    final deadline = DateTime.now().add(const Duration(seconds: 14));
    DateTime? stableSince;
    Duration? startingPosition;
    while (DateTime.now().isBefore(deadline)) {
      if (!valid()) return false;
      final state = candidate.state;
      if (state.playing && !state.buffering) {
        stableSince ??= DateTime.now();
        startingPosition ??= state.position;
        if (DateTime.now().difference(stableSince) >=
                const Duration(seconds: 6) &&
            state.position - startingPosition >= const Duration(seconds: 3)) {
          return true;
        }
      } else {
        stableSince = null;
        startingPosition = null;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    return false;
  }

  void _monitorAlternativePreview(Player candidate, int generation,
      int playGeneration, String mainUrl) {
    _alternativePreviewMonitor?.cancel();
    var unhealthySamples = 0;
    var previousPosition = candidate.state.position;
    _alternativePreviewMonitor = Timer.periodic(const Duration(seconds: 2),
        (_) async {
      if (generation != _alternativePreviewGeneration ||
          playGeneration != _playGeneration || _currentUrl != mainUrl) {
        _alternativePreviewMonitor?.cancel();
        return;
      }
      final state = candidate.state;
      final advancing = state.position - previousPosition >=
          const Duration(milliseconds: 300);
      previousPosition = state.position;
      unhealthySamples = state.playing && !state.buffering && advancing
          ? 0 : unhealthySamples + 1;
      if (unhealthySamples < 4) return;
      final alternativeUrl = _alternativePreviewUrl;
      if (alternativeUrl != null) {
        _healthTracker?.recordStall(alternativeUrl);
      }
      await discardAlternativePreview(resetTried: false);
      _startAlternativePreviewIfNeeded();
    });
  }

  Future<void> discardAlternativePreview({bool resetTried = true}) async {
    ++_alternativePreviewGeneration;
    _alternativePreviewMonitor?.cancel();
    _alternativePreviewMonitor = null;
    final candidate = _alternativePreviewPlayer;
    _alternativePreviewPlayer = null;
    _alternativePreviewUrl = null;
    alternativePreviewState.value = null;
    if (resetTried) _alternativeTriedUrls.clear();
    try {
      await candidate?.dispose().timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  Future<void> dismissAlternativePreview() async {
    _alternativeRetryNotBefore = DateTime.now().add(
        const Duration(minutes: 5));
    await discardAlternativePreview();
  }

  Future<bool> commitAlternativePreview() async {
    final candidate = _alternativePreviewPlayer;
    final controller = alternativePreviewState.value?.controller;
    final url = _alternativePreviewUrl;
    if (candidate == null || controller == null || url == null ||
        !candidate.state.playing || candidate.state.buffering) return false;
    final playGeneration = _playGeneration;
    final mainUrl = _currentUrl;
    ++_alternativePreviewGeneration;
    _alternativePreviewMonitor?.cancel();
    _alternativePreviewMonitor = null;
    _alternativePreviewPlayer = null;
    _alternativePreviewUrl = null;
    alternativePreviewState.value = null;
    _alternativeTriedUrls.clear();
    ++_channelSwitchGeneration;
    await discardPreparedChannel(invalidateRequest: false);
    await _disposeWarmPlayer();
    if (playGeneration != _playGeneration || _currentUrl != mainUrl) {
      unawaited(candidate.dispose());
      return false;
    }
    try {
      await candidate.setVolume(player.state.volume).timeout(
          const Duration(seconds: 2));
      await _promotePreparedChannel(
        candidate, controller, url,
        channelId: _currentChannelId,
        epgChannelId: _currentEpgChannelId,
        tvgId: _currentTvgId,
        channelName: _currentChannelName,
        vanityName: _currentVanityName,
        originalName: _currentOriginalName,
        failoverGroupUrls: _failoverGroupUrls,
        allowAudioOnly: _allowsAudioOnly,
      );
      _recordPlaybackReadyOnce(url, _playGeneration, alreadyCredited: true);
      return true;
    } catch (error) {
      AppDiagnostics.instance.log('alternative_preview_commit_failed', {
        'errorType': error.runtimeType.toString(),
      });
      if (!identical(_player, candidate)) unawaited(candidate.dispose());
      return false;
    }
  }

  // ── Auto-failover monitor ──────────────────────────────────────────────

  void _startFailoverMonitor() {
    _failoverCheckTimer?.cancel();
    _stallDetector.reset();
    _failoverMonitorBusy = false;
    _failoverCheckTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (_preparingChannelSwitch) return;
      if (_failoverMonitorBusy) return;
      final monitoredUrl = _currentUrl;
      if (monitoredUrl == null) return;
      final monitorGeneration = _playGeneration;
      final retryNotBefore = _failoverRetryNotBefore;
      if (retryNotBefore != null && DateTime.now().isBefore(retryNotBefore)) {
        return;
      }
      if (_alternatives == null &&
          (_failoverGroupUrls == null || _failoverGroupUrls!.isEmpty)) {
        return;
      }

      _failoverMonitorBusy = true;
      try {
        final raw = await getMpvProperty('demuxer-cache-duration');
        if (monitorGeneration != _playGeneration ||
            _currentUrl != monitoredUrl) return;
        final cacheSecs = double.tryParse(raw ?? '');
        if (cacheSecs != null) {
          _healthTracker?.recordBufferSample(monitoredUrl, cacheSecs);
        }

        final state = _stallDetector.add(
          PlaybackHealthSample(
            position: player.state.position,
            cacheSeconds: cacheSecs,
            buffering: player.state.buffering,
            playing: player.state.playing,
          ),
        );

        if (player.state.buffering) {
          _briefFreezeStartedAt = null;
        } else if (state.noProgressSamples >= 2) {
          _briefFreezeStartedAt ??= DateTime.now();
        } else if (state.noProgressSamples == 0 &&
            _briefFreezeStartedAt != null) {
          final recoveredAt = DateTime.now();
          final duration = recoveredAt.difference(_briefFreezeStartedAt!);
          _briefFreezeStartedAt = null;
          if (_shortBufferDetector.addRecoveredBuffer(
              recoveredAt, duration)) {
            _startAlternativePreviewIfNeeded();
          }
        }

        if (_getFailoverAlternatives().isEmpty) return;

        if (state.shouldWarmAlternative && !_warmReady && _warmPlayer == null &&
            alternativePreviewState.value == null) {
          await _startWarmPreload();
        }
        if (state.shouldFailover) {
          _healthTracker?.recordStall(monitoredUrl);
          await _autoFailover();
        } else if (state.healthy && _warmPlayer != null && !_warmReady) {
          await _disposeWarmPlayer();
        }
      } finally {
        _failoverMonitorBusy = false;
      }
    });
  }

  /// Get failover alternative URLs, preferring manual group URLs over auto-detected.
  List<String> _getFailoverAlternatives({bool includePreviouslyFailed = false}) {
    if (_currentUrl == null) return [];

    final results = <String>[];
    final seen = <String>{
      _currentUrl!,
      if (!includePreviouslyFailed) ..._failedFailoverUrls,
    };

    void addUrls(Iterable<String> urls) {
      for (final url in urls) {
        if (url.isNotEmpty &&
            !_manuallyRejectedUrls.contains(url) &&
            seen.add(url)) {
          results.add(url);
        }
      }
    }

    // Keep manually supplied and screen-discovered alternatives first.
    if (_failoverGroupUrls != null && _failoverGroupUrls!.isNotEmpty) {
      addUrls(_failoverGroupUrls!);
    }

    // Merge the complete database index instead of replacing it.
    if (_alternatives != null) {
      addUrls(
        _alternatives!.getAlternatives(
          channelId: _currentChannelId ?? '',
          epgChannelId: _currentEpgChannelId,
          tvgId: _currentTvgId,
          channelName: _currentChannelName,
          vanityName: _currentVanityName,
          originalName: _currentOriginalName,
          excludeUrl: _currentUrl!,
        ),
      );
    }
    return _rankCandidateUrls(results);
  }

  List<String> _rankCandidateUrls(
    Iterable<String> urls, {
    String? preferredUrl,
  }) => prioritizeCandidateUrls(
    urls,
    (url) => _healthTracker?.getScore(url) ?? 0.5,
    preferredUrl: preferredUrl,
  );

  @visibleForTesting
  static List<String> prioritizeCandidateUrls(
    Iterable<String> urls,
    double Function(String url) score, {
    String? preferredUrl,
  }) {
    final distinct = urls.where((url) => url.isNotEmpty).toSet().toList();
    final order = {for (var i = 0; i < distinct.length; i++) distinct[i]: i};
    distinct.sort((left, right) {
      if (left == preferredUrl) return -1;
      if (right == preferredUrl) return 1;
      final byScore = score(right).compareTo(score(left));
      return byScore != 0
          ? byScore
          : order[left]!.compareTo(order[right]!);
    });
    return distinct;
  }

  /// Start pre-buffering the best alternative stream in a hidden player.
  Future<void> _startWarmPreload() async {
    if (_currentUrl == null) return;
    if (_warmPlayer != null || _warmSetupFuture != null) return;

    final alts = _getFailoverAlternatives();
    if (alts.isEmpty) return;

    final warmUrl = alts.first;
    debugPrint('[Failover] Warm pre-buffering: $warmUrl');
    _warmUrl = warmUrl;
    _warmReady = false;

    final generation = ++_warmGeneration;
    final warmPlayer = Player(
      configuration: const PlayerConfiguration(
        bufferSize: 32 * 1024 * 1024,
        logLevel: MPVLogLevel.warn,
      ),
    );
    _warmPlayer = warmPlayer;

    // Configure warm player: muted, with loudnorm, no video output
    // Listen for buffering state — when it stops buffering, stream is ready
    await _warmBufferSub?.cancel();
    var openStarted = false;
    var sawBuffering = false;
    _warmBufferSub = warmPlayer.stream.buffering.listen((buffering) {
      if (_warmGeneration != generation || _warmPlayer != warmPlayer) return;
      if (!openStarted) return;
      if (buffering) {
        sawBuffering = true;
        return;
      }
      if (sawBuffering) {
        _warmReady = true;
        _warmTimeoutTimer?.cancel();
        debugPrint('[Failover] Warm player ready: $_warmUrl');
      }
    });

    Future<void> configureAndOpen() async {
      final np = warmPlayer.platform;
      if (np is native_player.NativePlayer) {
        await np.setProperty('vid', 'no'); // disable video decoding
        if (_warmGeneration != generation) return;
        if (Platform.isMacOS) {
          await np.setProperty('audio-buffer', '0.8');
          await np.setProperty('audio-samplerate', '48000');
          await np.setProperty('audio-format', 's16');
          if (_warmGeneration != generation) return;
          await np.setProperty('audio-normalize-downmix', 'no');
          if (_warmGeneration != generation) return;
          await np.setProperty('af', '');
        } else {
          await np.setProperty('audio-channels', 'stereo');
          if (_warmGeneration != generation) return;
          await np.setProperty('audio-normalize-downmix', 'yes');
          if (_warmGeneration != generation) return;
          await np.setProperty('af', 'loudnorm=I=-14:TP=-1:LRA=13');
        }
        if (_warmGeneration != generation) return;
        await np.setProperty('volume', '0'); // silent
      }
      if (_warmGeneration != generation || _warmPlayer != warmPlayer) return;
      openStarted = true;
      await warmPlayer.open(Media(warmUrl));
    }

    var setupFailed = false;
    final setup = configureAndOpen().timeout(const Duration(seconds: 5));
    _warmSetupFuture = setup;
    try {
      await setup;
    } catch (error) {
      setupFailed = true;
      debugPrint('[Failover] Warm player setup failed: $error');
    } finally {
      if (_warmSetupFuture == setup) _warmSetupFuture = null;
    }

    if (_warmGeneration != generation || _warmPlayer != warmPlayer) return;
    if (setupFailed) {
      await _disposeWarmPlayer();
      return;
    }

    // Timeout: if warm player doesn't become ready in 10s, dispose it
    _warmTimeoutTimer?.cancel();
    _warmTimeoutTimer = Timer(const Duration(seconds: 10), () async {
      if (!_warmReady) {
        debugPrint('[Failover] Warm pre-buffer timed out');
        await _disposeWarmPlayer();
      }
    });
  }

  /// Dispose the warm pre-buffer player and clean up.
  Future<void> _disposeWarmPlayer() async {
    ++_warmGeneration;
    final playerToDispose = _warmPlayer;
    final setupToFinish = _warmSetupFuture;
    final bufferSubToCancel = _warmBufferSub;

    _warmPlayer = null;
    _warmSetupFuture = null;
    _warmBufferSub = null;
    _warmTimeoutTimer?.cancel();
    _warmTimeoutTimer = null;
    _warmUrl = null;
    _warmReady = false;

    try {
      await bufferSubToCancel?.cancel().timeout(
        const Duration(milliseconds: 750),
      );
    } catch (_) {}
    try {
      await setupToFinish?.timeout(const Duration(seconds: 1));
    } catch (_) {}
    try {
      await playerToDispose?.dispose().timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  Future<void> _autoFailover() async {
    if (_preparingChannelSwitch) return;
    if (_autoFailoverInProgress) return;
    if (_currentUrl == null) return;
    if (_alternatives == null &&
        (_failoverGroupUrls == null || _failoverGroupUrls!.isEmpty)) {
      routeSearchProgress.value = const RouteSearchProgress(
        stage: '当前频道没有其他候选线路', index: 0, total: 0);
      if (_currentChannelName != null) {
        onSourcesExhausted?.call(_currentChannelName!);
      }
      return;
    }

    final retryNotBefore = _failoverRetryNotBefore;
    if (retryNotBefore != null && DateTime.now().isBefore(retryNotBefore)) {
      return;
    }

    _autoFailoverInProgress = true;
    try {
      await discardAlternativePreview();
      final playGeneration = _playGeneration;
      final previousUrl = _currentUrl!;
      final availableCandidates = <String>[];
      if (_warmReady && _warmPlayer != null && _warmUrl != null) {
        availableCandidates.add(_warmUrl!);
        debugPrint('[Failover] Warm candidate verified: ${_warmUrl!}');
      }
      for (final url in _getFailoverAlternatives()) {
        if (!availableCandidates.contains(url)) availableCandidates.add(url);
      }
      final candidates = _rankCandidateUrls(availableCandidates,
          preferredUrl: _warmReady ? _warmUrl : null);
      if (candidates.isEmpty) {
        _stallDetector.reset();
        _failoverRetryNotBefore = DateTime.now().add(
          const Duration(seconds: 30),
        );
        routeSearchProgress.value = const RouteSearchProgress(
          stage: '没有剩余候选线路', index: 0, total: 0);
        AppDiagnostics.instance.log('failover_exhausted', {
          'channel': _currentChannelName,
          'candidateCount': 0,
          'retryAfterSeconds': 30,
        });
        if (_currentChannelName != null) {
          onSourcesExhausted?.call(_currentChannelName!);
        }
        return;
      }

      AppDiagnostics.instance.log('failover_started', {
        'channel': _currentChannelName,
        'stream': AppDiagnostics.summarizeStreamUrl(previousUrl),
        'candidateCount': candidates.length,
      });
      _setFailoverSwitching(true);

      _failoverCheckTimer?.cancel();
      await _runPlayStep(
        _disposeWarmPlayer(),
        generation: playGeneration,
        step: 'failover_dispose_warm_player',
        timeout: const Duration(seconds: 3),
        continueOnError: true,
      );
      if (playGeneration != _playGeneration) return;
      _stallDetector.reset();
      String? switchedUrl;
      for (var index = 0; index < candidates.length; index++) {
        await Future<void>.delayed(Duration.zero);
        if (playGeneration != _playGeneration) return;
        final candidateUrl = candidates[index];
        routeSearchProgress.value = RouteSearchProgress(
          stage: '正在自动寻找线路', index: index + 1,
          total: candidates.length, label: routeLabel(candidateUrl),
          active: true,
        );
        final switched = await _switchWithVerification(
          candidateUrl,
          playGeneration,
        );
        if (playGeneration != _playGeneration) return;
        if (switched) {
          switchedUrl = candidateUrl;
          break;
        }
      }
      if (switchedUrl == null && playGeneration == _playGeneration) {
        await _restorePreviousStream(previousUrl, playGeneration);
      }
      _startFailoverMonitor();
      if (switchedUrl != null) {
        _failoverRetryNotBefore = null;
        _currentUrlController.add(switchedUrl);
        lastFailoverChannelId = _alternatives?.channelIdForUrl(switchedUrl);
        onFailover?.call('已自动切换到更稳定线路');
        AppDiagnostics.instance.updatePlaybackContext(
          channelName: _currentChannelName,
          streamUrl: switchedUrl,
        );
        AppDiagnostics.instance.log('failover_succeeded', {
          'channel': _currentChannelName,
          'stream': AppDiagnostics.summarizeStreamUrl(switchedUrl),
        });
        _startStaticFrameMonitor(switchedUrl, playGeneration);
      } else {
        _failoverRetryNotBefore = DateTime.now().add(
          const Duration(seconds: 15),
        );
        routeSearchProgress.value = RouteSearchProgress(
          stage: '候选线路均未播放成功',
          index: candidates.length, total: candidates.length);
        AppDiagnostics.instance.log('failover_exhausted', {
          'channel': _currentChannelName,
          'candidateCount': candidates.length,
          'retryAfterSeconds': 15,
        });
        if (_currentChannelName != null) {
          onSourcesExhausted?.call(_currentChannelName!);
        }
      }
    } finally {
      if (routeSearchProgress.value?.stage == '正在自动寻找线路') {
        routeSearchProgress.value = null;
      }
      _setFailoverSwitching(false);
      _autoFailoverInProgress = false;
    }
  }

  Future<bool> _switchWithVerification(
    String candidateUrl,
    int playGeneration,
  ) async {
    if (playGeneration != _playGeneration) return false;
    try {
      _currentUrl = candidateUrl;
      _proxyActive = false;
      await _runPlayStep(
        _streamProxy.stop(),
        generation: playGeneration,
        step: 'failover_stop_stream_proxy',
        timeout: const Duration(seconds: 2),
        continueOnError: true,
      );
      if (playGeneration != _playGeneration) return false;
      await _runPlayStep(
        _enableVideoOutput(),
        generation: playGeneration,
        step: 'failover_enable_video',
        timeout: const Duration(seconds: 1),
        continueOnError: true,
      );
      if (playGeneration != _playGeneration) return false;
      final opened = await _runPlayStep(
        player.open(Media(candidateUrl)),
        generation: playGeneration,
        step: 'failover_open_media',
        timeout: const Duration(seconds: 5),
      );
      if (!opened) return false;
      await _runPlayStep(
        _bufferManager.applyForStream(candidateUrl, this),
        generation: playGeneration,
        step: 'failover_apply_buffer',
        timeout: const Duration(seconds: 2),
        continueOnError: true,
      );
      if (playGeneration != _playGeneration) return false;
      await _runPlayStep(
        player.setVolume(100.0),
        generation: playGeneration,
        step: 'failover_set_volume',
        timeout: const Duration(seconds: 2),
        continueOnError: true,
      );
      if (playGeneration != _playGeneration) return false;
      final ready = await _waitForPlayable(
          candidateUrl, timeout: const Duration(seconds: 10));
      if (playGeneration != _playGeneration) return false;
      if (ready) {
        _recordPlaybackReadyOnce(candidateUrl, playGeneration);
        _scheduleAudioCheck(candidateUrl);
        _scheduleVideoCheck(candidateUrl, playGeneration);
        _scheduleQualityCheck(candidateUrl, playGeneration);
        return true;
      }
    } catch (error) {
      debugPrint('[Failover] Candidate failed: $error');
      AppDiagnostics.instance.log('failover_candidate_error', {
        'channel': _currentChannelName,
        'stream': AppDiagnostics.summarizeStreamUrl(candidateUrl),
        'error': error.toString(),
      });
    }

    if (playGeneration != _playGeneration) return false;
    _failedFailoverUrls.add(candidateUrl);
    _healthTracker?.recordStall(candidateUrl);
    return false;
  }

  Future<void> _restorePreviousStream(
    String previousUrl,
    int playGeneration,
  ) async {
    if (playGeneration != _playGeneration) return;
    debugPrint('[Failover] Restoring previous stream: $previousUrl');
    _currentUrl = previousUrl;
    await _runPlayStep(
      _enableVideoOutput(),
      generation: playGeneration,
      step: 'failover_restore_video',
      timeout: const Duration(seconds: 1),
      continueOnError: true,
    );
    if (playGeneration != _playGeneration) return;
    final restored = await _runPlayStep(
      player.open(Media(previousUrl)),
      generation: playGeneration,
      step: 'failover_restore_media',
      timeout: const Duration(seconds: 5),
    );
    if (restored) {
      await _runPlayStep(
        _bufferManager.applyForStream(previousUrl, this),
        generation: playGeneration,
        step: 'failover_restore_buffer',
        timeout: const Duration(seconds: 2),
        continueOnError: true,
      );
      if (playGeneration != _playGeneration) return;
      _scheduleAudioCheck(previousUrl);
      _scheduleVideoCheck(previousUrl, playGeneration);
    }
  }

  Future<void> dispose() async {
    ++_playGeneration;
    ++_channelSwitchGeneration;
    await discardPreparedChannel();
    await discardAlternativePreview();
    alternativePreviewState.dispose();
    channelSwitching.dispose();
    activeVideoController.dispose();
    previewVideoController.dispose();
    channelPreviewProgress.dispose();
    routeSearchProgress.dispose();
    _localCastMute?.dispose();
    AppDiagnostics.instance.log('player_disposing', {
      'channel': _currentChannelName,
    });
    _bufferManager.stop();
    _qualityCheckTimer?.cancel();
    _videoCheckTimer?.cancel();
    _resetStaticFrameMonitor();
    await _tracksSub?.cancel();
    await _playbackErrorLogSub?.cancel();
    await _playingLogSub?.cancel();
    await _macAudioLogSub?.cancel();
    await _bufferTrackSub?.cancel();
    _bufferTrackTimer?.cancel();
    _failoverCheckTimer?.cancel();
    await _disposeWarmPlayer();
    await _healthTracker?.save();
    await _streamProxy.stop();
    await _player?.dispose();
    await _currentUrlController.close();
    await _failoverSwitchingController.close();
    await _activePlayerController.close();
  }
}

class _StreamProbe {
  final String url;
  final bool usable;
  final int firstByteMs;
  final double bytesPerSecond;
  final double score;

  const _StreamProbe({
    required this.url,
    required this.usable,
    required this.firstByteMs,
    required this.bytesPerSecond,
    required this.score,
  });

  const _StreamProbe.unusable(this.url)
    : usable = false,
      firstByteMs = 3200,
      bytesPerSecond = 0,
      score = 0;
}

class _PreparedChannel {
  final Player player;
  final VideoController controller;
  final String url;
  final String? channelId;
  final String? epgChannelId;
  final String? tvgId;
  final String? channelName;
  final String? vanityName;
  final String? originalName;
  final List<String>? failoverGroupUrls;
  final bool allowAudioOnly;

  const _PreparedChannel({
    required this.player,
    required this.controller,
    required this.url,
    required this.channelId,
    required this.epgChannelId,
    required this.tvgId,
    required this.channelName,
    required this.vanityName,
    required this.originalName,
    required this.failoverGroupUrls,
    required this.allowAudioOnly,
  });
}

/// Riverpod provider for the player service (singleton).
final playerServiceProvider = Provider<PlayerService>((ref) {
  final service = PlayerService();
  final casting = ref.read(castServiceProvider);
  service.castService = casting;
  final muteSubscription = casting.statusStream.listen((_) {
    unawaited(service.syncLocalCastMute(casting.isCasting));
  });
  ref.onDispose(() => muteSubscription.cancel());
  final castSubscription = service.currentUrlStream.listen((url) {
    if (url != null && casting.isCasting) {
      unawaited(
        casting.switchChannel(
          casting.relayAirPlay ? (service.castUrl ?? url) : url,
          title: service._currentChannelName ?? 'BobTV',
        ),
      );
    }
  });
  ref.onDispose(() => castSubscription.cancel());
  // Inject failover services
  try {
    final alternatives = ref.read(streamAlternativesProvider);
    final health = ref.read(streamHealthTrackerProvider);
    service.configureFailover(alternatives, health);
    final database = ref.read(databaseProvider);
    service.onStaticStreamDetected = database.blockAndDeleteChannelRoute;
    final community = ref.read(bobTvCommunityProvider);
    service.onReviewedPlaybackVerdict = (channelId, url, playable) {
      unawaited(community.reportPlayback(
        channelId: channelId, url: url, playable: playable,
      ));
    };
  } catch (_) {
    // Services may not be available yet — failover will be disabled
  }
  ref.onDispose(() => unawaited(service.dispose()));
  return service;
});
