// Explicit local QA entry. The normal app never enables the driver extension.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_driver/driver_extension.dart';
import 'package:clubtivi/main.dart' as app;
import 'package:clubtivi/app/router.dart';
import 'package:clubtivi/features/player/player_service.dart';

void main() {
  app.main(
    onBindingReady: () {
      enableFlutterDriverExtension(
        handler: (message) async {
          if (message == 'landscape') {
            await SystemChrome.setPreferredOrientations([
              DeviceOrientation.landscapeLeft,
              DeviceOrientation.landscapeRight,
            ]);
          } else if (message == 'portrait') {
            await SystemChrome.setPreferredOrientations([
              DeviceOrientation.portraitUp,
            ]);
          } else if (message == 'stop') {
            final context = router.routerDelegate.navigatorKey.currentContext!;
            await ProviderScope.containerOf(
              context,
              listen: false,
            ).read(playerServiceProvider).stop();
          } else if (message == 'state') {
            final context = router.routerDelegate.navigatorKey.currentContext!;
            final service = ProviderScope.containerOf(
              context,
              listen: false,
            ).read(playerServiceProvider);
            final player = service.player;
            final state = player.state;
            final dynamic native = player.platform;
            return jsonEncode({
              'channelId': service.currentChannelId,
              'playing': state.playing,
              'positionMs': state.position.inMilliseconds,
              'width': state.width,
              'height': state.height,
              'muted': await native.getProperty('mute') == 'yes',
            });
          } else if (message == 'pid') {
            return '$pid';
          }
          return 'ok';
        },
      );
    },
  );
}
