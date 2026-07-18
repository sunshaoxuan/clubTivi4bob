import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Tracks per-stream health metrics for ranking failover alternatives.
///
/// Metrics: stall count, average buffer level, time-to-first-frame.
/// Persisted to SharedPreferences, decayed over time so recent data
/// weighs more than old data.
class StreamHealthTracker {
  static const _prefsKey = 'stream_health_scores';
  static const _maxEntries = 300;
  static const _decayDays = 7;

  Map<String, _StreamMetrics> _metrics = {};
  bool _loaded = false;

  /// Load persisted metrics from disk.
  Future<void> load() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = prefs.getString(_prefsKey);
      if (json != null) {
        final map = jsonDecode(json) as Map<String, dynamic>;
        _metrics = map.map((k, v) => MapEntry(k, _StreamMetrics.fromJson(v)));
      }
    } catch (_) {}
    _loaded = true;
  }

  /// Record a buffering stall on a stream.
  void recordStall(String url) {
    final m = _getOrCreate(url);
    m.stallCount++;
    m.failureCount += 2;
    m.currentWindow.recordFailure(weight: 2);
    m.lastUpdated = DateTime.now();
    _scheduleSave();
  }

  /// Reward a route that returned data during the current channel probe.
  void recordProbeSuccess(String url, int firstByteMs, double bytesPerSecond) {
    final m = _getOrCreate(url);
    m.successCount++;
    m.ttffMs = _ewma(m.ttffMs.toDouble(), firstByteMs.toDouble()).round();
    m.bytesPerSecond = _ewma(m.bytesPerSecond, bytesPerSecond);
    m.currentWindow.recordSuccess(firstByteMs, bytesPerSecond);
    m.lastUpdated = DateTime.now();
    _scheduleSave();
  }

  /// Penalize a route that could not return any media data.
  void recordProbeFailure(String url) {
    final m = _getOrCreate(url);
    m.failureCount++;
    m.currentWindow.recordFailure();
    m.lastUpdated = DateTime.now();
    _scheduleSave();
  }

  /// Record a buffer level sample (seconds of cache).
  void recordBufferSample(String url, double seconds) {
    final m = _getOrCreate(url);
    m.bufferSamples++;
    m.bufferSum += seconds;
    m.lastUpdated = DateTime.now();
    // Don't save on every sample — too frequent
  }

  /// Record time-to-first-frame in milliseconds.
  void recordTTFF(String url, int ms) {
    final m = _getOrCreate(url);
    m.ttffMs = ms;
    m.lastUpdated = DateTime.now();
    _scheduleSave();
  }

  /// Get a health score for a stream URL (0.0 = terrible, 1.0 = excellent).
  /// Unknown streams return 0.5 (neutral).
  double getScore(String url) {
    final key = _urlKey(url);
    final m = _metrics[key];
    if (m == null) return 0.5;

    // Old observations fade toward neutral so a recovered route can be tried
    // again after enough time has passed.
    final age = DateTime.now().difference(m.lastUpdated).inHours;
    final decay = 1.0 / (1.0 + age / (_decayDays * 24));
    final overall = _scoreMetrics(
      successes: m.successCount,
      failures: m.failureCount,
      firstByteMs: m.ttffMs.toDouble(),
      bytesPerSecond: m.bytesPerSecond,
      bufferSeconds: m.bufferSamples > 0 ? m.bufferSum / m.bufferSamples : null,
    );

    // A six-hour time bucket learns that a route may be good in the morning
    // and congested in the evening. New bucket observations gain influence
    // gradually and never erase the all-day history immediately.
    final window = m.currentWindow;
    final windowSamples = window.successCount + window.failureCount;
    final windowConfidence = (windowSamples / 6.0).clamp(0.0, 1.0);
    final windowScore = _scoreMetrics(
      successes: window.successCount,
      failures: window.failureCount,
      firstByteMs: window.ttffMs,
      bytesPerSecond: window.bytesPerSecond,
      bufferSeconds: null,
    );
    final learned =
        overall * (1.0 - windowConfidence) + windowScore * windowConfidence;
    return (0.5 + (learned - 0.5) * decay).clamp(0.0, 1.0);
  }

  double _scoreMetrics({
    required int successes,
    required int failures,
    required double firstByteMs,
    required double bytesPerSecond,
    required double? bufferSeconds,
  }) {
    final reliability = (successes + 1.0) / (successes + failures + 2.0);
    final latency = firstByteMs > 0 ? 1.0 / (1.0 + firstByteMs / 1200.0) : 0.5;
    final throughput = bytesPerSecond > 0
        ? bytesPerSecond / (bytesPerSecond + 750000.0)
        : 0.5;
    final buffer = bufferSeconds != null
        ? (bufferSeconds / 8.0).clamp(0.0, 1.0)
        : 0.5;
    return (reliability * 0.40 +
            latency * 0.20 +
            throughput * 0.25 +
            buffer * 0.15)
        .clamp(0.0, 1.0);
  }

  double _ewma(double previous, double current) {
    if (previous <= 0) return current;
    return previous * 0.65 + current * 0.35;
  }

  /// Get scores for multiple URLs, sorted best-first.
  List<MapEntry<String, double>> rankUrls(List<String> urls) {
    final scored = urls.map((u) => MapEntry(u, getScore(u))).toList();
    scored.sort((a, b) => b.value.compareTo(a.value));
    return scored;
  }

  _StreamMetrics _getOrCreate(String url) {
    final key = _urlKey(url);
    return _metrics.putIfAbsent(key, () => _StreamMetrics(url: url));
  }

  String _urlKey(String url) => url.hashCode.toRadixString(36);

  bool _saveScheduled = false;

  void _scheduleSave() {
    if (_saveScheduled) return;
    _saveScheduled = true;
    Future.delayed(const Duration(seconds: 5), () async {
      _saveScheduled = false;
      await _save();
    });
  }

  /// Force a save (call on app shutdown).
  Future<void> save() => _save();

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Prune old entries
      if (_metrics.length > _maxEntries) {
        final entries = _metrics.entries.toList()
          ..sort((a, b) => a.value.lastUpdated.compareTo(b.value.lastUpdated));
        for (var i = 0; i < entries.length - _maxEntries; i++) {
          _metrics.remove(entries[i].key);
        }
      }
      final json = _metrics.map((k, v) => MapEntry(k, v.toJson()));
      await prefs.setString(_prefsKey, jsonEncode(json));
    } catch (_) {}
  }
}

