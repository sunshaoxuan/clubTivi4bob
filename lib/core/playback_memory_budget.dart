/// Bound simultaneous preview buffers independently of the desktop budget.
class PlaybackMemoryBudget {
  const PlaybackMemoryBudget({required this.tablet});
  final bool tablet;
  int get main => (tablet ? 48 : 96) * 1024 * 1024;
  int get preview => (tablet ? 24 : 48) * 1024 * 1024;
  int get discovery => (tablet ? 12 : 24) * 1024 * 1024;
  int get warm => (tablet ? 16 : 32) * 1024 * 1024;
}
