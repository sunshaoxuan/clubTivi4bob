import 'dart:io';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

import 'mac_update_service.dart';
import 'windows_update_service.dart';
import 'android_update_service.dart';
import '../../core/desktop_app_exit.dart';

/// The UI depends on this small platform-neutral entry point. Each operating
/// system owns its update directory, helper process and installation rules.
class DesktopUpdateService with WidgetsBindingObserver, WindowListener {
  DesktopUpdateService._();

  static final instance = DesktopUpdateService._();
  bool _started = false;
  DateTime? _lastForegroundCheck;

  ValueListenable<WindowsUpdateState> get state => Platform.isAndroid
      ? AndroidUpdateService.instance.state
      : Platform.isMacOS
      ? MacUpdateService.instance.state
      : WindowsUpdateService.instance.state;

  void start() {
    if (_started ||
        !(Platform.isMacOS || Platform.isWindows || Platform.isAndroid)) {
      return;
    }
    _started = true;
    _lastForegroundCheck = DateTime.now();
    WidgetsBinding.instance.addObserver(this);
    if (!Platform.isAndroid) windowManager.addListener(this);
    if (Platform.isAndroid) {
      AndroidUpdateService.instance.start();
    } else if (Platform.isMacOS) {
      MacUpdateService.instance.start();
    } else if (Platform.isWindows) {
      WindowsUpdateService.instance.start();
    }
  }

  @override
  void onWindowFocus() => _checkOnForeground();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkOnForeground();
  }

  void _checkOnForeground() {
    final now = DateTime.now();
    if (_lastForegroundCheck != null &&
        now.difference(_lastForegroundCheck!) < const Duration(minutes: 15)) {
      return;
    }
    if (!state.value.canCheck) return;
    _lastForegroundCheck = now;
    unawaited(checkNow());
  }

  Future<void> checkNow() => Platform.isAndroid
      ? AndroidUpdateService.instance.checkNow()
      : Platform.isMacOS
      ? MacUpdateService.instance.checkNow()
      : WindowsUpdateService.instance.checkNow();

  Future<void> installReady() => Platform.isAndroid
      ? AndroidUpdateService.instance.installReady()
      : Platform.isWindows
      ? WindowsUpdateService.instance.installReady()
      : Platform.isMacOS
      ? DesktopAppExit.request('mac_update_install')
      : Future.value();

  Future<void> markStartupHealthy() => Platform.isAndroid
      ? Future.value()
      : Platform.isMacOS
      ? MacUpdateService.instance.markStartupHealthy()
      : WindowsUpdateService.instance.markStartupHealthy();
}
