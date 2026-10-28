import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../core/android_app_exit.dart';
import '../core/app_diagnostics.dart';
import '../core/desktop_app_exit.dart';
import '../core/player_resources.dart';
import '../data/services/server_epg_runtime.dart';
import '../data/services/epg_refresh_service.dart';
import '../features/casting/cast_service.dart';
import '../features/player/player_service.dart';
import '../features/providers/source_maintenance_coordinator.dart';
import '../features/providers/provider_manager.dart' show databaseProvider;
import '../features/recording/recording_service.dart';
import '../features/remote/web_remote_server.dart';

class DesktopAppLifecycle extends StatefulWidget {
  const DesktopAppLifecycle({
    super.key,
    required this.child,
    this.controller,
    this.enabled,
  });
  final Widget child;
  final DesktopAppExitController? controller;
  final bool? enabled;

  @override
  State<DesktopAppLifecycle> createState() => _DesktopAppLifecycleState();
}

class _DesktopAppLifecycleState extends State<DesktopAppLifecycle>
    with WidgetsBindingObserver, WindowListener {
  DesktopAppExitController? _controller;
  ProviderContainer? _container;
  bool get _enabled =>
      widget.enabled ?? (Platform.isWindows || Platform.isMacOS);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_enabled || _controller != null) return;
    _container = widget.controller == null
        ? ProviderScope.containerOf(context, listen: false)
        : null;
    _controller =
        widget.controller ??
        DesktopAppExitController(
          prepare: _prepare,
          closeNative: () async {
            await AppDiagnostics.instance.shutdown(reason: 'desktop_exit');
            await windowManager.setPreventClose(false);
            await windowManager.close();
          },
        );
    DesktopAppExit.controller = _controller;
    WidgetsBinding.instance.addObserver(this);
    if (widget.controller == null) {
      windowManager.addListener(this);
      unawaited(windowManager.setPreventClose(true));
    }
  }

  Future<void> _prepare() async {
    final resources = PlayerResourceRegistry.instance;
    resources.beginShutdown();
    // Replace the route tree first, allowing Video renderers to detach.
    final binding = WidgetsBinding.instance;
    AppDiagnostics.instance.log('desktop_renderer_detach_begin', {
      'lifecycle': binding.lifecycleState?.name,
      'framesEnabled': binding.framesEnabled,
    });
    await detachDesktopRenderers(
      endOfFrame: () => binding.endOfFrame,
      warmUpFrame: binding.scheduleWarmUpFrame,
    );
    AppDiagnostics.instance.log('desktop_renderers_detached');
    final container = _container!;
    final work = <Future<void>>[
      if (container.exists(epgRefreshServiceProvider))
        container.read(epgRefreshServiceProvider).shutdown(),
      if (container.exists(serverEpgRuntimeProvider))
        container.read(serverEpgRuntimeProvider).shutdown(),
      if (container.exists(sourceMaintenanceCoordinatorProvider))
        container.read(sourceMaintenanceCoordinatorProvider).shutdown(),
      if (container.exists(playerServiceProvider))
        container.read(playerServiceProvider).dispose(),
      if (container.exists(castServiceProvider))
        container.read(castServiceProvider).stopCasting(),
      if (container.exists(recordingServiceProvider))
        container.read(recordingServiceProvider).stopAll(),
      if (container.exists(webRemoteServerProvider))
        container.read(webRemoteServerProvider).stop(),
      AndroidExitDrain.wait(),
    ];
    AppDiagnostics.instance.log('desktop_service_cleanup_begin', {
      'operations': work.length,
      'players': resources.resourceCount,
    });
    // A timeout leaves the engine alive and offers retry. It never grants
    // permission to close over an unfinished native callback.
    await Future.wait(work).timeout(const Duration(seconds: 20));
    await resources.disposeAll().timeout(const Duration(seconds: 20));
    if (container.exists(databaseProvider)) {
      AppDiagnostics.instance.log('desktop_database_close_begin');
      await container
          .read(databaseProvider)
          .close()
          .timeout(const Duration(seconds: 20));
      AppDiagnostics.instance.log('desktop_database_close_completed');
    }
    AppDiagnostics.instance.log('desktop_resources_drained', {
      'players': resources.resourceCount,
    });
  }

  @override
  void onWindowClose() {
    if (_controller?.prepared == true) return;
    unawaited(
      _controller!
          .requestExit('native_window_close')
          .catchError((Object _, StackTrace __) {}),
    );
  }

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    if (_controller == null) return AppExitResponse.exit;
    try {
      await _controller!.prepareExit('platform_application_exit');
      if (widget.controller == null) {
        // Windows' platform exit acknowledgement posts another native close.
        // Only release the close veto after every decoder has drained.
        await windowManager.setPreventClose(false);
      }
      await AppDiagnostics.instance.shutdown(reason: 'desktop_platform_exit');
      return AppExitResponse.exit;
    } catch (_) {
      return AppExitResponse.cancel;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (widget.controller == null && _enabled)
      windowManager.removeListener(this);
    if (identical(DesktopAppExit.controller, _controller))
      DesktopAppExit.controller = null;
    if (widget.controller == null) _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_enabled || _controller == null) return widget.child;
    return ValueListenableBuilder<bool>(
      valueListenable: _controller!.closing,
      builder: (_, closing, __) {
        if (!closing) return widget.child;
        return Directionality(
          textDirection: TextDirection.ltr,
          child: Material(
            color: const Color(0xFF0A0F1B),
            child: Center(
              child: ValueListenableBuilder<String?>(
                valueListenable: _controller!.error,
                builder: (_, error, __) => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (error == null) const CircularProgressIndicator(),
                    const SizedBox(height: 16),
                    Text(
                      error ?? '正在清理资源并退出…',
                      style: const TextStyle(color: Colors.white70),
                    ),
                    if (error != null)
                      FilledButton(
                        onPressed: () => unawaited(
                          _controller!
                              .requestExit('cleanup_retry')
                              .catchError((Object _, StackTrace __) {}),
                        ),
                        child: const Text('重试退出'),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
