/// Keeps manual "next route" clicks moving forward within a channel.
/// A new cycle starts after five minutes without a route attempt.
class ManualRouteCycle {
  final Map<String, Set<String>> _attempted = {};
  final Map<String, DateTime> _lastAttemptAt = {};

  String? chooseNext({
    required String channelKey,
    required String currentUrl,
    required Iterable<String> candidates,
    required double Function(String url) score,
    DateTime? now,
  }) {
    final time = now ?? DateTime.now();
    final last = _lastAttemptAt[channelKey];
    if (last != null && time.difference(last) >= const Duration(minutes: 5)) {
      _attempted.remove(channelKey);
    }
    final attempted = _attempted.putIfAbsent(channelKey, () => <String>{});
    if (currentUrl.isNotEmpty) attempted.add(currentUrl);
    final ranked = candidates.where((url) => url.isNotEmpty).toSet().toList();
    final order = {for (var i = 0; i < ranked.length; i++) ranked[i]: i};
    ranked.sort((left, right) {
      final byScore = score(right).compareTo(score(left));
      return byScore != 0 ? byScore : order[left]!.compareTo(order[right]!);
    });
    for (final url in ranked) {
      if (attempted.add(url)) {
        _lastAttemptAt[channelKey] = time;
        return url;
      }
    }
    return null;
  }
}
