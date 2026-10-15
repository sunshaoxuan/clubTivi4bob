// Isolated native window and Flutter route regression. No application services.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';
import 'package:clubtivi/features/player/desktop_fullscreen_session.dart';
import 'package:clubtivi/features/player/window_manager_fullscreen_backend.dart';

final navigator = GlobalKey<NavigatorState>();
final channelKey = GlobalKey<_ChannelsState>();

Future<void> settle() =>
    Future<void>.delayed(const Duration(milliseconds: 450));
void require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

void trace(String event, [Map<String, Object?> fields = const {}]) =>
    stdout.writeln(jsonEncode({'event': event, ...fields}));

class _Channels extends StatefulWidget {
  const _Channels({super.key});
  @override
  State<_Channels> createState() => _ChannelsState();
}

class _ChannelsState extends State<_Channels> {
  final selectedCategory = '中国 / 央视';
  final channel = 'CCTV-6';
  final playbackIdentity = Object();
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xff142137),
    body: Row(
      children: [
        const Expanded(child: Center(child: Text('播放保持中'))),
        Expanded(
          child: Center(child: Text('$selectedCategory\n$channel\n频道列表')),
        ),
      ],
    ),
  );
}

class _Video extends StatefulWidget {
  const _Video({required this.ready});
  final Completer<void> ready;
  @override
  State<_Video> createState() => _VideoState();
}

class _VideoState extends State<_Video> {
  late final DesktopFullscreenSession session;
  bool leaving = false;
  @override
  void initState() {
    super.initState();
    session = DesktopFullscreenSession(
      backend: WindowManagerFullscreenBackend(),
      onChanged: (_) {},
      onExternalExit: () => unawaited(leave()),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await session.enter();
        widget.ready.complete();
      } catch (error, stack) {
        widget.ready.completeError(error, stack);
      }
    });
  }

  Future<void> leave() async {
    if (leaving) return;
    leaving = true;
    trace('video_exit_requested');
    await session.exit();
    trace('video_window_restored');
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    autofocus: true,
    onKeyEvent: (_, event) {
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.escape) {
        trace('escape_received');
        unawaited(leave());
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onDoubleTap: leave,
      child: const ColoredBox(
        color: Colors.black,
        child: Center(child: Text('视频全屏往返测试')),
      ),
    ),
  );
}

Future<({Future<void> returned})> openVideo() async {
  final ready = Completer<void>();
  final returned = navigator.currentState!.push(
    MaterialPageRoute<void>(builder: (_) => _Video(ready: ready)),
  );
  await ready.future.timeout(const Duration(seconds: 15));
  // Already-fullscreen callers do not wait for a native Space animation.
  // Wait for the route's own 300ms animation before sending its input.
  await settle();
  return (returned: returned);
}

Future<void> sendNativeEscapeToSelf() async {
  final quartz = DynamicLibrary.open(
    '/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics',
  );
  final allowed = quartz.lookupFunction<Uint8 Function(), int Function()>(
    'CGPreflightPostEventAccess',
  );
  require(allowed() != 0, 'Native input permission unavailable');
  final create = quartz
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Uint16, Uint8),
        Pointer<Void> Function(Pointer<Void>, int, int)
      >('CGEventCreateKeyboardEvent');
  final post = quartz
      .lookupFunction<
        Void Function(Int32, Pointer<Void>),
        void Function(int, Pointer<Void>)
      >('CGEventPostToPid');
  final core = DynamicLibrary.open(
    '/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation',
  );
  final release = core
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('CFRelease');
  for (final down in [1, 0]) {
    final event = create(nullptr, 0x35, down);
    require(event != nullptr, 'Cannot create native Escape event');
    // PID delivery cannot send keys to another application if focus changes.
    post(pid, event);
    release(event);
    await Future<void>.delayed(const Duration(milliseconds: 60));
  }
}

