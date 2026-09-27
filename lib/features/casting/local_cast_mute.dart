/// Serializes receiver ownership without touching playback or volume settings.
class LocalCastMute {
  LocalCastMute({required this.readMute, required this.writeMute});

  final Future<bool> Function() readMute;
  final Future<void> Function(bool) writeMute;
  Future<void> _queue = Future.value();
  bool? _savedMute;
  bool _disposed = false;

  Future<void> update(bool casting) {
    final operation = _queue.then((_) async {
      if (_disposed) return;
      if (casting) {
        if (_savedMute != null) return;
        final saved = await readMute();
        if (_disposed) return;
        await writeMute(true);
        _savedMute = saved;
      } else {
        final saved = _savedMute;
        if (saved == null) return;
        await writeMute(saved);
        _savedMute = null;
      }
    });
    // A failed request must not poison later stop/retry requests.
    _queue = operation.catchError((Object _) {});
    return operation;
  }

  void dispose() { _disposed = true; }
}
