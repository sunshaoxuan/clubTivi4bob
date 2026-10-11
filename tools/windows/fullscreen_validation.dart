// Isolated Windows native-window regression. No catalogue, player or updater.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'package:clubtivi/app/windows_fullscreen_controls.dart';
import 'package:clubtivi/features/player/desktop_fullscreen_session.dart';
import 'package:clubtivi/features/player/window_manager_fullscreen_backend.dart';
import 'package:clubtivi/features/player/window_manager_pip_backend.dart';
import 'package:clubtivi/features/player/windows_window_chrome.dart';

final class NativeRect extends Struct {
  @Int32()
  external int left;
  @Int32()
  external int top;
  @Int32()
  external int right;
  @Int32()
  external int bottom;
}

final class NativePoint extends Struct {
  @Int32()
  external int x;
  @Int32()
  external int y;
}

class NativeWindow {
  NativeWindow() {
    final user32 = DynamicLibrary.open('user32.dll');
    findWindow = user32
        .lookupFunction<
          IntPtr Function(Pointer<Utf16>, Pointer<Utf16>),
          int Function(Pointer<Utf16>, Pointer<Utf16>)
        >('FindWindowW');
    getRect = user32
        .lookupFunction<
          Int32 Function(IntPtr, Pointer<NativeRect>),
          int Function(int, Pointer<NativeRect>)
        >('GetWindowRect');
    getClient = user32
        .lookupFunction<
          Int32 Function(IntPtr, Pointer<NativeRect>),
          int Function(int, Pointer<NativeRect>)
        >('GetClientRect');
    toScreen = user32
        .lookupFunction<
          Int32 Function(IntPtr, Pointer<NativePoint>),
          int Function(int, Pointer<NativePoint>)
        >('ClientToScreen');
    getStyle = user32
        .lookupFunction<IntPtr Function(IntPtr, Int32), int Function(int, int)>(
          'GetWindowLongPtrW',
        );
    isZoomed = user32.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
      'IsZoomed',
    );
  }
  late final int Function(Pointer<Utf16>, Pointer<Utf16>) findWindow;
  late final int Function(int, Pointer<NativeRect>) getRect;
  late final int Function(int, Pointer<NativeRect>) getClient;
  late final int Function(int, Pointer<NativePoint>) toScreen;
  late final int Function(int, int) getStyle;
  late final int Function(int) isZoomed;

  Map<String, Object?> inspect() {
    final title = 'BobTV window QA'.toNativeUtf16();
    final rect = calloc<NativeRect>();
    final client = calloc<NativeRect>();
    final origin = calloc<NativePoint>();
    try {
      final hwnd = findWindow(nullptr, title);
      if (hwnd == 0 ||
          getRect(hwnd, rect) == 0 ||
          getClient(hwnd, client) == 0 ||
          toScreen(hwnd, origin) == 0) {
        throw StateError('Native QA window unavailable');
      }
      return {
        'left': rect.ref.left,
        'top': rect.ref.top,
        'width': rect.ref.right - rect.ref.left,
        'height': rect.ref.bottom - rect.ref.top,
        'clientWidth': client.ref.right - client.ref.left,
        'clientHeight': client.ref.bottom - client.ref.top,
        'captionInset': origin.ref.y - rect.ref.top,
        'maximizable': getStyle(hwnd, -16) & 0x10000 != 0,
        'zoomed': isZoomed(hwnd) != 0,
      };
    } finally {
      calloc.free(title);
      calloc.free(rect);
      calloc.free(client);
      calloc.free(origin);
    }
  }
}

Future<void> settle() =>
    Future<void>.delayed(const Duration(milliseconds: 500));

