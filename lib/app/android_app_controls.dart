import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/android_app_exit.dart';
import '../core/app_diagnostics.dart';
import '../data/services/android_pip_service.dart';
import '../data/services/android_update_service.dart';
import '../features/casting/cast_service.dart';
import '../features/player/player_service.dart';
import '../features/recording/recording_service.dart';
import '../features/remote/web_remote_server.dart';

/// Keep an explicit touch/mouse/remote exit reachable on every Android route,
/// including startup, empty catalogs, settings, TV mode and fullscreen video.
/// The reserved strip never covers channel cards, EPG or player controls.
class AndroidAppControls extends StatefulWidget {
  const AndroidAppControls({
    super.key,
    required this.child,
    this.enabled,
    this.controller,
    this.pictureInPicture,
  });

  final Widget child;
  final bool? enabled;
  final AndroidAppExitController? controller;
  final ValueNotifier<bool>? pictureInPicture;

  @override
  State<AndroidAppControls> createState() => _AndroidAppControlsState();
}

class _AndroidAppControlsState extends State<AndroidAppControls> {
  AndroidAppExitController? _controller;
  bool get _enabled => widget.enabled ?? Platform.isAndroid;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_enabled || _controller != null) return;
    _controller =
        widget.controller ??
        AndroidAppExitController(
          prepare: () =>
              _prepareExit(ProviderScope.containerOf(context, listen: false)),
          closeTask: AndroidAppExitController.closeAndroidTask,
        );
  }

  Future<void> _prepareExit(ProviderContainer container) async {
    // Detach player widgets and their subscriptions before disposing providers.
    await WidgetsBinding.instance.endOfFrame;
    final operations = <Future<void> Function()>[
      AndroidUpdateService.instance.stop,
      if (container.exists(playerServiceProvider))
        container.read(playerServiceProvider).dispose,
      if (container.exists(castServiceProvider))
        container.read(castServiceProvider).stopCasting,
      if (container.exists(recordingServiceProvider))
        container.read(recordingServiceProvider).stopAll,
      if (container.exists(webRemoteServerProvider))
        container.read(webRemoteServerProvider).stop,
      AndroidExitDrain.wait,
    ];
    await Future.wait(
      operations.map((operation) async {
        try {
          await operation().timeout(const Duration(seconds: 4));
        } catch (error, stack) {
          AppDiagnostics.instance.recordError(
            'android_exit_cleanup',
            error,
            stack,
          );
        }
      }),
    );
    // Cancels catalog synchronization, HTTP clients, recordings, device scans
    // and provider timers. Their durable database outboxes stay on disk.
    container.dispose();
    await AppDiagnostics.instance.shutdown(reason: 'android_exit');
  }

  @override
  void dispose() {
    if (widget.controller == null) _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_enabled) return widget.child;
    final controller = _controller!;
    return ValueListenableBuilder<bool>(
      valueListenable: controller.closing,
      builder: (context, closing, _) {
        if (closing) {
          return Material(
            color: const Color(0xFF0A0F1B),
            child: Center(
              child: ValueListenableBuilder<String?>(
                valueListenable: controller.error,
                builder: (context, error, _) => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (error == null)
                      const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    const SizedBox(height: 16),
                    Text(
                      error ?? '正在退出 BobTV…',
                      style: const TextStyle(color: Colors.white70),
                    ),
                    if (error != null) ...[
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: () => unawaited(controller.requestExit()),
                        icon: const Icon(Icons.power_settings_new_rounded),
                        label: const Text('重试退出'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );
        }
        return ValueListenableBuilder<bool>(
          valueListenable:
              widget.pictureInPicture ?? AndroidPipService.instance.active,
          builder: (context, inPip, _) => ColoredBox(
            color: const Color(0xFF0A0F1B),
            child: SafeArea(
              bottom: false,
              top: !inPip,
              child: Column(
                children: [
                  if (!inPip)
                    Material(
                      color: const Color(0xFF0D1422),
                      child: Container(
                        height: 52,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: const BoxDecoration(
                          border: Border(
                            bottom: BorderSide(color: Color(0x167C91BE)),
                          ),
                        ),
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            key: const ValueKey('android-app-exit'),
                            onPressed: () =>
                                unawaited(controller.requestExit()),
                            icon: const Icon(
                              Icons.power_settings_new_rounded,
                              size: 20,
                            ),
                            label: const Text('退出 BobTV'),
                            style: TextButton.styleFrom(
                              foregroundColor: const Color(0xFFD1DDFC),
                              minimumSize: const Size(112, 48),
                            ),
                          ),
                        ),
                      ),
                    ),
                  Expanded(
                    key: const ValueKey('android-route-content'),
                    child: widget.child,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