class _StreamMetrics {
  final String url;
  int stallCount;
  double bufferSum;
  int bufferSamples;
  int ttffMs;
  int successCount;
  int failureCount;
  double bytesPerSecond;
  Map<String, _ProbeWindow> windows;
  DateTime lastUpdated;

  _StreamMetrics({
    required this.url,
    this.stallCount = 0,
    this.bufferSum = 0,
    this.bufferSamples = 0,
    this.ttffMs = 0,
    this.successCount = 0,
    this.failureCount = 0,
    this.bytesPerSecond = 0,
    Map<String, _ProbeWindow>? windows,
    DateTime? lastUpdated,
  }) : windows = windows ?? {},
       lastUpdated = lastUpdated ?? DateTime.now();

  _ProbeWindow get currentWindow {
    final key = (DateTime.now().hour ~/ 6).toString();
    return windows.putIfAbsent(key, () => _ProbeWindow());
  }

  Map<String, dynamic> toJson() => {
    'url': url,
    'stalls': stallCount,
    'bufSum': bufferSum,
    'bufN': bufferSamples,
    'ttff': ttffMs,
    'ok': successCount,
    'fail': failureCount,
    'bps': bytesPerSecond,
    'windows': windows.map((key, value) => MapEntry(key, value.toJson())),
    'ts': lastUpdated.millisecondsSinceEpoch,
  };

  factory _StreamMetrics.fromJson(Map<String, dynamic> j) => _StreamMetrics(
    url: j['url'] ?? '',
    stallCount: j['stalls'] ?? 0,
    bufferSum: (j['bufSum'] ?? 0).toDouble(),
    bufferSamples: j['bufN'] ?? 0,
    ttffMs: j['ttff'] ?? 0,
    successCount: j['ok'] ?? 0,
    failureCount: j['fail'] ?? 0,
    bytesPerSecond: (j['bps'] ?? 0).toDouble(),
    windows: ((j['windows'] as Map<String, dynamic>?) ?? {}).map(
      (key, value) => MapEntry(key, _ProbeWindow.fromJson(value)),
    ),
    lastUpdated: DateTime.fromMillisecondsSinceEpoch(j['ts'] ?? 0),
  );
}

class _ProbeWindow {
  int successCount = 0;
  int failureCount = 0;
  double ttffMs = 0;
  double bytesPerSecond = 0;

  _ProbeWindow();

  void recordSuccess(int firstByteMs, double throughput) {
    successCount++;
    ttffMs = _ewma(ttffMs, firstByteMs.toDouble());
    bytesPerSecond = _ewma(bytesPerSecond, throughput);
  }

  void recordFailure({int weight = 1}) {
    failureCount += weight;
  }

  double _ewma(double previous, double current) {
    if (previous <= 0) return current;
    return previous * 0.65 + current * 0.35;
  }

  Map<String, dynamic> toJson() => {
    'ok': successCount,
    'fail': failureCount,
    'ttff': ttffMs,
    'bps': bytesPerSecond,
  };

  factory _ProbeWindow.fromJson(Map<String, dynamic> json) => _ProbeWindow()
    ..successCount = json['ok'] ?? 0
    ..failureCount = json['fail'] ?? 0
    ..ttffMs = (json['ttff'] ?? 0).toDouble()
    ..bytesPerSecond = (json['bps'] ?? 0).toDouble();
}