void require(bool condition, String label) {
  if (!condition) throw StateError(label);
}

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  final report = arguments
      .singleWhere((argument) => argument.startsWith('--report='))
      .substring(9);
  final records = <Map<String, Object?>>[];
  var passed = false;
  String? error;
  await windowManager.setTitle('BobTV window QA');
  runApp(
    const MaterialApp(
      home: WindowsFullscreenControls(
        child: Scaffold(
          backgroundColor: Color(0xff132035),
          body: Center(
            child: Text(
              'BobTV 窗口回归测试',
              style: TextStyle(color: Colors.white, fontSize: 28),
            ),
          ),
        ),
      ),
    ),
  );
  await WidgetsBinding.instance.endOfFrame;
  await settle();
  final native = NativeWindow();
  try {
    for (final maximized in [false, true]) {
      await windowManager.setFullScreen(false);
      await restoreWindowsWindowChrome();
      await windowManager.unmaximize();
      await settle();
      await windowManager.setBounds(const Rect.fromLTWH(50, 50, 1100, 700));
      if (maximized) await windowManager.maximize();
      await settle();
      for (var cycle = 0; cycle < 3; cycle++) {
        final backend = WindowManagerFullscreenBackend();
        final session = DesktopFullscreenSession(
          backend: backend,
          onChanged: (_) {},
          onExternalExit: () {},
        );
        await session.enter();
        await settle();
        final full = native.inspect();
        require(
          full['captionInset'] == 0 &&
              full['clientHeight'] == full['height'] &&
              full['clientWidth'] == full['width'],
          'Fullscreen retained native borders: $full',
        );
        require(
          await windowManager.isFullScreen(),
          'Fullscreen native flag missing',
        );
        await session.exit();
        await settle();
        final normal = native.inspect();
        require(
          normal['captionInset'] as int > 0,
          'Normal caption not restored: $normal',
        );
        require(
          normal['maximizable'] == true && await windowManager.isResizable(),
          'Normal maximize/resize capability missing: $normal',
        );
        require(
          normal['zoomed'] == maximized,
          'Original maximization changed: $normal',
        );
        await windowManager.unmaximize();
        await settle();
        require(
          native.inspect()['zoomed'] == false,
          'Native restore button equivalent failed',
        );
        await windowManager.maximize();
        await settle();
        require(
          native.inspect()['zoomed'] == true,
          'Native maximize button equivalent failed',
        );
        if (!maximized) {
          await windowManager.unmaximize();
          await settle();
        }
        records.add({
          'path': 'normal-fullscreen-return',
          'maximized': maximized,
          'cycle': cycle,
          'full': full,
          'normal': normal,
        });
        session.dispose();
        await settle();
      }
    }
    final first = DesktopFullscreenSession(
      backend: WindowManagerFullscreenBackend(),
      onChanged: (_) {},
      onExternalExit: () {},
    );
    await first.enter();
    await first.exit(keepWindowFullscreen: true);
    first.dispose();
    await settle();
    require(
      native.inspect()['captionInset'] == 0,
      'Channel return exposed caption',
    );
    final second = DesktopFullscreenSession(
      backend: WindowManagerFullscreenBackend(),
      onChanged: (_) {},
      onExternalExit: () {},
    );
    await second.enter();
    await second.exit();
    await settle();
    require(
      native.inspect()['maximizable'] == true,
      'Fullscreen re-entry saved temporary disabled maximize',
    );
    records.add({
      'path': 'fullscreen-channel-reentry',
      'normal': native.inspect(),
    });
    second.dispose();
    await settle();
    final pip = WindowManagerPipBackend();
    final saved = await pip.capture();
    await pip.compact();
    await settle();
    require(
      (native.inspect()['width'] as int) < 1000,
      'PiP did not become compact',
    );
    await pip.restore(saved);
    await settle();
    require(
      native.inspect()['maximizable'] == true &&
          (native.inspect()['captionInset'] as int) > 0,
      'PiP left window controls disabled',
    );
    records.add({'path': 'pip-restore', 'normal': native.inspect()});
    passed = true;
  } catch (failure, stack) {
    error = '$failure\n$stack';
  } finally {
    await File(report).writeAsString(
      jsonEncode({'passed': passed, 'records': records, 'error': error}),
      flush: true,
    );
    await windowManager.setAlwaysOnTop(false);
    await windowManager.close();
  }
}
