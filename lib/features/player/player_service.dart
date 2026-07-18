import 'dart:async';
import 'dart:io' show HttpClient, Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit/src/player/native/player/real.dart' as native_player;
import 'package:media_kit_video/media_kit_video.dart';

import 'adaptive_buffer.dart';
import 'playback_stall_detector.dart';
import 'stream_proxy.dart';
import '../../data/services/channel_name_normalizer.dart';
import '../../data/services/stream_alternatives_service.dart';
import '../../data/services/stream_health_tracker.dart';

/// Manages video playback with stream failover support.
class PlayerService {
  Player? _player;
  VideoController? _videoController;
  final AdaptiveBufferManager _bufferManager = AdaptiveBufferManager();
  bool _isBuffering = false;
  DateTime? _bufferStartTime;
  StreamSubscription<Tracks>? _tracksSub;

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
  int _playGeneration = 0;
  final Set<String> _failedFailoverUrls = {};
  bool _requiresUltraHd = false;
  Timer? _qualityCheckTimer;

  /// Broadcast current stream URL changes (for UI like failover dialog).
  final _currentUrlController = StreamController<String?>.broadcast();
  Stream<String?> get currentUrlStream => _currentUrlController.stream;
  String? get currentUrl => _currentUrl;
  String? get currentChannelId => _currentChannelId;

