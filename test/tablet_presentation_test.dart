import 'package:clubtivi/core/tablet_presentation.dart';
import 'package:clubtivi/core/windows_binary_architecture.dart';
import 'package:clubtivi/data/services/update_manifest.dart';
import 'package:clubtivi/features/channels/adaptive_home_toolbar.dart';
import 'package:clubtivi/features/channels/channel_card_feedback.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'package:clubtivi/data/services/apk_download_policy.dart';
import 'package:clubtivi/core/playback_memory_budget.dart';

void main() {
  test('tablet buffers are bounded while desktop buffers remain unchanged', () {
    const tablet = PlaybackMemoryBudget(tablet: true);
    const desktop = PlaybackMemoryBudget(tablet: false);
    expect(tablet.main, 48 * 1024 * 1024);
    expect(tablet.preview, 24 * 1024 * 1024);
    expect(tablet.discovery, 12 * 1024 * 1024);
    expect(tablet.warm, 16 * 1024 * 1024);
    expect(desktop.main, 96 * 1024 * 1024);
    expect(desktop.preview, 48 * 1024 * 1024);
  });
  test('tablet homes share simple mode, rotation does not imply TV', () {
    expect(
      TabletPresentation.useSimpleHome(simpleMode: true, television: false),
      isTrue,
    );
    expect(
      TabletPresentation.useSimpleHome(simpleMode: true, television: true),
      isFalse,
    );
    expect(TabletPresentation.videoFit, BoxFit.contain);
    for (final size in [
      const Size(1280, 800),
      const Size(1024, 768),
      const Size(960, 640),
      const Size(800, 600),
      const Size(640, 480),
      const Size(800, 1280),
      const Size(1920, 1080),
    ]) {
      expect(
        TabletPresentation.splitLayout(width: size.width, height: size.height),
        isTrue,
      );
    }
    for (final size in [const Size(600, 960), const Size(480, 800)]) {
      expect(
        TabletPresentation.splitLayout(width: size.width, height: size.height),
        isFalse,
      );
      expect(
        TabletPresentation.previewHeight(size.height),
        lessThan(size.height * .5),
      );
    }
  });
  for (final width in [360.0, 600.0, 800.0, 1024.0, 1280.0]) {
    testWidgets('toolbar wraps without overflow at $width dp', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: AdaptiveHomeToolbar(
                  brand: const SizedBox(
                    width: 200,
                    height: 40,
                    child: Text('BobTV'),
                  ),
                  actions: [
                    TextButton(onPressed: () {}, child: const Text('进阶模式')),
                    IconButton(
                      onPressed: () {},
                      icon: const Icon(Icons.refresh),
                    ),
                    IconButton(
                      onPressed: () {},
                      icon: const Icon(Icons.settings),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('long press opens menu without selecting or force-playing card', (
    tester,
  ) async {
    var clicks = 0;
    var forced = 0;
    var menus = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 240,
            height: 160,
            child: ChannelCardFeedback(
              loading: false,
              onTap: () async {
                clicks++;
              },
              onDoubleTap: () async {
                forced++;
              },
              onContextMenu: (_) {
                menus++;
              },
              builder: (_) => const ColoredBox(color: Colors.blue),
            ),
          ),
        ),
      ),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(ChannelCardFeedback)),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.up();
    await tester.pump();
    expect(menus, 1);
    expect(clicks, 0);
    expect(forced, 0);
  });
  for (final width in [480.0, 640.0, 800.0, 1280.0]) {
    testWidgets('compact toolbar actions align to the right at $width dp', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: AdaptiveHomeToolbar(
                  compact: true,
                  brand: const SizedBox(width: 160, child: Text('BobTV')),
                  actions: const [
                    SizedBox(width: 100, height: 40),
                    SizedBox(width: 100, height: 40),
                    SizedBox(
                      key: ValueKey('last-toolbar-action'),
                      width: 48,
                      height: 40,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(
        tester.getRect(find.byKey(const ValueKey('last-toolbar-action'))).right,
        closeTo(width, .01),
      );
    });
  }
  test('PE architecture selects native ARM64 or emulated x64 correctly', () {
    Uint8List header(int machine) {
      final bytes = Uint8List(256);
      final data = ByteData.sublistView(bytes);
      bytes[0] = 0x4d;
      bytes[1] = 0x5a;
      data.setUint32(60, 128, Endian.little);
      data.setUint32(128, 0x4550, Endian.little);
      data.setUint16(132, machine, Endian.little);
      return bytes;
    }

    expect(WindowsBinaryArchitecture.fromHeader(header(0xaa64)), 'arm64');
    expect(WindowsBinaryArchitecture.fromHeader(header(0x8664)), 'x64');
    expect(
      () => WindowsBinaryArchitecture.fromHeader(header(0x14c)),
      throwsFormatException,
    );
    expect(
      () => WindowsBinaryArchitecture.fromHeader(Uint8List(20)),
      throwsFormatException,
    );
    final invalid = header(0xaa64);
    ByteData.sublistView(invalid).setUint32(60, 0xffffffff, Endian.little);
    expect(
      () => WindowsBinaryArchitecture.fromHeader(invalid),
      throwsFormatException,
    );
  });
  test('APK resume accepts only the requested complete suffix', () {
    int offset(int status, String? range, int length) =>
        ApkDownloadPolicy.initialOffset(
          statusCode: status,
          contentRange: range,
          requestedOffset: 400,
          totalBytes: 1000,
          contentLength: length,
        );
    expect(offset(206, 'bytes 400-999/1000', 600), 400);
    expect(offset(200, null, 1000), 0);
    expect(offset(200, null, -1), 0);
    for (final range in [
      'bytes 0-999/1000',
      'bytes 400-800/1000',
      'bytes 400-999/2000',
      'bytes 400-999/*',
      null,
    ]) {
      expect(() => offset(206, range, 600), throwsFormatException);
    }
    expect(() => offset(302, null, 600), throwsFormatException);
    expect(() => offset(200, null, 600), throwsFormatException);
    expect(() => offset(206, 'bytes 400-999/1000', 500), throwsFormatException);
  });
  test(
    'APK feeds are pinned to HTTPS mirror and cannot be ZIPs or external hosts',
    () {
      final uri = Uri.parse(
        'https://bobtv.briconbric.com/updates/android-arm64/latest.json',
      );
      String body(String archive) => jsonEncode({
        'schema': 1,
        'version': '1.1.0+93',
        'archive': archive,
        'sha256': 'a' * 64,
        'bytes': 1000001,
      });
      final good = body(
        'https://bobtv.briconbric.com/updates/files/BobTV-1.1.0+93-android-arm64.apk',
      );
      expect(
        UpdateManifest.parse(good, uri, extension: '.apk').version,
        '1.1.0+93',
      );
      expect(() => UpdateManifest.parse(good, uri), throwsFormatException);
      expect(
        () => UpdateManifest.parse(
          body('https://github.com/test.apk'),
          uri,
          extension: '.apk',
        ),
        throwsFormatException,
      );
      expect(
        () => UpdateManifest.parse(
          body('http://bobtv.briconbric.com/updates/test.apk'),
          uri,
          extension: '.apk',
        ),
        throwsFormatException,
      );
    },
  );
}
