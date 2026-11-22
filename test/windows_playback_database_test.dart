import 'dart:async';
import 'dart:io';
import 'package:clubtivi/data/datasources/local/database.dart';
import 'package:clubtivi/data/services/sqlite_snapshot.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart' as sql;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const paths = MethodChannel('plugins.flutter.io/path_provider');

  test(
    'playback reads committed state during a held catalog transaction',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'bobtv-read-pool-',
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(paths, (_) async => directory.path);
      SharedPreferences.setMockInitialValues({});
      final database = AppDatabase(concurrentReads: true);
      final started = Completer<void>();
      final release = Completer<void>();
      Future<void>? writer;
      try {
        await database.customStatement(
          'CREATE TABLE playback_fixture(value TEXT)',
        );
        await database.customStatement(
          "INSERT INTO playback_fixture VALUES('committed')",
        );
        writer = database.transaction(() async {
          await database.customStatement(
            "UPDATE playback_fixture SET value='importing'",
          );
          started.complete();
          await release.future;
        });
        await started.future;
        final snapshot = await database
            .customSelect('SELECT value FROM playback_fixture')
            .getSingle()
            .timeout(const Duration(seconds: 1));
        expect(snapshot.read<String>('value'), 'committed');
        await database.getBlockedStreamUrls().timeout(
          const Duration(seconds: 1),
        );
        await database.sharedCatalogVersion().timeout(
          const Duration(seconds: 1),
        );
        release.complete();
        await writer;
        expect(
          (await database
                  .customSelect('SELECT value FROM playback_fixture')
                  .getSingle())
              .read<String>('value'),
          'importing',
        );
      } finally {
        if (!release.isCompleted) release.complete();
        await writer;
        await database.close().timeout(const Duration(seconds: 5));
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(paths, null);
        // Successful deletion also verifies both native connections released files.
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'backup and restore include committed WAL pages with an open destination',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'bobtv-wal-backup-',
      );
      final source = File('${directory.path}/source.db');
      final destination = File('${directory.path}/destination.db');
      final input = sql.sqlite3.open(source.path);
      final output = sql.sqlite3.open(destination.path);
      try {
        for (final connection in [input, output]) {
          connection.execute('PRAGMA journal_mode=WAL');
          connection.execute('PRAGMA wal_autocheckpoint=0');
          connection.execute('CREATE TABLE fixture(value TEXT)');
        }
        input.execute("INSERT INTO fixture VALUES('new committed data')");
        output.execute("INSERT INTO fixture VALUES('old WAL data')");
        expect(await File('${source.path}-wal').length(), greaterThan(0));
        await copySqliteSnapshot(source.path, destination.path);
        expect(
          output.select('SELECT value FROM fixture').single['value'],
          'new committed data',
        );
        expect(
          output.select('PRAGMA integrity_check').single.values.single,
          'ok',
        );
      } finally {
        input.dispose();
        output.dispose();
      }
      final reopened = sql.sqlite3.open(destination.path);
      try {
        expect(
          reopened.select('SELECT value FROM fixture').single['value'],
          'new committed data',
        );
      } finally {
        reopened.dispose();
        await directory.delete(recursive: true);
      }
    },
  );
}