  /// Callback invoked when auto-failover switches streams.
  /// Provides the provider name or URL fragment for UI toast.
  void Function(String message)? onFailover;

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
    }
    return _player!;
  }

  Future<void> _initPlayer(Player p) async {
    final np = p.platform;
    if (np is native_player.NativePlayer) {
      // Downmix surround to stereo for output compatibility
      await np.setProperty('audio-channels', 'stereo');
      // Normalize volume when downmixing surround to stereo
      await np.setProperty('audio-normalize-downmix', 'yes');
      // EBU R128 loudness normalization — keeps volume consistent across streams
      await np.setProperty('af', 'loudnorm=I=-14:TP=-1:LRA=13');
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
    _videoController ??= VideoController(player);
    return _videoController!;
  }

  /// Inject services for auto-failover (call once at startup).
  void configureFailover(
    StreamAlternativesService alternatives,
    StreamHealthTracker health,
  ) {
    _alternatives = alternatives;
    _healthTracker = health;
  }

  // Failover group override: manual alternatives from user-created groups
  List<String>? _failoverGroupUrls;

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
  }) async {
    final playGeneration = ++_playGeneration;
    _isBuffering = false;
    _bufferStartTime = null;
    _stallDetector.reset();
    _failedFailoverUrls.clear();
    _currentUrl = url;
    _currentChannelId = channelId;
    _currentEpgChannelId = epgChannelId;
    _currentTvgId = tvgId;
    _currentChannelName = channelName;
    _currentVanityName = vanityName;
    _currentOriginalName = originalName;
    _requiresUltraHd =
        ChannelNameNormalizer.isUltraHd(channelName ?? '') ||
        ChannelNameNormalizer.isUltraHd(originalName ?? '') ||
        ChannelNameNormalizer.isUltraHd(tvgId ?? '');
    _failoverGroupUrls = failoverGroupUrls;
    _qualityCheckTimer?.cancel();
    await _tracksSub?.cancel();
    _failoverCheckTimer?.cancel();
    await _disposeWarmPlayer();
    _proxyActive = false;
    await _streamProxy.stop();
    await _ensureReady();

    final selectedUrl = await _selectFastestStream(url);
    if (playGeneration != _playGeneration) return;
    var activeUrl = selectedUrl;
    _currentUrl = activeUrl;
    await player.open(Media(activeUrl));
    await _bufferManager.applyForStream(activeUrl, this);
    await player.setVolume(100.0);

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
        await player.open(Media(activeUrl));
        await _bufferManager.applyForStream(activeUrl, this);
        await player.setVolume(100.0);
      }
    }

    // Check for missing audio after a brief delay and retry through
    // ffmpeg proxy if needed (fixes EAC-3 with non-standard codec tags)
    _scheduleAudioCheck(activeUrl);

    // Reset and start buffer tracking for the new stream
    bufferHistory.fillRange(0, 60, false);
    bufferEventCount = 0;
    bufferingSeconds = 0;
    startBufferTracking();
    _startFailoverMonitor();
    _scheduleQualityCheck(activeUrl, playGeneration);
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
          (hasVideo || hasAudio) &&
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

  bool _hasKnownSubUltraHdResolution() {
    final width = player.state.width ?? 0;
    final height = player.state.height ?? 0;
    if (width <= 0 && height <= 0) return false;
    return width < 3200 && height < 1800;
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
      if (!_hasKnownSubUltraHdResolution()) return;

      debugPrint(
        '[Failover] $expectedUrl advertised Ultra HD but decoded at '
        '${width}x$height',
      );
      _failedFailoverUrls.add(expectedUrl);
      _healthTracker?.recordProbeFailure(expectedUrl);
      onFailover?.call('检测到伪4K线路，正在寻找真正的4K线路');
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
      statusOk = response.statusCode >= 200 && response.statusCode < 400;
      if (!statusOk) {
        _healthTracker?.recordProbeFailure(url);
        return _StreamProbe.unusable(url);
      }

      await for (final chunk in response.timeout(
        const Duration(milliseconds: 1700),
      )) {
        if (bytes == 0) firstByteMs = stopwatch.elapsedMilliseconds;
        bytes += chunk.length;
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
    if (!statusOk || bytes == 0) {
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

  /// Check audio tracks after playback starts; retry through ffmpeg proxy
  /// if no real audio tracks are detected.
  void _scheduleAudioCheck(String originalUrl) {
    _tracksSub?.cancel();
    // Give mpv 3 seconds to detect audio tracks before checking
    _tracksSub =
        Stream<void>.fromFuture(
          Future<void>.delayed(const Duration(seconds: 3)),
        ).asyncMap((_) => player.state.tracks).listen((tracks) {
          _tracksSub?.cancel();
          if (_proxyActive || _currentUrl != originalUrl) return;

          final realAudio = tracks.audio
              .where((a) => a.id != 'auto' && a.id != 'no')
              .length;
          if (realAudio > 0) {
            debugPrint('[Player] Audio OK: $realAudio tracks detected');
            return;
          }

          // No real audio detected — try ffmpeg proxy
          debugPrint(
            '[Player] No audio tracks after 3s, trying ffmpeg proxy for $originalUrl',
          );
          _retryWithProxy(originalUrl);
        });
  }

  /// Re-open the stream through the local ffmpeg proxy.
  Future<void> _retryWithProxy(String originalUrl) async {
    if (_proxyActive) return; // Avoid recursive retry
    final proxyUrl = await _streamProxy.start(originalUrl);
    if (proxyUrl == null) {
      debugPrint('[Player] ffmpeg proxy unavailable, keeping direct playback');
      return;
    }
    // Verify the stream URL hasn't changed while we were starting the proxy
    if (_currentUrl != originalUrl) {
      await _streamProxy.stop();
      return;
    }
    _proxyActive = true;
    debugPrint('[Player] Switching to proxied stream: $proxyUrl');
    await player.open(Media(proxyUrl));
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
    _bufferManager.stop();
    _qualityCheckTimer?.cancel();
    await player.stop();
  }

  /// Pause playback.
  Future<void> pause() async {
    await player.pause();
  }

  /// Resume playback.
  Future<void> resume() async {
    await player.play();
  }

  /// Set volume (0.0 - 100.0).
  Future<void> setVolume(double volume) async {
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
    } else if (!buffering) {
      _isBuffering = false;
      _bufferStartTime = null;
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
    });

    _bufferTrackTimer?.cancel();
    _bufferTrackTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (player.state.buffering) bufferingSeconds++;
    });
  }

  // ── Auto-failover monitor ──────────────────────────────────────────────

  void _startFailoverMonitor() {
    _failoverCheckTimer?.cancel();
    _stallDetector.reset();
    _failoverMonitorBusy = false;
    _failoverCheckTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (_failoverMonitorBusy) return;
      if (_currentUrl == null) return;
      if (_alternatives == null &&
          (_failoverGroupUrls == null || _failoverGroupUrls!.isEmpty)) {
        return;
      }

      _failoverMonitorBusy = true;
      try {
        final raw = await getMpvProperty('demuxer-cache-duration');
        final cacheSecs = double.tryParse(raw ?? '');
        if (cacheSecs != null) {
          _healthTracker?.recordBufferSample(_currentUrl!, cacheSecs);
        }

        final state = _stallDetector.add(
          PlaybackHealthSample(
            position: player.state.position,
            cacheSeconds: cacheSecs,
            buffering: player.state.buffering,
            playing: player.state.playing,
          ),
        );

        if (state.shouldWarmAlternative && !_warmReady && _warmPlayer == null) {
          await _startWarmPreload();
        }
        if (state.shouldFailover) {
          _healthTracker?.recordStall(_currentUrl!);
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
  List<String> _getFailoverAlternatives() {
    if (_currentUrl == null) return [];

    final results = <String>[];
    final seen = <String>{_currentUrl!, ..._failedFailoverUrls};

    void addUrls(Iterable<String> urls) {
      for (final url in urls) {
        if (url.isNotEmpty && seen.add(url)) results.add(url);
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
    return results;
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
        await np.setProperty('audio-channels', 'stereo');
        if (_warmGeneration != generation) return;
        await np.setProperty('audio-normalize-downmix', 'yes');
        if (_warmGeneration != generation) return;
        await np.setProperty('af', 'loudnorm=I=-14:TP=-1:LRA=13');
        if (_warmGeneration != generation) return;
        await np.setProperty('volume', '0'); // silent
      }
      if (_warmGeneration != generation || _warmPlayer != warmPlayer) return;
      openStarted = true;
      await warmPlayer.open(Media(warmUrl));
    }

    var setupFailed = false;
    final setup = configureAndOpen();
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

    await bufferSubToCancel?.cancel();
    try {
      await setupToFinish;
    } catch (_) {}
    await playerToDispose?.dispose();
  }

  Future<void> _autoFailover() async {
    if (_autoFailoverInProgress) return;
    if (_currentUrl == null) return;
    if (_alternatives == null &&
        (_failoverGroupUrls == null || _failoverGroupUrls!.isEmpty)) {
      return;
    }

    _autoFailoverInProgress = true;
    try {
      final playGeneration = _playGeneration;
      final previousUrl = _currentUrl!;
      final candidates = <String>[];
      if (_warmReady && _warmPlayer != null && _warmUrl != null) {
        candidates.add(_warmUrl!);
        debugPrint('[Failover] Warm candidate verified: ${_warmUrl!}');
      }
      for (final url in _getFailoverAlternatives()) {
        if (!candidates.contains(url)) candidates.add(url);
      }
      if (candidates.isEmpty) return;

      _failoverCheckTimer?.cancel();
      await _disposeWarmPlayer();
      _stallDetector.reset();
      String? switchedUrl;
      for (final candidateUrl in candidates) {
        final switched = await _switchWithVerification(
          candidateUrl,
          previousUrl,
          playGeneration,
        );
        if (playGeneration != _playGeneration) return;
        if (switched) {
          switchedUrl = candidateUrl;
          break;
        }
      }
      _startFailoverMonitor();
      if (switchedUrl != null) {
        _currentUrlController.add(switchedUrl);
        lastFailoverChannelId = _alternatives?.channelIdForUrl(switchedUrl);
        onFailover?.call('已自动切换到更稳定线路');
      }
    } finally {
      _autoFailoverInProgress = false;
    }
  }

  Future<bool> _switchWithVerification(
    String candidateUrl,
    String previousUrl,
    int playGeneration,
  ) async {
    if (playGeneration != _playGeneration) return false;
    try {
      _currentUrl = candidateUrl;
      _proxyActive = false;
      await _streamProxy.stop();
      await player.open(Media(candidateUrl));
      await _bufferManager.applyForStream(candidateUrl, this);
      await player.setVolume(100.0);
      if (playGeneration != _playGeneration) return false;
      final ready = await _waitForPlayable(candidateUrl);
      if (playGeneration != _playGeneration) return false;
      if (ready) {
        _scheduleAudioCheck(candidateUrl);
        _scheduleQualityCheck(candidateUrl, playGeneration);
        return true;
      }
    } catch (error) {
      debugPrint('[Failover] Candidate failed: $error');
    }

    if (playGeneration != _playGeneration) return false;
    _failedFailoverUrls.add(candidateUrl);
    _healthTracker?.recordStall(candidateUrl);
    debugPrint('[Failover] Restoring previous stream: $previousUrl');
    _currentUrl = previousUrl;
    try {
      await player.open(Media(previousUrl));
      await _bufferManager.applyForStream(previousUrl, this);
      await player.setVolume(100.0);
      _scheduleAudioCheck(previousUrl);
    } catch (error) {
      debugPrint('[Failover] Previous stream restore failed: $error');
    }
    return false;
  }

  Future<void> dispose() async {
    _bufferManager.stop();
    _qualityCheckTimer?.cancel();
    await _tracksSub?.cancel();
    await _bufferTrackSub?.cancel();
    _bufferTrackTimer?.cancel();
    _failoverCheckTimer?.cancel();
    await _disposeWarmPlayer();
    await _healthTracker?.save();
    await _streamProxy.stop();
    await _player?.dispose();
    await _currentUrlController.close();
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

/// Riverpod provider for the player service (singleton).
final playerServiceProvider = Provider<PlayerService>((ref) {
  final service = PlayerService();
  // Inject failover services
  try {
    final alternatives = ref.read(streamAlternativesProvider);
    final health = ref.read(streamHealthTrackerProvider);
    service.configureFailover(alternatives, health);
  } catch (_) {
    // Services may not be available yet — failover will be disabled
  }
  ref.onDispose(() => unawaited(service.dispose()));
  return service;
});
