import 'dart:isolate';
import 'package:sqlite3/sqlite3.dart';

/// Copies a consistent, committed SQLite snapshot, including active WAL pages.
/// Both connections and their cleanup belong to the background isolate.
Future<void> copySqliteSnapshot(String source, String destination) =>
    Isolate.run(() async {
      final input = sqlite3.open(source, mode: OpenMode.readOnly);
      try {
        final output = sqlite3.open(destination);
        try {
          output.execute('PRAGMA busy_timeout=30000');
          await input.backup(output).drain<void>();
        } finally {
          output.dispose();
        }
      } finally {
        input.dispose();
      }
    });
