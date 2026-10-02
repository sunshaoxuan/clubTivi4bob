import 'package:clubtivi/features/channels/inline_expanded_channel_grid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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
