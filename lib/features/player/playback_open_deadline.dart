import 'dart:async';

/// Preserve ordinary route deadlines while allowing an active subtitle clock
/// preparation to finish within the existing 35-second subtitle startup bound.
Future<void> awaitPlaybackOpen(
  Future<void> operation, {
  required Duration initialTimeout,
  required bool Function() preparingSubtitleClock,
  Duration maximumTimeout = const Duration(seconds: 35),
}) async {
  try {
    await operation.timeout(initialTimeout);
  } on TimeoutException {
    if (initialTimeout >= maximumTimeout || !preparingSubtitleClock()) rethrow;
    await operation.timeout(maximumTimeout - initialTimeout);
  }
}
