import 'dart:async';

import 'package:media_kit/media_kit.dart';

import 'app_diagnostics.dart';

/// Owns every decoder, including disposals whose caller stopped waiting.
/// A UI timeout never cancels the native disposal or removes it from this set.
class PlayerResourceRegistry {
  static final instance = PlayerResourceRegistry();
  final _resources = <Object, _PlayerResource>{};
  bool _closing = false;

  bool get closing => _closing;
  int get resourceCount => _resources.length;

  void requireOpen() {
    if (_closing) throw StateError('Application player cleanup has started');
  }

  void register(Object owner, Future<void> Function() dispose, String role) {
    requireOpen();
    _resources[owner] = _PlayerResource(dispose, role);
  }

  Future<void> dispose(Object owner) {
    final resource = _resources[owner];
    if (resource == null) return Future<void>.value();
    return resource.pending ??= Future<void>.sync(() async {
      AppDiagnostics.instance.log('player_cleanup_begin', {
        'role': resource.role,
      });
      await resource.dispose();
      _resources.remove(owner);
      AppDiagnostics.instance.log('player_cleanup_completed', {
        'role': resource.role,
        'remaining': resourceCount,
      });
    });
  }

  void beginShutdown() => _closing = true;

  Future<void> disposeAll() async {
    beginShutdown();
    while (_resources.isNotEmpty) {
      await Future.wait(_resources.keys.toList().map(dispose));
    }
  }
}

class _PlayerResource {
  _PlayerResource(this.dispose, this.role);
  final Future<void> Function() dispose;
  final String role;
  Future<void>? pending;
}

/// Idempotent native ownership shared by main, warm, preview and multi-view.
class ManagedPlayer extends Player {
  factory ManagedPlayer({
    PlayerConfiguration configuration = const PlayerConfiguration(),
    PlatformPlayer? platformPlayer,
    String role = 'player',
    PlayerResourceRegistry? registry,
  }) {
    final resources = registry ?? PlayerResourceRegistry.instance;
    resources.requireOpen();
    return ManagedPlayer._(configuration, platformPlayer, resources, role);
  }

  ManagedPlayer._(
    PlayerConfiguration configuration,
    PlatformPlayer? platformPlayer,
    this._resources,
    String role,
  ) : super(configuration: configuration, platformPlayer: platformPlayer) {
    _resources.register(this, () => super.dispose(), role);
  }

  final PlayerResourceRegistry _resources;

  @override
  Future<void> dispose() => _resources.dispose(this);
}
