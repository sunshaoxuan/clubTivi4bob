import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../core/app_diagnostics.dart';
import 'bobtv_api_client.dart';
import 'route_identity.dart';
import 'stream_health_tracker.dart';

/// Refreshes only requested candidates. There is no whole-catalog route scan.
/// Tokens capture the observed network before an offline outbox retry occurs.
class RegionalRouteService {
  RegionalRouteService({
    required this.tracker,
    BobTvApiClient? api,
    this.onNetworkChanged,
  }) : api = api ?? BobTvApiClient();

  final StreamHealthTracker tracker;
  final BobTvApiClient api;
  final Future<void> Function(String networkId)? onNetworkChanged;
  static const _profileKey = 'bobtv_network_profile_v1';
  final Map<String, DateTime> _checked = {};
  Future<void>? _refreshing;
  final Map<String, Future<void>> _rankings = {};
  Map<String, dynamic>? _profile;
  DateTime? _lastRefresh;
  DateTime? _retryAfter;
  bool _disposed = false;

  String get networkId => '${_profile?['networkId'] as String? ?? 'ZZ:*:*'}|direct';

  Map<String, Object?> observation(Map<String, Object?> values) => {
    'transport': 'direct',
    ...values,
    if (_validProfile(_profile)) 'networkToken': _profile!['token'],
  };

  Future<void> initialize() async {
    await tracker.load();
    tracker.setNetworkContext(networkId);
    try {
      final prefs = await SharedPreferences.getInstance();
      final value = jsonDecode(prefs.getString(_profileKey) ?? 'null');
      if (value is Map<String, dynamic> && _validProfile(value)) {
        await _applyProfile(value);
      }
    } catch (_) {}
    tracker.prepareCandidates = prepare;
    await refresh();
  }

  Future<void> refresh() {
    if (_disposed || (_retryAfter?.isAfter(DateTime.now()) ?? false)) {
      return Future.value();
    }
    if (_lastRefresh != null &&
        DateTime.now().difference(_lastRefresh!) < const Duration(minutes: 1)) {
      return Future.value();
    }
    return _refreshing ??= _refresh().whenComplete(() => _refreshing = null);
  }

  Future<void> _refresh() async {
    try {
      final profile = await api.fetchNetworkProfile().timeout(
        const Duration(seconds: 3),
      );
      if (_disposed) return;
      if (!_validProfile(profile))
        throw const FormatException('Invalid network profile');
      await _applyProfile(profile);
      _lastRefresh = DateTime.now();
      _retryAfter = null;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_profileKey, jsonEncode(profile));
    } catch (error, stack) {
      _retryAfter = DateTime.now().add(const Duration(minutes: 1));
      AppDiagnostics.instance.recordError(
        'network_profile_refresh',
        error,
        stack,
      );
    }
  }

  Future<void> _applyProfile(Map<String, dynamic> profile) async {
    if (_profile?['issuedAt'] is int &&
        profile['issuedAt'] is int &&
        (profile['issuedAt'] as int) < (_profile!['issuedAt'] as int))
      return;
    final changed = networkId != '${profile['networkId']}|direct';
    _profile = profile;
    tracker.setNetworkContext(networkId);
    await onNetworkChanged?.call(networkId);
    if (changed) {
      _checked.clear();
      AppDiagnostics.instance.log('route_network_changed', {
        'country': profile['countryCode'],
        'asn': profile['asn'],
      });
    }
  }

  Future<void> prepare(Iterable<String> candidates) async {
    if (_disposed || (_retryAfter?.isAfter(DateTime.now()) ?? false)) return;
    final now = DateTime.now();
    final urls = candidates
        .map(canonicalRouteUrl)
        .toSet()
        .where(
          (url) =>
              BobTvApiClient.isPublicCatalogUrl(url) &&
              (_checked[url] == null ||
                  now.difference(_checked[url]!) > const Duration(minutes: 5)),
        )
        .toList();
    if (urls.isEmpty) return;
    // Keep the work bounded even when a malformed channel has thousands of
    // candidates. Unmeasured candidates remain eligible and locally ranked.
    for (var offset = 0; offset < urls.length && offset < 400; offset += 200) {
      final page = urls.skip(offset).take(200).toList();
      final key = '$networkId:${page.join('\n')}';
      await (_rankings[key] ??= _rank(
        page,
      ).whenComplete(() => _rankings.remove(key)));
    }
  }

  Future<void> _rank(List<String> urls) async {
    try {
      final result = await api
          .rankRegionalRoutes(urls)
          .timeout(const Duration(seconds: 3));
      if (_disposed) return;
      final profile = result['profile'];
      if (profile is! Map<String, dynamic> || !_validProfile(profile)) {
        throw const FormatException('Invalid ranking profile');
      }
      final entries = result['routes'];
      if (entries is! List)
        throw const FormatException('Invalid regional rankings');
      final scores = <String, double>{};
      final seen = <String>{};
      for (final entry in entries) {
        if (entry is! Map ||
            entry['url'] is! String ||
            !urls.contains(entry['url']) ||
            !seen.add(entry['url'] as String) ||
            entry['score'] is! num ||
            !(entry['score'] as num).isFinite ||
            (entry['score'] as num) < 0 ||
            (entry['score'] as num) > 1) {
          throw const FormatException('Invalid regional route');
        }
        scores[entry['url'] as String] = (entry['score'] as num).toDouble();
      }
      await _applyProfile(profile);
      if (networkId != '${profile['networkId']}|direct') return;
      tracker.setRegionalScores(networkId, scores);
      final now = DateTime.now();
      for (final url in urls) {
        _checked[url] = now;
      }
      if (_checked.length > 1200) {
        _checked.removeWhere(
          (_, value) => now.difference(value) > const Duration(minutes: 5),
        );
      }
    } catch (error, stack) {
      _retryAfter = DateTime.now().add(const Duration(minutes: 1));
      AppDiagnostics.instance.recordError(
        'regional_route_ranking',
        error,
        stack,
      );
    }
  }

  static bool _validProfile(Map<String, dynamic>? profile) =>
      profile != null &&
      profile['schemaVersion'] == 1 &&
      profile['networkId'] is String &&
      RegExp(
        r'^[A-Z]{2}:[A-Za-z0-9._*-]{1,40}:[0-9*]{1,10}$',
      ).hasMatch(profile['networkId'] as String) &&
      profile['token'] is String &&
      (profile['token'] as String).length <= 1024 &&
      profile['expiresAt'] is int &&
      (profile['expiresAt'] as int) >
          DateTime.now().millisecondsSinceEpoch ~/ 1000;

  void dispose() {
    _disposed = true;
    tracker.prepareCandidates = null;
    api.close();
  }
}
