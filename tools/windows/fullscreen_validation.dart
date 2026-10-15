// Isolated Windows native-window regression. No catalogue, player or updater.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

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
    movePointer = user32
        .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
          'SetCursorPos',
        );
  }
  late final int Function(Pointer<Utf16>, Pointer<Utf16>) findWindow;
  late final int Function(int, Pointer<NativeRect>) getRect;
  late final int Function(int, Pointer<NativeRect>) getClient;
  late final int Function(int, Pointer<NativePoint>) toScreen;
  late final int Function(int, int) getStyle;
  late final int Function(int) isZoomed;
  late final int Function(int, int) movePointer;

  int get handle {
    final title = 'BobTV window QA'.toNativeUtf16();
    try {
      return findWindow(nullptr, title);
    } finally {
      calloc.free(title);
    }
  }

  Future<void> captureControls(String path) async {
    final hwnd = handle;
    final user32 = DynamicLibrary.open('user32.dll');
    final gdi = DynamicLibrary.open('gdi32.dll');
    final foreground = user32.lookupFunction<IntPtr Function(), int Function()>(
      'GetForegroundWindow',
    );
    require(hwnd != 0 && foreground() == hwnd, 'QA window is not foreground');
    final getDC = user32
        .lookupFunction<IntPtr Function(IntPtr), int Function(int)>(
          'GetWindowDC',
        );
    final releaseDC = user32
        .lookupFunction<Int32 Function(IntPtr, IntPtr), int Function(int, int)>(
          'ReleaseDC',
        );
    final createDC = gdi
        .lookupFunction<IntPtr Function(IntPtr), int Function(int)>(
          'CreateCompatibleDC',
        );
    final deleteDC = gdi
        .lookupFunction<Int32 Function(IntPtr), int Function(int)>('DeleteDC');
    final select = gdi
        .lookupFunction<
          IntPtr Function(IntPtr, IntPtr),
          int Function(int, int)
        >('SelectObject');
    final deleteObject = gdi
        .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
          'DeleteObject',
        );
    final createBitmap = gdi
        .lookupFunction<
          IntPtr Function(
            IntPtr,
            Pointer<Uint8>,
            Uint32,
            Pointer<Pointer<Uint8>>,
            IntPtr,
            Uint32,
          ),
          int Function(
            int,
            Pointer<Uint8>,
            int,
            Pointer<Pointer<Uint8>>,
            int,
            int,
          )
        >('CreateDIBSection');
    final copy = gdi
        .lookupFunction<
          Int32 Function(
            IntPtr,
            Int32,
            Int32,
            Int32,
            Int32,
            IntPtr,
            Int32,
            Int32,
            Uint32,
          ),
          int Function(int, int, int, int, int, int, int, int, int)
        >('BitBlt');
    const width = 640;
    const height = 80;
    const length = width * height * 4;
    final info = calloc<Uint8>(44);
    final pixels = calloc<Pointer<Uint8>>();
    final header = ByteData.sublistView(info.asTypedList(44));
    header.setUint32(0, 40, Endian.little);
    header.setInt32(4, width, Endian.little);
    header.setInt32(8, -height, Endian.little);
    header.setUint16(12, 1, Endian.little);
    header.setUint16(14, 32, Endian.little);
    final source = getDC(hwnd);
    final memory = createDC(source);
    final bitmap = createBitmap(source, info, 0, pixels, 0, 0);
    final previous = select(memory, bitmap);
    try {
      require(
        source != 0 && memory != 0 && bitmap != 0,
        'QA capture unavailable',
      );
      final bounds = inspect();
      require(
        copy(
              memory,
              0,
              0,
              width,
              height,
              source,
              (bounds['width'] as int) - width,
              0,
              0x40CC0020,
            ) !=
            0,
        'QA window capture failed',
      );
      final file = Uint8List(54 + length);
      final data = ByteData.sublistView(file);
      data.setUint16(0, 0x4D42, Endian.little);
      data.setUint32(2, file.length, Endian.little);
      data.setUint32(10, 54, Endian.little);
      file.setRange(14, 54, info.asTypedList(40));
      file.setRange(54, file.length, pixels.value.asTypedList(length));
      await File(path).writeAsBytes(file, flush: true);
    } finally {
      select(memory, previous);
      deleteObject(bitmap);
      deleteDC(memory);
      releaseDC(hwnd, source);
      calloc.free(info);
      calloc.free(pixels);
    }
  }

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
        'captionStyle': getStyle(hwnd, -16) & 0x00C00000 != 0,
        'systemMenuStyle': getStyle(hwnd, -16) & 0x00080000 != 0,
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
  final capture = arguments.contains('--capture');
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
        final original = native.inspect();
        require(
          !await windowManager.isFullScreen(),
          'Window maximize entered video fullscreen',
        );
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
              full['clientWidth'] == full['width'] &&
              full['captionStyle'] == false &&
              full['systemMenuStyle'] == false,
          'Fullscreen retained native borders: $full',
        );
        require(
          await windowManager.isFullScreen(),
          'Fullscreen native flag missing',
        );
        require(
          native.movePointer(
                (full['left'] as int) + (full['width'] as int) - 70,
                (full['top'] as int) + 2,
              ) !=
              0,
          'QA pointer could not reach top edge',
        );
        await settle();
        require(
          native.movePointer(
                (full['left'] as int) + (full['width'] as int) - 70,
                (full['top'] as int) + 24,
              ) !=
              0,
          'QA pointer could not reach restore control',
        );
        await settle();
        final hover = native.inspect();
        require(
          hover['captionInset'] == 0 &&
              hover['captionStyle'] == false &&
              hover['systemMenuStyle'] == false,
          'Native caption returned over fullscreen controls: $hover',
        );
        if (capture && cycle == 0) {
          await native.captureControls(
            '${File(report).parent.path}\\controls-${maximized ? 'maximized' : 'normal'}.bmp',
          );
        }
        await session.exit();
        await settle();
        final normal = native.inspect();
        for (final dimension in ['left', 'top', 'width', 'height']) {
          require(
            ((normal[dimension] as int) - (original[dimension] as int)).abs() <=
                2,
            'Original $dimension changed: $original -> $normal',
          );
        }
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
    final windowOwner = WindowManagerFullscreenBackend();
    final callerSnapshot = await windowOwner.capture();
    await windowOwner.prepareEntry();
    await windowOwner.setFullscreen(true);
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
      await windowManager.isFullScreen(),
      'Video return changed caller window fullscreen',
    );
    require(
      native.inspect()['captionInset'] == 0,
      'Video return exposed native caption',
    );
    second.dispose();
    await settle();
    await windowOwner.setFullscreen(false);
    await windowOwner.restore(callerSnapshot);
    windowOwner.dispose();
    require(
      native.inspect()['maximizable'] == true,
      'Fullscreen re-entry saved temporary disabled maximize',
    );
    records.add({
      'path': 'fullscreen-channel-reentry',
      'normal': native.inspect(),
    });
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
      jsonEncode({
        'passed': passed,
        'records': records,
        'error': error,
        'captureRequested': capture,
      }),
      flush: true,
    );
    await windowManager.setAlwaysOnTop(false);
    await windowManager.close();
  }
}
