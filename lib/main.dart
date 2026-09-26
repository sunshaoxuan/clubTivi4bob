import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'app/app.dart';
import 'core/app_diagnostics.dart';
import 'data/services/legacy_preferences_migration.dart';

void main() {
  final diagnostics = AppDiagnostics.instance;
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      await diagnostics.initialize();
      await LegacyPreferencesMigration.run();

      FlutterError.onError = (details) {
        diagnostics.recordError(
          'flutter_framework',
          details.exception,
          details.stack ?? StackTrace.current,
          fatal: details.silent == false,
        );
        FlutterError.presentError(details);
      };
      PlatformDispatcher.instance.onError = (error, stackTrace) {
        diagnostics.recordError('platform_dispatcher', error, stackTrace);
        return true;
      };

      MediaKit.ensureInitialized();
      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        await windowManager.ensureInitialized();
      }
      diagnostics.log('flutter_ready', {
        'diagnosticDirectory': diagnostics.logDirectoryPath,
      });
      runApp(const ProviderScope(child: ClubTiviApp()));
    },
    (error, stackTrace) {
      diagnostics.recordError('root_zone', error, stackTrace, fatal: true);
    },
  );
}
