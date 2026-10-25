import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';

import 'app_diagnostics.dart';

/// A closing or hidden native window may stop supplying vsync. Keep renderer
/// detachment bounded and request one framework warm-up frame when necessary.
/// Failure still prevents engine shutdown.
Future<void> detachDesktopRenderers({
  required Future<void> Function() endOfFrame,
  required void Function() warmUpFrame,
  Duration timeout = const Duration(seconds: 2),
}) async {
  final detached = endOfFrame();
  try {
    await detached.timeout(timeout);
  } on TimeoutException {
    AppDiagnostics.instance.log('desktop_exit_detach_warmup');
    warmUpFrame();
    await detached.timeout(timeout);
  }
}

/// Separate preparation from native close so platform exit requests cannot
/// recursively await their own close acknowledgement.
class DesktopAppExitController {
  DesktopAppExitController({required this.prepare, required this.closeNative});
  final Future<void> Function() prepare;
  final Future<void> Function() closeNative;
  final closing = ValueNotifier(false);
  final error = ValueNotifier<String?>(null);
  Future<void>? _preparation;
  Future<void>? _nativeClose;
  bool _prepared = false;

  bool get prepared => _prepared;

  Future<void> prepareExit(String reason) {
    if (_prepared) return Future<void>.value();
    return _preparation ??= _prepare(reason).catchError((
      Object failure,
      StackTrace stack,
    ) {
      _preparation = null;
      Error.throwWithStackTrace(failure, stack);
    });
  }

  Future<void> _prepare(String reason) async {
    closing.value = true;
    error.value = null;
    AppDiagnostics.instance.log('desktop_exit_requested', {'reason': reason});
    try {
      await prepare();
      _prepared = true;
      AppDiagnostics.instance.log('desktop_exit_cleanup_completed', {
        'reason': reason,
      });
    } catch (failure, stack) {
      error.value = '资源清理未完成，暂不关闭。请重试。';
      AppDiagnostics.instance.recordError(
        'desktop_exit_cleanup',
        failure,
        stack,
      );
      rethrow;
    }
  }

  Future<void> requestExit(String reason) =>
      _nativeClose ??= _close(reason).whenComplete(() => _nativeClose = null);

  Future<void> _close(String reason) async {
    await prepareExit(reason);
    try {
      await closeNative();
    } catch (failure, stack) {
      error.value = '关闭未完成，请重试。';
      AppDiagnostics.instance.recordError(
        'desktop_native_close',
        failure,
        stack,
      );
      rethrow;
    }
  }

  void dispose() {
    closing.dispose();
    error.dispose();
  }
}

/// All explicit desktop exit entry points carry an auditable reason.
class DesktopAppExit {
  static DesktopAppExitController? controller;

  static Future<void> request(String reason) =>
      controller?.requestExit(reason) ?? windowManager.close();
}
