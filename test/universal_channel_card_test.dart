import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/features/channels/channel_card_feedback.dart';
import 'package:clubtivi/features/channels/channel_programme_preview.dart';
import 'package:clubtivi/features/channels/channel_programme_strip.dart';
import 'package:clubtivi/features/channels/channel_programme_status.dart';
import 'package:clubtivi/features/channels/inline_expanded_channel_grid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2030, 1, 1, 12);
  testWidgets(
    'every card expands through the same resolver for public/private foreign guides and missing data',
    (tester) async {
      final ids = [
        'BBC One',
        'NHK World',
        '翡翠台',
        'Private playlist',
        'Unmatched',
        'Empty',
        'Retry',
      ];
      var retryFails = true;
      final preview = ChannelProgrammePreview(
        clock: () => now,
        resolve: (id, _) async => id == 'Unmatched' ? null : 'world_$id',
        load: (epg, at, limit) async {
          if (epg == 'world_Empty') return [];
          if (epg == 'world_Retry' && retryFails) throw StateError('temporary');
          return [
            db.EpgProgramme(
              id: 1,
              epgChannelId: epg,
              sourceId: 'world',
              title: 'Programme $epg',
              start: now,
              stop: now.add(const Duration(hours: 1)),
            ),
          ];
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AnimatedBuilder(
              animation: preview,
              builder: (context, _) => SizedBox(
                width: 900,
                height: 650,
                child: InlineExpandedChannelGrid(
                  columns: 3,
                  channelIds: ids,
                  cardHeight: 100,
                  expandedChannelId: preview.selectedChannelId,
                  expandedContent: preview.programmes.isNotEmpty
                      ? ChannelProgrammeStrip(
                          channelName: preview.selectedChannelId!,
                          programmes: preview.programmes,
                          now: now,
                          embedded: true,
                        )
                      : ChannelProgrammeStatus(
                          loading: preview.loading,
                          failed: preview.failed,
                          hasMapping: preview.hasMapping,
                        ),
                  cardBuilder: (context, index) => ChannelCardFeedback(
                    key: ValueKey(ids[index]),
                    loading: false,
                    onTap: () => preview.select(
                      channelId: ids[index],
                      epgChannelId: null,
                    ),
                    onDoubleTap: () async {},
                    builder: (_) => Center(child: Text(ids[index])),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      for (final id in ids) {
        await tester.ensureVisible(find.byKey(ValueKey(id)));
        await tester.tap(find.byKey(ValueKey(id)));
        await tester.pump();
        await tester.pumpAndSettle();
        expect(preview.selectedChannelId, id);
        if (id == 'Unmatched') {
          expect(find.text('暂无可用节目表'), findsOneWidget);
        } else if (id == 'Empty') {
          expect(find.text('当前暂无节目数据'), findsOneWidget);
        } else if (id == 'Retry') {
          expect(find.text('节目表暂时无法读取'), findsOneWidget);
        } else {
          expect(find.text('Programme world_$id'), findsOneWidget);
        }
      }
      retryFails = false;
      await tester.tap(find.byKey(const ValueKey('Retry')));
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.text('Programme world_Retry'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      preview.dispose();
    },
  );
}
