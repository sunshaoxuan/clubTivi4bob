import 'dart:async';

import 'package:clubtivi/data/datasources/local/database.dart' as db;
import 'package:clubtivi/features/channels/channel_programme_preview.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 10, 3, 12);

  db.EpgProgramme programme(String title, {String channel = 'CCTV6'}) =>
      db.EpgProgramme(
        id: 1,
        epgChannelId: channel,
        sourceId: 'guide',
        title: title,
        start: now,
        stop: now.add(const Duration(hours: 1)),
      );

  test('selects by channel ID and clears old programmes immediately', () async {
    final second = Completer<List<db.EpgProgramme>>();
    final preview = ChannelProgrammePreview(
      load: (epgId, at, limit) =>
          epgId == 'CCTV6' ? Future.value([programme('Film')]) : second.future,
      clock: () => now,
    );
    addTearDown(preview.dispose);
    await preview.select(channelId: 'film-id', epgChannelId: 'CCTV6');
    expect(preview.programmes.single.title, 'Film');

    final request = preview.select(channelId: 'news-id', epgChannelId: 'CCTV1');
    expect(preview.selectedChannelId, 'news-id');
    expect(preview.programmes, isEmpty);
    expect(preview.loading, isTrue);
    second.complete([programme('News', channel: 'CCTV1')]);
    await request;
    expect(preview.programmes.single.title, 'News');
    expect(preview.loading, isFalse);
  });

  test('ignores the late result of an earlier channel selection', () async {
    final first = Completer<List<db.EpgProgramme>>();
    final second = Completer<List<db.EpgProgramme>>();
    final preview = ChannelProgrammePreview(
      load: (epgId, at, limit) =>
          epgId == 'CCTV6' ? first.future : second.future,
      clock: () => now,
    );
    addTearDown(preview.dispose);
    final oldRequest = preview.select(
      channelId: 'film-id',
      epgChannelId: 'CCTV6',
    );
    final newRequest = preview.select(
      channelId: 'news-id',
      epgChannelId: 'CCTV1',
    );
    second.complete([programme('News', channel: 'CCTV1')]);
    await newRequest;
    first.complete([programme('Film')]);
    await oldRequest;
    expect(preview.selectedChannelId, 'news-id');
    expect(preview.programmes.single.title, 'News');
  });

  test('missing EPG mapping clears the strip without loading', () async {
    var calls = 0;
    final preview = ChannelProgrammePreview(
      load: (epgId, at, limit) async {
        calls++;
        return [programme('Film')];
      },
      clock: () => now,
    );
    addTearDown(preview.dispose);
    await preview.select(channelId: 'film-id', epgChannelId: 'CCTV6');
    await preview.select(channelId: 'unknown-id', epgChannelId: null);
    expect(calls, 1);
    expect(preview.selectedChannelId, 'unknown-id');
    expect(preview.programmes, isEmpty);
    expect(preview.loading, isFalse);
    await preview.select(channelId: 'blank-id', epgChannelId: '  ');
    expect(calls, 1);
  });

  test(
    'mapping changes on the same channel invalidate an earlier query',
    () async {
      final oldMapping = Completer<List<db.EpgProgramme>>();
      final preview = ChannelProgrammePreview(
        load: (epgId, at, limit) => epgId == 'old-mapping'
            ? oldMapping.future
            : Future.value([programme('Correct film')]),
        clock: () => now,
      );
      addTearDown(preview.dispose);
      final oldRequest = preview.select(
        channelId: 'film-id',
        epgChannelId: 'old-mapping',
      );
      await preview.select(channelId: 'film-id', epgChannelId: 'CCTV6');
      oldMapping.complete([programme('Wrong guide')]);
      await oldRequest;
      expect(preview.selectedChannelId, 'film-id');
      expect(preview.programmes.single.title, 'Correct film');
    },
  );

  test(
    'forced refresh wins over an outstanding query for the same choice',
    () async {
      final firstResponse = Completer<List<db.EpgProgramme>>();
      var calls = 0;
      final preview = ChannelProgrammePreview(
        load: (epgId, at, limit) => ++calls == 1
            ? firstResponse.future
            : Future.value([programme('Refreshed film')]),
        clock: () => now,
      );
      addTearDown(preview.dispose);
      final oldRequest = preview.select(
        channelId: 'film-id',
        epgChannelId: 'CCTV6',
      );
      await preview.select(
        channelId: 'film-id',
        epgChannelId: 'CCTV6',
        forceRefresh: true,
      );
      firstResponse.complete([programme('Old film')]);
      await oldRequest;
      expect(calls, 2);
      expect(preview.programmes.single.title, 'Refreshed film');
      expect(preview.loading, isFalse);
    },
  );

  test('negative timeshift queries the later guide time', () async {
    DateTime? queriedAt;
    final preview = ChannelProgrammePreview(
      load: (epgId, at, limit) async {
        queriedAt = at;
        return [];
      },
      clock: () => now,
    );
    addTearDown(preview.dispose);
    await preview.select(
      channelId: 'film-id',
      epgChannelId: 'CCTV6',
      timeshiftHours: -2,
    );
    expect(queriedAt, now.add(const Duration(hours: 2)));
  });

  test(
    'applies the guide timeshift and requests only three programmes',
    () async {
      DateTime? queriedAt;
      int? queriedLimit;
      final preview = ChannelProgrammePreview(
        load: (epgId, at, limit) async {
          queriedAt = at;
          queriedLimit = limit;
          return [];
        },
        clock: () => now,
      );
      addTearDown(preview.dispose);
      await preview.select(
        channelId: 'film-id',
        epgChannelId: 'CCTV6',
        timeshiftHours: 2,
      );
      expect(preview.timeshiftHours, 2);
      expect(queriedAt, now.subtract(const Duration(hours: 2)));
      expect(queriedLimit, 3);
    },
  );

  test(
    'coalesces pending queries and caches the same choice for 60 seconds',
    () async {
      var currentTime = now;
      var calls = 0;
      final response = Completer<List<db.EpgProgramme>>();
      final preview = ChannelProgrammePreview(
        load: (epgId, at, limit) {
          calls++;
          return calls == 1 ? response.future : Future.value([]);
        },
        clock: () => currentTime,
      );
      addTearDown(preview.dispose);
      final first = preview.select(channelId: 'film-id', epgChannelId: 'CCTV6');
      final duplicate = preview.select(
        channelId: 'film-id',
        epgChannelId: 'CCTV6',
      );
      expect(identical(first, duplicate), isTrue);
      expect(calls, 1);
      response.complete([]);
      await first;
      currentTime = now.add(const Duration(seconds: 59));
      await preview.select(channelId: 'film-id', epgChannelId: 'CCTV6');
      expect(calls, 1);
      currentTime = now.add(const Duration(seconds: 60));
      await preview.select(channelId: 'film-id', epgChannelId: 'CCTV6');
      expect(calls, 2);
      await preview.select(
        channelId: 'film-id',
        epgChannelId: 'CCTV6',
        forceRefresh: true,
      );
      expect(calls, 3);
      await preview.select(
        channelId: 'film-id',
        epgChannelId: 'CCTV6',
        timeshiftHours: 1,
      );
      expect(calls, 4);
    },
  );

  test('errors leave the strip empty and report diagnostics safely', () async {
    final failure = StateError('Guide unavailable');
    Object? reported;
    final preview = ChannelProgrammePreview(
      load: (epgId, at, limit) => Future.error(failure),
      onError: (error, stackTrace) => reported = error,
      clock: () => now,
    );
    addTearDown(preview.dispose);
    await preview.select(channelId: 'film-id', epgChannelId: 'CCTV6');
    expect(reported, same(failure));
    expect(preview.programmes, isEmpty);
    expect(preview.loading, isFalse);
  });

  test('clear invalidates outstanding results and resets selection', () async {
    final response = Completer<List<db.EpgProgramme>>();
    final preview = ChannelProgrammePreview(
      load: (epgId, at, limit) => response.future,
      clock: () => now,
    );
    addTearDown(preview.dispose);
    final request = preview.select(channelId: 'film-id', epgChannelId: 'CCTV6');
    preview.clear();
    response.complete([programme('Film')]);
    await request;
    expect(preview.selectedChannelId, isNull);
    expect(preview.programmes, isEmpty);
    expect(preview.loading, isFalse);
  });

  test(
    'dispose prevents notifications and errors from outstanding requests',
    () async {
      final response = Completer<List<db.EpgProgramme>>();
      var notifications = 0;
      var errors = 0;
      final preview = ChannelProgrammePreview(
        load: (epgId, at, limit) => response.future,
        onError: (error, stackTrace) => errors++,
        clock: () => now,
      )..addListener(() => notifications++);
      final request = preview.select(
        channelId: 'film-id',
        epgChannelId: 'CCTV6',
      );
      expect(notifications, 1);
      preview.dispose();
      response.completeError(StateError('Late failure'));
      await request;
      await preview.select(channelId: 'news-id', epgChannelId: 'CCTV1');
      expect(notifications, 1);
      expect(errors, 0);
    },
  );
}
