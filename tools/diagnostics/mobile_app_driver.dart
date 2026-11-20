// Explicit local QA entry. The normal app never enables the driver extension.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_driver/driver_extension.dart';
import 'package:clubtivi/main.dart' as app;
import 'package:clubtivi/app/router.dart';
import 'package:clubtivi/features/player/player_service.dart';
import 'package:clubtivi/features/providers/provider_manager.dart';
import 'package:clubtivi/features/player/subtitle_preferences.dart';
import 'package:clubtivi/features/player/client_subtitle_runtime.dart';

Future<String> handleMobileQaCommand(String? message) async {
  if (message == 'landscape') {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  } else if (message == 'portrait') {
    await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  } else if (message == 'back') {
    await router.routerDelegate.navigatorKey.currentState!.maybePop();
  } else if (message == 'stop' || message == 'state') {
    final context = router.routerDelegate.navigatorKey.currentContext!;
    final container = ProviderScope.containerOf(context, listen: false);
    final service = container.read(playerServiceProvider);
    if (message == 'stop') {
      await service.stop();
    } else {
      final player = service.player;
      final state = player.state;
      final dynamic native = player.platform;
      return jsonEncode({
        'route':
            router.routerDelegate.currentConfiguration.last.matchedLocation,
        'playerIdentity': identityHashCode(player),
        'channelId': service.currentChannelId,
        'playing': state.playing,
        'positionMs': state.position.inMilliseconds,
        'width': state.width,
        'height': state.height,
        'muted': await native.getProperty('mute') == 'yes',
        'favorite':
            (await container
                    .read(databaseProvider)
                    .getAllFavoritedChannelIds(reconcile: false))
                .contains(service.currentChannelId),
        'subtitleEnabled': SubtitlePreferences.instance.enabled,
        'subtitleLanguage': SubtitlePreferences.instance.language.tag,
        'subtitleFollowsApplication':
            SubtitlePreferences.instance.followsApplication,
        'offlineSubtitleRuntimeAvailable': ClientSubtitleRuntime.available,
      });
    }
  } else if (message == 'pid') {
    return '$pid';
  }
  return 'ok';
}

void main() => app.main(
  onBindingReady: () {
    enableFlutterDriverExtension(handler: handleMobileQaCommand);
  },
);
