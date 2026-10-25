import 'dart:async';
import 'dart:io' show Platform;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/app_diagnostics.dart';
import '../../features/providers/provider_manager.dart';
import 'server_epg_sync_service.dart';

class ServerEpgRuntime with WidgetsBindingObserver, WindowListener {
  ServerEpgRuntime(
    this.service, {
    Stream<bool>? networkChanges,
    bool? observeWindow,
    DateTime Function()? now,
  }) : _network =
           networkChanges ??
           Connectivity().onConnectivityChanged.map(
             (values) => values.any((v) => v != ConnectivityResult.none),
           ),
       _observeWindow =
           observeWindow ?? (Platform.isWindows || Platform.isMacOS),
       _now = now ?? DateTime.now;
  final ServerEpgSyncService service;
  final Stream<bool> _network;
  final bool _observeWindow;
  final DateTime Function() _now;
  StreamSubscription<bool>? _subscription;
  bool _started = false, _disposed = false;
  bool? _online;
  DateTime? _lastForeground;

  void start() {
    if (_started || _disposed) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    if (_observeWindow) windowManager.addListener(this);
    _subscription = _network.distinct().listen(
      (online) {
        final previous = _online;
        _online = online;
        if (previous == false && online) service.onNetworkRestored();
      },
      onError: (Object error, StackTrace stack) {
        AppDiagnostics.instance.log('epg_connectivity_observer_unavailable', {
          'type': error.runtimeType.toString(),
        });
      },
    );
    service.start();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _foreground();
  }

  @override
  void onWindowFocus() => _foreground();
  void _foreground() {
    if (_disposed) return;
    final now = _now();
    if (_lastForeground != null &&
        now.difference(_lastForeground!) < const Duration(seconds: 5)) {
      return;
    }
    _lastForeground = now;
    service.onAppResumed();
  }

  Future<void> shutdown() async {
    dispose();
    await _subscription?.cancel();
    await service.shutdown();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    if (_observeWindow) windowManager.removeListener(this);
    unawaited(_subscription?.cancel());
    service.dispose();
  }
}

final serverEpgRuntimeProvider = Provider<ServerEpgRuntime>((ref) {
  final runtime = ServerEpgRuntime(
    ServerEpgSyncService(database: ref.watch(databaseProvider)),
  );
  runtime.start();
  ref.onDispose(runtime.dispose);
  return runtime;
});
