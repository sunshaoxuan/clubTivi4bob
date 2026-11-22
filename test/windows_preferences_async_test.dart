// The Windows store is pure Dart. Controlled disk futures verify responsiveness
// and write ordering on every host without touching the user's preferences.
// ignore_for_file: implementation_imports, depend_on_referenced_packages, invalid_use_of_visible_for_testing_member
import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'package:file/file.dart' as fs;
import 'package:file/memory.dart';
import 'package:file/src/forwarding.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_windows/path_provider_windows.dart';
import 'package:shared_preferences_windows/shared_preferences_windows.dart';

class _Paths extends PathProviderWindows {
  @override
  Future<String?> getApplicationSupportPath() async =>
      io.Platform.isWindows ? r'C:\preferences' : '/preferences';
}

class _Write {
  _Write(this.contents);
  final String contents;
  final release = Completer<void>();
}

class _Disk extends ForwardingFileSystem {
  _Disk(this.memory) : super(memory);
  final MemoryFileSystem memory;
  final writes = <_Write>[];
  int syncWrites = 0;
  int renameFailures = 0;
  @override
  fs.File file(dynamic path) => _File(delegate.file(path), this);
}

class _File extends ForwardingFileSystemEntity<fs.File, io.File>
    with ForwardingFile
    implements fs.File {
  _File(this.delegate, this.disk);
  @override
  final io.File delegate;
  final _Disk disk;
  @override
  fs.FileSystem get fileSystem => disk;
  @override
  fs.File wrapFile(io.File file) => _File(file, disk);
  @override
  fs.Directory wrapDirectory(io.Directory dir) => disk.directory(dir.path);
  @override
  fs.Link wrapLink(io.Link link) => disk.link(link.path);
  @override
  void writeAsStringSync(
    String contents, {
    io.FileMode mode = io.FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) {
    disk.syncWrites++;
    throw StateError('Preferences must never write synchronously');
  }

  @override
  Future<fs.File> rename(String newPath) async {
    if (disk.renameFailures > 0) {
      disk.renameFailures--;
      throw const io.FileSystemException('fixture sharing lock');
    }
    return wrapFile(await delegate.rename(newPath));
  }

  @override
  Future<fs.File> writeAsString(
    String contents, {
    io.FileMode mode = io.FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) async {
    final write = _Write(contents);
    disk.writes.add(write);
    // Simulate an in-progress OS write exposing incomplete bytes at its target.
    await delegate.writeAsString('{"incomplete":');
    await write.release.future;
    await delegate.writeAsString(
      contents,
      mode: mode,
      encoding: encoding,
      flush: flush,
    );
    return this;
  }
}

String get _preferencesPath => io.Platform.isWindows
    ? r'C:\preferences\shared_preferences.json'
    : '/preferences/shared_preferences.json';

Future<void> _turn() => Future<void>.delayed(Duration.zero);
void main() {
  late _Disk disk;
  late SharedPreferencesWindows store;
  setUp(() async {
    disk = _Disk(
      MemoryFileSystem(
        style: io.Platform.isWindows
            ? FileSystemStyle.windows
            : FileSystemStyle.posix,
      ),
    );
    disk.memory.file(_preferencesPath)
      ..createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode({
          'flutter.registration_policy': 'legacy',
          'flutter.favorites': ['channel-a', 'channel-b'],
          'outside': 'preserve',
        }),
      );
    store = SharedPreferencesWindows()
      ..fs = disk
      ..pathProvider = _Paths();
    await store.getAll();
  });
  tearDown(() => SharedPreferencesWindows.flushPendingWrites());

  test(
    'slow disk leaves timers responsive and snapshots write in order',
    () async {
      final first = store.setValue('String', 'flutter.channel', 'one');
      final second = store.setValue('String', 'flutter.channel', 'two');
      var drained = false;
      final flush = SharedPreferencesWindows.flushPendingWrites().then(
        (_) => drained = true,
      );
      await _turn();
      expect(disk.writes, hasLength(1));
      final duringWrite = jsonDecode(
        disk.memory.file(_preferencesPath).readAsStringSync(),
      );
      expect(duringWrite['flutter.registration_policy'], 'legacy');
      expect(duringWrite.containsKey('flutter.channel'), isFalse);
      var timerRan = false;
      await Future<void>.delayed(
        const Duration(milliseconds: 20),
        () => timerRan = true,
      );
      expect(timerRan, isTrue);
      expect(drained, isFalse);
      expect(jsonDecode(disk.writes.first.contents)['flutter.channel'], 'one');
      disk.writes.first.release.complete();
      expect(await first, isTrue);
      await _turn();
      expect(disk.writes, hasLength(2));
      expect(jsonDecode(disk.writes.last.contents)['flutter.channel'], 'two');
      expect(drained, isFalse);
      disk.writes.last.release.complete();
      expect(await second, isTrue);
      await flush;
      expect(drained, isTrue);
      expect(disk.syncWrites, 0);
      final saved = jsonDecode(
        disk.memory.file(_preferencesPath).readAsStringSync(),
      );
      expect(saved['flutter.channel'], 'two');
      expect(saved['flutter.registration_policy'], 'legacy');
      expect(saved['flutter.favorites'], ['channel-a', 'channel-b']);
      expect(saved['outside'], 'preserve');
    },
  );

  test(
    'a failed write reports failure and later snapshots still persist',
    () async {
      final first = store.setValue('String', 'flutter.first', 'one');
      final second = store.setValue('String', 'flutter.second', 'two');
      await _turn();
      disk.writes.first.release.completeError(
        const io.FileSystemException('fixture disk failure'),
      );
      expect(await first, isFalse);
      final afterFailure = jsonDecode(
        disk.memory.file(_preferencesPath).readAsStringSync(),
      );
      expect(afterFailure['flutter.registration_policy'], 'legacy');
      expect(afterFailure.containsKey('flutter.first'), isFalse);
      await _turn();
      expect(disk.writes, hasLength(2));
      disk.writes.last.release.complete();
      expect(await second, isTrue);
      final saved = jsonDecode(
        disk.memory.file(_preferencesPath).readAsStringSync(),
      );
      expect(saved['flutter.first'], 'one');
      expect(saved['flutter.second'], 'two');
      expect(disk.syncWrites, 0);
    },
  );

  test(
    'a transient replacement lock retries without exposing a partial file',
    () async {
      disk.renameFailures = 1;
      final write = store.setValue('String', 'flutter.channel', 'one');
      await _turn();
      disk.writes.first.release.complete();
      expect(await write, isTrue);
      expect(disk.renameFailures, 0);
      final saved = jsonDecode(
        disk.memory.file(_preferencesPath).readAsStringSync(),
      );
      expect(saved['flutter.channel'], 'one');
      expect(saved['flutter.registration_policy'], 'legacy');
      expect(disk.syncWrites, 0);
    },
  );

  test('clear after a queued mutation never restores removed keys', () async {
    final first = store.setValue('String', 'flutter.channel', 'one');
    final cleared = store.clear();
    await _turn();
    disk.writes.first.release.complete();
    expect(await first, isTrue);
    await _turn();
    disk.writes.last.release.complete();
    expect(await cleared, isTrue);
    final saved = jsonDecode(
      disk.memory.file(_preferencesPath).readAsStringSync(),
    );
    expect(saved, {'outside': 'preserve'});
    expect(disk.syncWrites, 0);
  });
}
