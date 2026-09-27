/// Shared UI state for the platform-specific desktop update workers.
/// The Windows-prefixed names are retained for source compatibility.
enum WindowsUpdatePhase {
  idle,
  available,
  downloading,
  ready,
  installing,
  failed,
}

class WindowsUpdateState {
  const WindowsUpdateState(
    this.phase, {
    this.version,
    this.percent,
    this.message,
  });

  final WindowsUpdatePhase phase;
  final String? version;
  final int? percent;
  final String? message;

  bool get visible => phase != WindowsUpdatePhase.idle;
}
