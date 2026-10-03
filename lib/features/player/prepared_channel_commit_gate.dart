import 'dart:async';

/// Coalesces clicks on one preview and checks ownership across asynchronous work.
class PreparedChannelCommitGate {
  Object? _owner;
  Future<bool>? _running;

  Future<bool> run({
    required Object owner,
    required void Function() onStart,
    required bool Function() isCurrent,
    required bool Function() readyNow,
    required Future<bool> Function() waitUntilReady,
    required Future<bool> Function() promote,
  }) {
    if (identical(owner, _owner) && _running != null) return _running!;
    final result = Completer<bool>();
    _owner = owner;
    _running = result.future;
    Future<void> execute() async {
      try {
        onStart();
        if (!isCurrent()) {
          result.complete(false);
          return;
        }
        if (!readyNow() && !await waitUntilReady()) {
          result.complete(false);
          return;
        }
        if (!isCurrent()) {
          result.complete(false);
          return;
        }
        result.complete(await promote());
      } catch (error, stack) {
        result.completeError(error, stack);
      } finally {
        if (identical(_owner, owner)) {
          _owner = null;
          _running = null;
        }
      }
    }

    unawaited(execute());
    return result.future;
  }
}
