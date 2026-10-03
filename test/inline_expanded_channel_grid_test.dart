import 'dart:io';
import 'dart:math' as math;

import 'package:clubtivi/features/channels/inline_expanded_channel_grid.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void expectSmoothJoin(Path path, Offset point, Offset direction) {
  final metric = path.computeMetrics().single;
  final step = metric.length / 160;
  var closest = 0.0;
  var distance = double.infinity;
  for (var offset = 0.0; offset < metric.length; offset += step) {
    final candidate =
        (metric.getTangentForOffset(offset)!.position - point).distanceSquared;
    if (candidate < distance) {
      distance = candidate;
      closest = offset;
    }
  }
  var low = math.max(0.0, closest - step);
  var high = math.min(metric.length, closest + step);
  for (var iteration = 0; iteration < 40; iteration++) {
    final a = low + (high - low) / 3;
    final b = high - (high - low) / 3;
    final da =
        (metric.getTangentForOffset(a)!.position - point).distanceSquared;
    final db =
        (metric.getTangentForOffset(b)!.position - point).distanceSquared;
    if (da < db) {
      high = b;
    } else {
      low = a;
    }
  }
  final join = (low + high) / 2;
  expect(
    (metric.getTangentForOffset(join)!.position - point).distance,
    lessThan(.01),
    reason: 'boundary reaches $point',
  );
  final before = metric.getTangentForOffset(join - .02)!.vector;
  final after = metric.getTangentForOffset(join + .02)!.vector;
  double dot(Offset a, Offset b) => a.dx * b.dx + a.dy * b.dy;
  expect(
    dot(before, after),
    greaterThan(.999),
    reason: 'continuous tangent at $point',
  );
  expect(
    dot(before, direction),
    greaterThan(.999),
    reason: 'incoming tangent at $point',
  );
  expect(
    dot(after, direction),
    greaterThan(.999),
    reason: 'outgoing tangent at $point',
  );
}

Widget grid(
  List<String> ids, {
  String? selected,
  int columns = 2,
  double width = 560,
  void Function(int)? onBuild,
}) => MaterialApp(
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: width,
        height: 550,
        child: InlineExpandedChannelGrid(
          channelIds: ids,
          columns: columns,
          expandedChannelId: selected,
          expandedContent: selected == null
              ? null
              : SizedBox(height: 100, child: Text('节目单 $selected')),
          cardBuilder: (_, index) {
            onBuild?.call(index);
            return Text(ids[index]);
          },
        ),
      ),
    ),
  ),
);