Future<void> doubleTapVideo() async {
  for (var i = 0; i < 2; i++) {
    final position =
        (WidgetsBinding.instance.platformDispatcher.views.first.physicalSize /
                WidgetsBinding
                    .instance
                    .platformDispatcher
                    .views
                    .first
                    .devicePixelRatio)
            .center(Offset.zero);
    GestureBinding.instance.handlePointerEvent(
      PointerDownEvent(pointer: 1, position: position),
    );
    GestureBinding.instance.handlePointerEvent(
      PointerUpEvent(pointer: 1, position: position),
    );
    await Future<void>.delayed(const Duration(milliseconds: 75));
  }
}

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  await windowManager.setTitle('BobTV fullscreen state QA');
  runApp(
    MaterialApp(
      navigatorKey: navigator,
      theme: ThemeData.dark(),
      home: _Channels(key: channelKey),
    ),
  );
  await WidgetsBinding.instance.endOfFrame;
  await windowManager.show();
  await windowManager.focus();
  await settle();
  final records = <Map<String, Object?>>[];
  final report = arguments
      .singleWhere((value) => value.startsWith('--report='))
      .substring(9);
  try {
    final caller = channelKey.currentState!;
    for (final mode in ['normal', 'maximized', 'windowFullscreen']) {
      if (await windowManager.isFullScreen()) {
        await windowManager.setFullScreen(false);
      }
      await settle();
      if (await windowManager.isMaximized()) await windowManager.unmaximize();
      await windowManager.setBounds(const Rect.fromLTWH(80, 80, 1000, 650));
      await settle();
      if (mode == 'maximized') await windowManager.maximize();
      if (mode == 'windowFullscreen') await windowManager.setFullScreen(true);
      await settle();
      require(
        channelKey.currentState == caller,
        'Native window action changed channel route',
      );
      final before = await windowManager.getBounds();
      final maxBefore = await windowManager.isMaximized();
      for (var cycle = 0; cycle < 3; cycle++) {
        trace('cycle_started', {'mode': mode, 'cycle': cycle});
        final returned = (await openVideo()).returned;
        require(
          await windowManager.isFullScreen(),
          'Video entry was not native fullscreen',
        );
        await doubleTapVideo();
        await returned.timeout(const Duration(seconds: 15));
        await settle();
        final after = await windowManager.getBounds();
        require(
          await windowManager.isFullScreen() == (mode == 'windowFullscreen'),
          'Wrong window fullscreen after $mode cycle $cycle',
        );
        require(
          await windowManager.isMaximized() == maxBefore,
          'Wrong maximization after $mode',
        );
        require(
          channelKey.currentState == caller &&
              caller.playbackIdentity ==
                  channelKey.currentState!.playbackIdentity,
          'Caller channel/video state was recreated',
        );
        if (mode == 'normal') {
          require(
            (before.left - after.left).abs() < 3 &&
                (before.top - after.top).abs() < 3 &&
                (before.width - after.width).abs() < 3 &&
                (before.height - after.height).abs() < 3,
            'Original window geometry changed: $before -> $after',
          );
        }
        records.add({
          'mode': mode,
          'cycle': cycle,
          'width': after.width,
          'height': after.height,
        });
      }
    }
    final returned = (await openVideo()).returned;
    await windowManager.setFullScreen(false);
    await returned.timeout(const Duration(seconds: 15));
    require(!await windowManager.isFullScreen(), 'Native Escape was undone');
    records.add({'mode': 'native-exit', 'passed': true});
    await settle();
    final escaped = (await openVideo()).returned;
    await sendNativeEscapeToSelf();
    await escaped.timeout(const Duration(seconds: 15));
    await settle();
    require(
      !await windowManager.isFullScreen(),
      'Escape left video fullscreen',
    );
    records.add({'mode': 'native-keyboard-escape', 'passed': true});
    final afterEscape = await windowManager.getBounds();
    for (var cycle = 0; cycle < 2; cycle++) {
      final returned = (await openVideo()).returned;
      require(
        await windowManager.isFullScreen(),
        'Re-entry after Escape failed',
      );
      await doubleTapVideo();
      await returned.timeout(const Duration(seconds: 15));
      await settle();
      require(!await windowManager.isFullScreen(), 'Re-entry did not restore');
      final restored = await windowManager.getBounds();
      require(
        (afterEscape.left - restored.left).abs() < 3 &&
            (afterEscape.top - restored.top).abs() < 3 &&
            (afterEscape.width - restored.width).abs() < 3 &&
            (afterEscape.height - restored.height).abs() < 3 &&
            channelKey.currentState == caller,
        'Caller window or channel changed after Escape re-entry',
      );
      records.add({'mode': 'escape-reentry', 'cycle': cycle, 'passed': true});
    }
    await File(report).writeAsString(
      jsonEncode({'passed': true, 'records': records}),
      flush: true,
    );
  } catch (error, stack) {
    await File(report).writeAsString(
      jsonEncode({
        'passed': false,
        'records': records,
        'error': '$error\n$stack',
      }),
      flush: true,
    );
  } finally {
    if (await windowManager.isFullScreen()) {
      await windowManager.setFullScreen(false);
    }
    await windowManager.close();
  }
}
