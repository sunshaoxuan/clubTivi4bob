// ignore_for_file: implementation_imports, depend_on_referenced_packages, invalid_use_of_visible_for_testing_member
// Development-only driver for the normal application. Uses a private copy of
// the Windows profile and real card gestures, streams, renderer and audio.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:file/file.dart' as fs;
import 'package:file/src/forwarding.dart';
import 'package:path_provider_windows/path_provider_windows.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_windows/shared_preferences_windows.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';
import 'package:clubtivi/core/app_diagnostics.dart';
import 'package:clubtivi/main.dart' as application;
import 'package:clubtivi/features/player/player_service.dart';

class _ObservedPaths extends PathProviderWindows {
  _ObservedPaths(this.original);
  final PathProviderWindows original;
  Future<String?>? cached;
  @override
  Future<String?> getApplicationSupportPath() async {
    final watch = Stopwatch()..start();
    final path = Platform.environment['BOBTV_HANDOFF_CACHE_PREF_PATH'] == '1'
        ? await (cached ??= original.getApplicationSupportPath())
        : await original.getApplicationSupportPath();
    AppDiagnostics.instance.log('preference_path', {
      'elapsedMs': watch.elapsedMilliseconds,
    });
    return path;
  }
}

class _ObservedFS extends ForwardingFileSystem {
  _ObservedFS(super.delegate);
  @override
  fs.File file(dynamic path) => _ObservedFile(delegate.file(path), this);
}

class _ObservedFile extends ForwardingFileSystemEntity<fs.File, File>
    with ForwardingFile
    implements fs.File {
  _ObservedFile(this.delegate, this.fileSystem);
  @override
  final File delegate;
  @override
  final fs.FileSystem fileSystem;
  @override
  fs.File wrapFile(File file) => _ObservedFile(file, fileSystem);
  @override
  fs.Directory wrapDirectory(Directory dir) => fileSystem.directory(dir.path);
  @override
  fs.Link wrapLink(Link link) => fileSystem.link(link.path);
  @override
  Future<fs.File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) async {
    final watch = Stopwatch()..start();
    await delegate.writeAsString(
      contents,
      mode: mode,
      encoding: encoding,
      flush: flush,
    );
    AppDiagnostics.instance.log('preference_file_write_async', {
      'elapsedMs': watch.elapsedMilliseconds,
      'characters': contents.length,
    });
    return this;
  }

  @override
  void writeAsStringSync(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) {
    _synchronousPreferenceWrites++;
    final watch = Stopwatch()..start();
    delegate.writeAsStringSync(
      contents,
      mode: mode,
      encoding: encoding,
      flush: flush,
    );
    AppDiagnostics.instance.log('preference_file_write', {
      'elapsedMs': watch.elapsedMilliseconds,
      'characters': contents.length,
    });
  }
}

int _synchronousPreferenceWrites = 0;
Stopwatch? _handoffWatch;

class _HandoffBinding extends WidgetsFlutterBinding {
  @override
  void drawFrame() {
    final watch = Stopwatch()..start();
    final elapsed = _handoffWatch?.elapsedMilliseconds;
    super.drawFrame();
    if (elapsed != null &&
        elapsed < 45000 &&
        (elapsed < 500 || watch.elapsedMilliseconds > 50)) {
      AppDiagnostics.instance.log('handoff_framework_frame', {
        'elapsedMs': elapsed,
        'frameMs': watch.elapsedMilliseconds,
      });
    }
  }
}

void main() {
  if (Platform.environment['BOBTV_TEST_MUTE'] != '1') {
    throw StateError('This diagnostic requires BOBTV_TEST_MUTE=1');
  }
  application.main(
    onBindingReady: () {
      _HandoffBinding();
      WidgetsBinding.instance.addTimingsCallback((frames) {
        for (final frame in frames) {
          if (frame.buildDuration.inMilliseconds > 100 ||
              frame.rasterDuration.inMilliseconds > 100) {
            AppDiagnostics.instance.log('handoff_slow_frame', {
              'buildMs': frame.buildDuration.inMilliseconds,
              'rasterMs': frame.rasterDuration.inMilliseconds,
            });
          }
        }
      });
      if (Platform.environment['BOBTV_HANDOFF_AUTORUN'] != '0') {
        Timer(const Duration(seconds: 20), () => unawaited(_drive()));
      } else {
        Timer(
          const Duration(seconds: 3),
          () => unawaited(windowManager.setTitle('BobTV 换台修复测试版')),
        );
      }
    },
  );
}

