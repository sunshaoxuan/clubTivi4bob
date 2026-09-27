import 'dart:io';

import 'package:flutter/foundation.dart';

import 'mac_update_service.dart';
import 'desktop_update_state.dart';
import 'windows_update_service.dart';

/// The UI depends on this small platform-neutral entry point. Each operating
/// system owns its update directory, helper process and installation rules.
class DesktopUpdateService {
  DesktopUpdateService._();

  static final instance = DesktopUpdateService._();

  ValueListenable<WindowsUpdateState> get state => Platform.isMacOS
      ? MacUpdateService.instance.state
      : WindowsUpdateService.instance.state;

  void start() {
    if (Platform.isMacOS) {
      MacUpdateService.instance.start();
    } else if (Platform.isWindows) {
      WindowsUpdateService.instance.start();
    }
  }

  Future<void> checkNow() => Platform.isMacOS
      ? MacUpdateService.instance.checkNow()
      : WindowsUpdateService.instance.checkNow();

  Future<void> markStartupHealthy() => Platform.isMacOS
      ? MacUpdateService.instance.markStartupHealthy()
      : WindowsUpdateService.instance.markStartupHealthy();
}
