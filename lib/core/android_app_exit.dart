import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'app_diagnostics.dart';

/// One exit transaction, shared by every Android route. A failed native close
/// can be retried without bringing back a partially shut-down application.
class AndroidAppExitController {
  AndroidAppExitController({required this.prepare, required this.closeTask});

  final Future<void> Function() prepare;
  final Future<void> Function() closeTask;
  final closing = ValueNotifier(false);
  final error = ValueNotifier<String?>(null);
  Future<void>? _request;
  bool _prepared = false;
  bool _closed = false;

  Future<void> requestExit() {
    if (_closed) return Future.value();
    return _request ??= _exit().whenComplete(() => _request = null);
  }

  Future<void> _exit() async {
    closing.value = true;
    error.value = null;
    try {
      if (!_prepared) {
        try {
          await prepare().timeout(const Duration(seconds: 8));
        } catch (error, stack) {
          AppDiagnostics.instance.recordError(
            'android_exit_prepare',
            error,
            stack,
          );
        }
        _prepared = true;
      }
      await closeTask();
      _closed = true;
    } catch (_) {
      error.value = '退出未完成，请重试。';
    }
  }

  void dispose() {
    closing.dispose();
    error.dispose();
  }

  static Future<void> closeAndroidTask() async {
    try {
      final closed = await const MethodChannel(
        'bobtv/app',
      ).invokeMethod<bool>('exit').timeout(const Duration(seconds: 3));
      if (closed == true) return;
    } on MissingPluginException {
      // Older embeddings still have Flutter's standard activity-close path.
    } on PlatformException {
      // Keep the exit usable when the task-removal extension is unavailable.
    } on TimeoutException {
      // The Activity may already have been destroyed before replying.
    }
    await SystemNavigator.pop();
  }
}

/// Route-owned decoders begin asynchronous disposal when the exit screen
/// replaces the router. Wait for them before destroying the Flutter engine.
class AndroidExitDrain {
  static final _pending = <Future<void>>{};

  static void track(Future<void> operation) {
    _pending.add(operation);
    unawaited(
      operation.then<void>(
        (_) => _pending.remove(operation),
        onError: (Object _, StackTrace _) => _pending.remove(operation),
      ),
    );
  }

  static Future<void> wait() async {
    while (_pending.isNotEmpty) {
      await Future.wait(
        _pending.toList().map((operation) async {
          try {
            await operation;
          } catch (_) {}
        }),
      );
    }
  }
}