void main() {
  for (var columns = 1; columns <= 5; columns++) {
    for (var selected = 0; selected < columns; selected++) {
      test(
        '$columns columns, position $selected: straight edges and smooth shoulders',
        () {
          for (final width in [260.0, 560.0, 790.0, 1000.0, 1600.0]) {
            final cardWidth = (width - (columns - 1) * 14) / columns;
            final left = selected * (cardWidth + 14) + 1;
            final right = left + cardWidth - 2;
            final painter = ChannelGuideOutline(
              column: selected,
              columns: columns,
            );
            for (final height in [187.0, 196.0, 204.0, 240.0, 380.0, 540.0]) {
              final path = painter.outline(Size(width, height));
              expect(path.computeMetrics().length, 1);
              expect(path.getBounds().left, closeTo(1, .001));
              expect(path.getBounds().right, closeTo(width - 1, .001));
              expect(path.getBounds().bottom, closeTo(height - 1, .001));
              for (var column = 0; column < columns; column++) {
                expect(
                  path.contains(
                    Offset(column * (cardWidth + 14) + cardWidth / 2, 80),
                  ),
                  column == selected,
                );
              }
              if (selected == 0) {
                for (var y = 150.0; y <= 184; y++) {
                  expect(path.contains(Offset(1.2, y)), isTrue);
                  expect(path.contains(Offset(.8, y)), isFalse);
                }
              } else {
                expect(path.contains(Offset(left - .5, 178)), isTrue);
                expect(path.contains(Offset(left - 4, 178)), isFalse);
                expect(path.contains(Offset(left - 4, 183)), isTrue);
                expect(path.contains(Offset(left - 10, 183)), isFalse);
              }
              if (selected == columns - 1) {
                for (var y = 150.0; y <= 184; y++) {
                  expect(path.contains(Offset(width - 1.2, y)), isTrue);
                  expect(path.contains(Offset(width - .8, y)), isFalse);
                }
              } else {
                expect(path.contains(Offset(right + .5, 178)), isTrue);
                expect(path.contains(Offset(right + 4, 178)), isFalse);
                expect(path.contains(Offset(right + 4, 183)), isTrue);
                expect(path.contains(Offset(right + 10, 183)), isFalse);
              }
            }
            final path = painter.outline(Size(width, 380));
            if (selected == 0) {
              expectSmoothJoin(path, const Offset(1, 184), const Offset(0, -1));
            } else {
              expectSmoothJoin(path, Offset(left, 172), const Offset(0, -1));
              expectSmoothJoin(
                path,
                Offset(left - 12, 184),
                const Offset(1, 0),
              );
            }
            if (selected == columns - 1) {
              expectSmoothJoin(path, Offset(right, 184), const Offset(0, 1));
            } else {
              expectSmoothJoin(path, Offset(right, 172), const Offset(0, 1));
              expectSmoothJoin(
                path,
                Offset(right + 12, 184),
                const Offset(1, 0),
              );
            }
          }
        },
      );
    }
  }

  test('all positions remain mirror-symmetric during guide expansion', () {
    for (var columns = 1; columns <= 5; columns++) {
      for (var selected = 0; selected < columns; selected++) {
        for (final height in [
          172.0,
          180.0,
          184.0,
          186.0,
          186.1,
          187.0,
          196.0,
          204.0,
          380.0,
        ]) {
          final path = ChannelGuideOutline(
            column: selected,
            columns: columns,
          ).outline(Size(790, height));
          final mirrored = ChannelGuideOutline(
            column: columns - 1 - selected,
            columns: columns,
          ).outline(Size(790, height));
          for (var x = 3.3; x < 790; x += 11.7) {
            for (var y = 150.3; y < math.min(height - 1, 213); y += 2.7) {
              expect(
                path.contains(Offset(x, y)),
                mirrored.contains(Offset(790 - x, y)),
                reason:
                    '$columns columns, position $selected, height $height, ($x, $y)',
              );
            }
          }
        }
      }
    }
  });

  testWidgets(
    'every grid position and incomplete final row survives animation',
    (tester) async {
      for (var columns = 1; columns <= 5; columns++) {
        final ids = List.generate(columns * 2 + 1, (index) => 'channel-$index');
        for (var selected = 0; selected < ids.length; selected++) {
          await tester.pumpWidget(
            grid(ids, columns: columns, selected: ids[selected]),
          );
          for (final milliseconds in [16, 55, 110, 220]) {
            await tester.pump(Duration(milliseconds: milliseconds));
            final frame = find.byWidgetPredicate(
              (widget) =>
                  widget is CustomPaint &&
                  widget.painter is ChannelGuideOutline,
            );
            expect(frame, findsOneWidget);
            final paint = tester.widget<CustomPaint>(frame);
            final painter = paint.painter! as ChannelGuideOutline;
            final size = tester.getSize(frame);
            expect(painter.column, selected % columns);
            expect(painter.columns, columns);
            final path = painter.outline(size);
            expect(path.computeMetrics().length, 1);
            expect(path.getBounds().bottom, lessThanOrEqualTo(size.height));
            expect(path.getBounds().right, lessThanOrEqualTo(size.width));
            expect(
              tester.takeException(),
              isNull,
              reason: '$columns columns, index $selected, frame $milliseconds',
            );
          }
        }
      }
    },
  );

  testWidgets(
    'renders all fifteen outline positions for visual inspection',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1160);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        final loader = FontLoader('BobTVOutlinePreview');
        loader.addFont(
          Future.value(
            ByteData.sublistView(
              await File(
                '/System/Library/Fonts/STHeiti Light.ttc',
              ).readAsBytes(),
            ),
          ),
        );
        await loader.load();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RepaintBoundary(
              key: const ValueKey('outline-matrix'),
              child: ColoredBox(
                color: const Color(0xFF090F19),
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      for (var columns = 1; columns <= 5; columns++)
                        for (var selected = 0; selected < columns; selected++)
                          SizedBox(
                            width: 380,
                            height: 212,
                            child: Column(
                              children: [
                                Text(
                                  '$columns 列 · 第 ${selected + 1} 张',
                                  style: const TextStyle(
                                    fontFamily: 'BobTVOutlinePreview',
                                    fontSize: 18,
                                    color: Colors.white,
                                  ),
                                ),
                                const SizedBox(height: 10),
                                Expanded(
                                  child: FittedBox(
                                    child: SizedBox(
                                      width: 600,
                                      height: 300,
                                      child: CustomPaint(
                                        painter: ChannelGuideOutline(
                                          column: selected,
                                          columns: columns,
                                        ),
                                        foregroundPainter: ChannelGuideOutline(
                                          column: selected,
                                          columns: columns,
                                          foreground: true,
                                        ),
                                        child: Column(
                                          children: [
                                            Row(
                                              children: [
                                                for (
                                                  var card = 0;
                                                  card < columns;
                                                  card++
                                                ) ...[
                                                  if (card > 0)
                                                    const SizedBox(width: 14),
                                                  Expanded(
                                                    child: Container(
                                                      height: 172,
                                                      decoration: BoxDecoration(
                                                        color: card == selected
                                                            ? const Color(
                                                                0xFF304861,
                                                              )
                                                            : const Color(
                                                                0xFF1B293A,
                                                              ),
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              20,
                                                            ),
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ],
                                            ),
                                            const SizedBox(height: 42),
                                            const Divider(
                                              indent: 20,
                                              endIndent: 20,
                                              color: Color(0xFF7598C5),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await expectLater(
        find.byKey(const ValueKey('outline-matrix')),
        matchesGoldenFile('/tmp/bobtv-outline-all-positions.png'),
      );
    },
    skip: !const bool.fromEnvironment('BOBTV_OUTLINE_PREVIEW'),
  );

  test('left outside edge stays straight through the card-guide join', () {
    final path = const ChannelGuideOutline(
      column: 0,
      columns: 2,
    ).outline(const Size(1000, 380));
    for (var y = 150.0; y <= 215; y += 1) {
      expect(path.contains(Offset(1.2, y)), isTrue, reason: 'join at $y');
      expect(path.contains(Offset(.8, y)), isFalse);
    }
    expect(path.computeMetrics().length, 1);
  });

  test('inset edge joins the guide with a rounded concave shoulder', () {
    final path = const ChannelGuideOutline(
      column: 0,
      columns: 2,
    ).outline(const Size(1000, 380));
    const right = 492.0;
    expect(path.contains(const Offset(right + .5, 178)), isTrue);
    expect(path.contains(const Offset(right + 4, 178)), isFalse);
    expect(path.contains(const Offset(right + 4, 183)), isTrue);
    expect(path.contains(const Offset(right + 10, 183)), isFalse);
    expect(path.contains(const Offset(right + 12, 185)), isTrue);
  });

  test('connected outline excludes every neighbouring channel', () {
    for (var columns = 1; columns <= 5; columns++) {
      for (var selected = 0; selected < columns; selected++) {
        final painter = ChannelGuideOutline(column: selected, columns: columns);
        final path = painter.outline(const Size(1000, 380));
        final cardWidth = (1000 - (columns - 1) * 14) / columns;
        for (var column = 0; column < columns; column++) {
          expect(
            path.contains(
              Offset(column * (cardWidth + 14) + cardWidth / 2, 80),
            ),
            column == selected,
          );
        }
        expect(path.contains(const Offset(20, 260)), isTrue);
        expect(path.contains(const Offset(980, 260)), isTrue);
        final animating = painter.outline(const Size(1000, 172));
        expect(animating.getBounds().bottom, lessThanOrEqualTo(172));
      }
    }
  });

  testWidgets('guide expands below the selected card row', (tester) async {
    await tester.pumpWidget(
      grid(['CCTV1', 'CCTV6', 'CCTV9'], selected: 'CCTV6'),
    );
    expect(
      tester.getTopLeft(find.text('节目单 CCTV6')).dy,
      greaterThan(tester.getTopLeft(find.text('CCTV6')).dy),
    );
    expect(
      tester.getTopLeft(find.text('CCTV9')).dy,
      greaterThan(tester.getBottomLeft(find.text('节目单 CCTV6')).dy),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('scan insertion keeps the guide attached to the channel ID', (
    tester,
  ) async {
    await tester.pumpWidget(
      grid(['CCTV1', 'CCTV6', 'CCTV9'], selected: 'CCTV6'),
    );
    await tester.pumpWidget(
      grid(['CCTV1', 'CCTV2', 'CCTV6', 'CCTV9'], selected: 'CCTV6'),
    );
    await tester.pump(const Duration(milliseconds: 250));
    final selectedTop = tester.getTopLeft(find.text('CCTV6')).dy;
    final precedingTop = tester.getTopLeft(find.text('CCTV1')).dy;
    final guideTop = tester.getTopLeft(find.text('节目单 CCTV6')).dy;
    expect(guideTop, greaterThan(selectedTop + 172));
    expect(selectedTop, greaterThan(precedingTop));
    expect(find.text('节目单 CCTV1'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('filtered-out selection leaves no misplaced guide', (
    tester,
  ) async {
    await tester.pumpWidget(grid(['CCTV1', 'CCTV2'], selected: 'CCTV6'));
    expect(find.text('节目单 CCTV6'), findsNothing);
  });

  testWidgets('narrow single-column layout has no overflow', (tester) async {
    await tester.pumpWidget(
      grid(['CCTV1', 'CCTV6'], selected: 'CCTV6', columns: 1, width: 260),
    );
    expect(find.text('节目单 CCTV6'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('large channel inventory is built lazily', (tester) async {
    var built = 0;
    await tester.pumpWidget(
      grid(List.generate(30000, (i) => '频道$i'), onBuild: (_) => built++),
    );
    expect(built, lessThan(40));
    expect(find.text('频道29999'), findsNothing);
  });
}