Future<void> _drive() async {
  final root = Directory(Platform.environment['BOBTV_HANDOFF_REPORT']!);
  root.createSync(recursive: true);
  final report = File('${root.path}/driver.jsonl');
  void record(String event, Map<String, Object?> fields) {
    report.writeAsStringSync(
      '${jsonEncode({'event': event, 'utc': DateTime.now().toUtc().toIso8601String(), 'pid': pid, ...fields})}\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  int pointer = 200;
  Element cardLabel(String label) {
    Element? found;
    void visit(Element element) {
      final widget = element.widget;
      if (widget is Text && widget.data == label) {
        final box = element.findRenderObject();
        if (box is RenderBox &&
            box.attached &&
            box.hasSize &&
            box.size.width > 0 &&
            box.size.height > 0) {
          final center = box.localToGlobal(box.size.center(Offset.zero));
          final size = MediaQuery.sizeOf(element);
          if (center.dx > size.width / 2 &&
              center.dy > 40 &&
              center.dy < size.height &&
              center.dx < size.width) {
            found = element;
          }
        }
      }
      element.visitChildElements(visit);
    }

    WidgetsBinding.instance.rootElement!.visitChildElements(visit);
    return found ??
        (throw StateError('Visible card label unavailable: $label'));
  }

  Future<void> tap(String label) async {
    final element = cardLabel(label);
    final box = element.findRenderObject()! as RenderBox;
    final point = box.localToGlobal(box.size.center(Offset.zero));
    final id = pointer++;
    GestureBinding.instance.handlePointerEvent(
      PointerDownEvent(
        pointer: id,
        position: point,
        kind: PointerDeviceKind.mouse,
        buttons: 1,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 25));
    GestureBinding.instance.handlePointerEvent(
      PointerUpEvent(
        pointer: id,
        position: point,
        kind: PointerDeviceKind.mouse,
      ),
    );
  }

  Future<void> until(bool Function() predicate, String description) async {
    final watch = Stopwatch()..start();
    while (!predicate()) {
      if (watch.elapsed > const Duration(seconds: 45)) {
        throw TimeoutException(description);
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }

  try {
    await windowManager.setTitle('BobTV real channel test $pid');
    await windowManager.maximize();
    if (Platform.environment['BOBTV_HANDOFF_BACKGROUND'] != '1') {
      await windowManager.setAlwaysOnTop(true);
      await windowManager.focus();
    }
    if (Platform.environment['BOBTV_HANDOFF_BACKGROUND'] == '1') {
      await windowManager.setAlwaysOnBottom(true);
      await windowManager.blur();
    }
    final preferences = SharedPreferencesStorePlatform.instance;
    if (preferences is SharedPreferencesWindows) {
      preferences.pathProvider = _ObservedPaths(preferences.pathProvider);
      preferences.fs = _ObservedFS(preferences.fs);
      if (Platform.environment['BOBTV_HANDOFF_CACHE_PREF_PATH'] == '1') {
        await preferences.pathProvider.getApplicationSupportPath();
      }
    }
    final service = ProviderScope.containerOf(
      cardLabel('Action Movies'),
      listen: false,
    ).read(playerServiceProvider);
    await until(
      () => service.currentUrl != null && service.player.state.playing,
      'Initial channel playback',
    );
    await service.setVolume(0);
    if (await service.getMpvProperty('mute') != 'yes') {
      throw StateError('Application mute was not applied');
    }
    record('started', {
      'applicationMuted': true,
      'normalApplication': true,
      'backgroundProfiling':
          Platform.environment['BOBTV_HANDOFF_BACKGROUND'] == '1',
    });
    final channels = List.generate(
      12,
      (i) => i.isEven ? 'Action Movies' : 'Comedy Movies',
    );
    final performanceFailures = <Map<String, Object?>>[];
    for (var cycle = 0; cycle < channels.length; cycle++) {
      final label = channels[cycle];
      final old = service.activeVideoController.value;
      if (cycle == 4 || cycle == 8) {
        await tap('Drama Movies');
        await Future<void>.delayed(const Duration(milliseconds: 200));
        record('cold_selection_cancelled', {'cycle': cycle});
      }
      final preparation = Stopwatch()..start();
      await tap(label);
      await until(
        () => service.previewVideoController.value != null,
        'Decoded preview: $label',
      );
      final preview = service.previewVideoController.value!;
      final id = service.preparedChannelId;
      await WidgetsBinding.instance.endOfFrame;
      await Future<void>.delayed(const Duration(milliseconds: 500));
      record('preview_ready', {
        'preparationMs': preparation.elapsedMilliseconds,
        'cycle': cycle,
        'channel': label,
        'volume': service.player.state.volume,
      });
      File('${root.path}/click-$cycle.json').writeAsStringSync(
        jsonEncode({
          'cycle': cycle,
          'utc': DateTime.now().toUtc().toIso8601String(),
          'channel': label,
        }),
        flush: true,
      );
      final watch = Stopwatch()..start();
      _handoffWatch = watch;
      var frameUs = -1;
      void published() {
        if (!identical(service.activeVideoController.value, preview)) return;
        service.activeVideoController.removeListener(published);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          frameUs = watch.elapsedMicroseconds;
        });
      }

      service.activeVideoController.addListener(published);
      await tap(label);
      await until(
        () =>
            !service.channelSwitching.value &&
            identical(service.activeVideoController.value, preview),
        'Preview promotion: $label',
      );
      final logicalUs = watch.elapsedMicroseconds;
      await WidgetsBinding.instance.endOfFrame;
      record('committed', {
        'cycle': cycle,
        'channel': label,
        'logicalUs': logicalUs,
        'firstFrameUs': frameUs,
        'sameController': identical(
          service.activeVideoController.value,
          preview,
        ),
        'changedController': !identical(old, preview),
        'previewDetached': service.previewVideoController.value == null,
        'preparedCleared': service.preparedChannelId != id,
        'volume': service.player.state.volume,
      });
      if (logicalUs > 500000 || frameUs < 0 || frameUs > 500000) {
        performanceFailures.add({
          'cycle': cycle,
          'logicalUs': logicalUs,
          'frameUs': frameUs,
        });
      }
      final position = service.player.state.position;
      final frameBefore = await service.player.screenshot();
      if (frameBefore != null) {
        await File(
          '${root.path}/video-$cycle-before.jpg',
        ).writeAsBytes(frameBefore);
      }
      final audioBefore = double.tryParse(
        await service.getMpvProperty('audio-pts') ?? '',
      );
      await Future<void>.delayed(const Duration(seconds: 4));
      final frameAfter = await service.player.screenshot();
      if (frameAfter != null) {
        await File(
          '${root.path}/video-$cycle-after.jpg',
        ).writeAsBytes(frameAfter);
      }
      final audioAfter = double.tryParse(
        await service.getMpvProperty('audio-pts') ?? '',
      );
      final audioOutput = await service.getMpvProperty('current-ao');
      final mute = await service.getMpvProperty('mute');
      final positionAdvance =
          (service.player.state.position - position).inMilliseconds;
      final videoChanged =
          frameBefore != null &&
          frameAfter != null &&
          sha256.convert(frameBefore) != sha256.convert(frameAfter);
      if (!videoChanged) {
        performanceFailures.add({
          'cycle': cycle,
          'kind': 'video_frame_unchanged',
        });
      }
      if (audioOutput != 'wasapi' || mute != 'yes' || positionAdvance < 500) {
        performanceFailures.add({
          'cycle': cycle,
          'kind': 'live_audio_progress',
          'audioOutput': audioOutput,
          'mute': mute,
          'positionAdvanceMs': positionAdvance,
        });
      }
      record('live_av_progress', {
        'cycle': cycle,
        'audioOutput': audioOutput,
        'mute': mute,
        'positionAdvanceMs': positionAdvance,
        'videoFrameChanged': videoChanged,
        'audioAdvanceSeconds': audioBefore != null && audioAfter != null
            ? audioAfter - audioBefore
            : null,
      });
      _handoffWatch = null;
    }
    await SharedPreferencesWindows.flushPendingWrites();
    final support = await (preferences as SharedPreferencesWindows).pathProvider
        .getApplicationSupportPath();
    final saved =
        jsonDecode(
              await File('$support/shared_preferences.json').readAsString(),
            )
            as Map;
    final savedChannel =
        saved['flutter.last_channel_id'] == service.currentChannelId;
    record('completed', {
      'passed':
          performanceFailures.isEmpty &&
          _synchronousPreferenceWrites == 0 &&
          savedChannel &&
          saved['flutter.bobtv.installation.registration_policy.v1'] ==
              'legacy',
      'performanceFailures': performanceFailures,
      'synchronousPreferenceWrites': _synchronousPreferenceWrites,
      'lastChannelPersisted': savedChannel,
      'registrationCohort':
          saved['flutter.bobtv.installation.registration_policy.v1'],
      'cycles': channels.length,
    });
  } catch (error, stack) {
    record('failed', {'error': error.toString(), 'stack': stack.toString()});
  } finally {
    await windowManager.setAlwaysOnTop(false);
  }
}
