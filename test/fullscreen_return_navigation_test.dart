import 'package:clubtivi/features/player/fullscreen_return_navigation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _CallerScreen extends StatefulWidget {
  const _CallerScreen();

  @override
  State<_CallerScreen> createState() => _CallerScreenState();
}

class _CallerScreenState extends State<_CallerScreen> {
  int count = 0;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        Text('Caller count: $count'),
        ElevatedButton(
          key: const Key('increment-caller'),
          onPressed: () => setState(() => count++),
          child: const Text('Remember caller state'),
        ),
        ElevatedButton(
          key: const Key('open-player'),
          onPressed: () => context.push('/player'),
          child: const Text('Open player'),
        ),
      ],
    ),
  );
}

class _PlayerScreen extends StatelessWidget {
  const _PlayerScreen({required this.onContext});

  final ValueChanged<BuildContext> onContext;

  @override
  Widget build(BuildContext context) {
    onContext(context);
    return Scaffold(
      body: Column(
        children: [
          const Text('Fullscreen player'),
          ElevatedButton(
            key: const Key('return-from-player'),
            onPressed: () => FullscreenReturnNavigation.returnToCaller(context),
            child: const Text('Return'),
          ),
          ElevatedButton(
            key: const Key('open-player-dialog'),
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) =>
                  const AlertDialog(title: Text('Player popup menu')),
            ),
            child: const Text('Open popup'),
          ),
        ],
      ),
    );
  }
}

GoRouter _router({
  String initialLocation = '/',
  required ValueChanged<BuildContext> onPlayerContext,
}) => GoRouter(
  initialLocation: initialLocation,
  routes: [
    GoRoute(
      path: '/',
      pageBuilder: (context, state) =>
          const NoTransitionPage(child: _CallerScreen()),
    ),
    GoRoute(
      path: '/player',
      pageBuilder: (context, state) =>
          NoTransitionPage(child: _PlayerScreen(onContext: onPlayerContext)),
    ),
  ],
);

Future<void> _openFromRememberedCaller(
  WidgetTester tester,
  GoRouter router,
) async {
  await tester.pumpWidget(MaterialApp.router(routerConfig: router));
  await tester.pump();
  await tester.tap(find.byKey(const Key('increment-caller')));
  await tester.pump();
  expect(find.text('Caller count: 1'), findsOneWidget);
  await tester.tap(find.byKey(const Key('open-player')));
  await tester.pump();
  expect(find.text('Fullscreen player'), findsOneWidget);
}

void main() {
  testWidgets('ordinary return pops player and preserves caller state', (
    tester,
  ) async {
    final router = _router(onPlayerContext: (_) {});
    addTearDown(router.dispose);
    await _openFromRememberedCaller(tester, router);

    await tester.tap(find.byKey(const Key('return-from-player')));
    await tester.pump();

    expect(find.text('Fullscreen player'), findsNothing);
    expect(find.text('Caller count: 1'), findsOneWidget);
    expect(router.canPop(), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('native return closes popup and its owning player together', (
    tester,
  ) async {
    late BuildContext playerContext;
    final router = _router(
      onPlayerContext: (context) => playerContext = context,
    );
    addTearDown(router.dispose);
    await _openFromRememberedCaller(tester, router);
    await tester.tap(find.byKey(const Key('open-player-dialog')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Player popup menu'), findsOneWidget);

    FullscreenReturnNavigation.returnToCaller(playerContext);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Player popup menu'), findsNothing);
    expect(find.text('Fullscreen player'), findsNothing);
    expect(find.text('Caller count: 1'), findsOneWidget);
    expect(router.canPop(), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('direct player launch without a caller navigates home', (
    tester,
  ) async {
    final router = _router(initialLocation: '/player', onPlayerContext: (_) {});
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pump();
    expect(find.text('Fullscreen player'), findsOneWidget);
    expect(router.canPop(), isFalse);

    await tester.tap(find.byKey(const Key('return-from-player')));
    await tester.pump();

    expect(find.text('Fullscreen player'), findsNothing);
    expect(find.text('Caller count: 0'), findsOneWidget);
    expect(router.canPop(), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('direct player return also clears its popup before going home', (
    tester,
  ) async {
    late BuildContext playerContext;
    final router = _router(
      initialLocation: '/player',
      onPlayerContext: (context) => playerContext = context,
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pump();
    await tester.tap(find.byKey(const Key('open-player-dialog')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    FullscreenReturnNavigation.returnToCaller(playerContext);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Player popup menu'), findsNothing);
    expect(find.text('Fullscreen player'), findsNothing);
    expect(find.text('Caller count: 0'), findsOneWidget);
    expect(router.canPop(), isFalse);
    expect(tester.takeException(), isNull);
  });
}
