// Explicit local QA entry. The normal app never enables the driver extension.
import 'dart:async';
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
import 'package:clubtivi/features/player/ios_native_media.dart';

Future<String> handleMobileQaCommand(String? message) async {
  if (message == 'source-manager') {
    router.go('/providers');
    return 'ok';
  }
  if (message == 'source-state' || message == 'source-refresh') {
    final context = router.routerDelegate.navigatorKey.currentContext!;
    final container = ProviderScope.containerOf(context, listen: false);
    final database = container.read(databaseProvider);
    if (message == 'source-refresh') {
      for (final provider in await database.getAllProviders()) {
        if (provider.type == 'resource')
          await container
              .read(providerManagerProvider)
              .refreshProvider(provider.id);
      }
    }
    final channels = await database.getAllChannels();
    final keys = await database.channelPresentationKeys(channels);
    return jsonEncode({
      'providers': (await database.getAllProviders())
          .map((p) => {'name': p.name, 'type': p.type})
          .toList(),
      'routes': channels.length,
      'cards': keys.values.toSet().length,
      'names': channels.map((c) => c.name).toSet().toList(),
      'groups': await database.getUserSourceCategoryGroups(),
      'logos': channels.where((c) => c.tvgLogo?.isNotEmpty ?? false).length,
      'epgSources': (await database.getAllEpgSources()).length,
      'epgChannels': (await database.select(database.epgChannels).get()).length,
      'epgMappings': (await database.select(database.epgMappings).get()).length,
    });
  }
  if (message?.startsWith('native-call:') == true) {
    final command =
        jsonDecode(message!.substring('native-call:'.length)) as Map;
    try {
      return jsonEncode(
        await IosNativeMedia.channel.invokeMethod(
          command['method'] as String,
          command['args'],
        ),
      );
    } on PlatformException catch (error) {
      return jsonEncode({'error': error.code, 'details': error.details});
    }
  } else if (message == 'native-capabilities') {
    await IosNativeMedia.refresh();
    return jsonEncode(IosNativeMedia.capabilities);
  } else if (message == 'native-state') {
    return jsonEncode(await IosNativeMedia.channel.invokeMethod('playerState'));
  } else if (message == 'native-close') {
    await IosNativeMedia.channel.invokeMethod<void>('closePlayer');
  } else if (message?.startsWith('native-open:') == true) {
    unawaited(
      IosNativeMedia.channel.invokeMethod('presentPlayer', {
        'url': message!.substring('native-open:'.length),
        'qaSilent': true,
        'live': false,
        'position': 2.0,
      }),
    );
  } else if (message == 'native-fixture-play' ||
      message == 'native-pcm-probe') {
    final context = router.routerDelegate.navigatorKey.currentContext!;
    final container = ProviderScope.containerOf(context, listen: false);
    final service = container.read(playerServiceProvider);
    if (message == 'native-fixture-play') {
      final dynamic native = service.player.platform;
      await native.setProperty('ao', 'null');
      await service.setVolume(0);
      await service.play(
        'http://127.0.0.1:18765/fixture.mp4',
        channelId: 'owned-native-qa-fixture',
        channelName: 'BobTV Native QA',
      );
    } else {
      final dynamic native = service.player.platform;
      const label = 'bobtv_qa_pcm';
      try {
        await native.command([
          'af',
          'add',
          '@$label:lavfi=[bobtv_pcm]:o=[threads=1]',
        ]);
        for (var attempt = 0; attempt < 30; attempt++) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          final raw = await native.getProperty('af-metadata/$label') as String;
          if (raw.isEmpty) continue;
          final metadata = jsonDecode(raw) as Map;
          if (metadata['lavfi.bobtv_pcm.pcm'] != null) {
            return jsonEncode({
              'pcmBytes': base64Decode(
                metadata['lavfi.bobtv_pcm.pcm'] as String,
              ).length,
              'start': metadata['lavfi.bobtv_pcm.start'],
              'end': metadata['lavfi.bobtv_pcm.end'],
              'sequence': metadata['lavfi.bobtv_pcm.sequence'],
              'playing': service.player.state.playing,
              'muted': await native.getProperty('mute') == 'yes',
            });
          }
        }
        return jsonEncode({
          'error': 'pcm_timeout',
          'filters': await native.getProperty('af'),
          'audio': await native.getProperty('audio-params'),
          'audioOutput': await native.getProperty('audio-out-params'),
          'track': service.player.state.track.audio.id,
          'metadata': await native.getProperty('af-metadata/$label'),
        });
      } finally {
        await native.command(['af', 'remove', '@$label']);
      }
    }
  } else if (message == 'native-fixture-prepare' ||
      message == 'native-fixture-commit') {
    final context = router.routerDelegate.navigatorKey.currentContext!;
    final container = ProviderScope.containerOf(context, listen: false);
    final service = container.read(playerServiceProvider);
    final success = message == 'native-fixture-prepare'
        ? await service.switchChannel(
            'http://127.0.0.1:18765/fixture.mp4?next=1',
            channelId: 'owned-native-qa-next',
            channelName: 'BobTV Native QA Next',
            previewOnly: true,
            onlyRequestedRoute: true,
          )
        : await service.commitPreparedChannel('owned-native-qa-next');
    return jsonEncode({'success': success});
  } else if (message == 'native-resume-local') {
    final context = router.routerDelegate.navigatorKey.currentContext!;
    final container = ProviderScope.containerOf(context, listen: false);
    await container.read(playerServiceProvider).player.play();
  } else if (message == 'native-handoff') {
    final context = router.routerDelegate.navigatorKey.currentContext!;
    final container = ProviderScope.containerOf(context, listen: false);
    unawaited(container.read(playerServiceProvider).presentIosPlayer());
  } else if (message == 'landscape') {
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
