import 'dart:io';

import 'package:clubtivi/app/router.dart';
import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/data/services/stream_alternatives_service.dart';
import 'package:clubtivi/features/casting/cast_service.dart';
import 'package:clubtivi/features/player/adaptive_buffer.dart';
import 'package:clubtivi/features/player/player_presentation_buttons.dart';
import 'package:clubtivi/features/player/player_screen.dart';
import 'package:clubtivi/features/player/player_service.dart';
import 'package:clubtivi/features/providers/provider_manager.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Streams extends Fake implements PlayerStream {
  @override
  Stream<List<String>> get subtitle => const Stream.empty();
  @override
  Stream<Tracks> get tracks => const Stream.empty();
  @override
  Stream<bool> get playing => const Stream.empty();
  @override
  Stream<bool> get buffering => const Stream.empty();
  @override
  Stream<Duration> get position => const Stream.empty();
  @override
  Stream<Duration> get duration => const Stream.empty();
  @override
  Stream<double> get volume => const Stream.empty();
  @override
  Stream<int?> get width => const Stream.empty();
  @override
  Stream<int?> get height => const Stream.empty();
}

class _Player extends Fake implements Player {
  @override
  PlatformPlayer? get platform => null;
  _Player({required bool playing})
    : state = PlayerState(
        playing: playing,
        volume: 0,
        position: const Duration(seconds: 123),
        width: 1920,
        height: 1080,
      );
  @override
  final PlayerState state;
  @override
  final PlayerStream stream = _Streams();
}

class _Video extends Fake implements VideoController {
  _Video(this.player);
  @override
  final Player player;
  @override
  final notifier = ValueNotifier<PlatformVideoController?>(null);
}

class _Service extends Fake implements PlayerService {
  _Service({required bool playing}) : player = _Player(playing: playing) {
    videoController = _Video(player);
    activeVideoController = ValueNotifier(videoController);
  }
  int playRequests = 0;
  @override
  final bufferManager = AdaptiveBufferManager();
  @override
  final Player player;
  @override
  late final VideoController videoController;
  @override
  late final ValueNotifier<VideoController?> activeVideoController;
  @override
  final alternativePreviewState = ValueNotifier<AlternativePreviewState?>(null);
  @override
  final routeSearchProgress = ValueNotifier<RouteSearchProgress?>(null);
  @override
  String? get currentUrl => 'https://example.com/failover-radio.m3u8';
  @override
  String? get currentChannelId => 'radio-fixture';
  @override
  int get currentCandidateCount => 2;
  @override
  Stream<Player> get activePlayerStream => const Stream.empty();
  @override
  Stream<bool> get bufferingStream => const Stream.empty();
  @override
  Stream<String?> get currentUrlStream => const Stream.empty();
  @override
  Future<String?> getMpvProperty(String name) async => null;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #play) {
      playRequests++;
      return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }

  void disposeNotifiers() {
    activeVideoController.dispose();
    alternativePreviewState.dispose();
    routeSearchProgress.dispose();
  }
}

class _Cast extends Fake implements CastService {
  @override
  Stream<String?> get statusStream => const Stream.empty();
  @override
  bool get isCasting => false;
}

class _Alternatives extends Fake implements StreamAlternativesService {
  @override
  String providerName(String providerId) => 'Test provider';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final viewport in [const Size(984, 611), const Size(800, 500)]) {
    for (final playing in [true, false]) {
      testWidgets(
        'window player fills $viewport and returns without reopening media, playing=$playing',
        (tester) async {
          tester.view.physicalSize = viewport;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          SharedPreferences.setMockInitialValues({});
          final windowCalls = <MethodCall>[];
          final messenger =
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
          messenger.setMockMethodCallHandler(
            const MethodChannel('window_manager'),
            (call) async {
              windowCalls.add(call);
              return null;
            },
          );
          addTearDown(
            () => messenger.setMockMethodCallHandler(
              const MethodChannel('window_manager'),
              null,
            ),
          );
          final database = db.AppDatabase.forTesting(NativeDatabase.memory());
          addTearDown(database.close);
          final service = _Service(playing: playing);
          addTearDown(service.disposeNotifiers);

          // Exercise the actual production route builder with a minimal caller.
          final productionRouter = createRouter();
          final playerRoute = productionRouter.configuration.routes
              .whereType<GoRoute>()
              .singleWhere((route) => route.path == '/player');
          productionRouter.dispose();
          final router = GoRouter(
            routes: [
              GoRoute(
                path: '/',
                builder: (context, _) => Scaffold(
                  body: Column(
                    children: [
                      const Text('选台，原有筛选与滚动状态'),
                      PlayerPresentationButtons(
                        onFullscreen: () {},
                        onWindowPlayback: () => context.push(
                          '/player',
                          extra: {
                            'streamUrl':
                                'https://example.com/primary-radio.m3u8',
                            'channelName': 'Window Radio',
                            'startFullscreen': false,
                            'channels': [
                              <String, dynamic>{
                                'id': 'radio-fixture',
                                'name': 'Window Radio',
                                'providerId': 'fixture',
                                'groupTitle': '广播',
                                'streamUrl':
                                    'https://example.com/primary-radio.m3u8',
                              },
                            ],
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              playerRoute,
            ],
          );
          addTearDown(router.dispose);
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                databaseProvider.overrideWithValue(database),
                playerServiceProvider.overrideWithValue(service),
                castServiceProvider.overrideWithValue(_Cast()),
                streamAlternativesProvider.overrideWithValue(_Alternatives()),
              ],
              child: MaterialApp.router(
                theme: ThemeData.dark(),
                routerConfig: router,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(disableAnimations: true),
                  child: child!,
                ),
              ),
            ),
          );
          await tester.pump();
          final caller = tester.state(find.byType(Scaffold));
          final decoder = service.player;
          final controller = service.videoController;
          await tester.tap(find.byTooltip('全窗口播放'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 350));
          for (var i = 0; i < 3; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pump();
          }
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<PlayerScreen>(find.byType(PlayerScreen))
                .startFullscreen,
            isFalse,
          );
          expect(tester.getSize(find.byType(Video)), viewport);
          expect(find.text('选台，原有筛选与滚动状态'), findsNothing);
          expect(find.byTooltip('全屏播放'), findsOneWidget);
          expect(find.byTooltip('窗口置顶'), findsOneWidget);
          expect(service.playRequests, 0);
          expect(identical(service.player, decoder), isTrue);
          expect(identical(service.videoController, controller), isTrue);
          expect(service.player.state.playing, playing);
          expect(service.player.state.volume, 0);
          expect(service.player.state.position, const Duration(seconds: 123));
          expect(windowCalls, isEmpty);
          expect(tester.takeException(), isNull);

          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pump();
          await tester.pumpAndSettle();
          expect(find.byType(PlayerScreen), findsNothing);
          expect(find.text('选台，原有筛选与滚动状态'), findsOneWidget);
          expect(
            identical(tester.state(find.byType(Scaffold)), caller),
            isTrue,
          );
          expect(service.playRequests, 0);
          expect(windowCalls, isEmpty);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
        skip: !(Platform.isWindows || Platform.isMacOS || Platform.isLinux),
      );
    }
  }
}
