import 'dart:ui';
import 'package:clubtivi/core/desktop_window_geometry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('4K ordinary outer frame is capped with toolbar included', () {
    final bounds = boundedDesktopWindowBounds(
      const Rect.fromLTWH(0, 0, 3840, 2160),
      [const Rect.fromLTWH(0, 24, 3840, 2096)],
    );
    expect(bounds.size, const Size(1920, 1280));
    expect(bounds.top, 24);
  });
  test('1080p fits actual work area excluding taskbar and menu bar', () {
    const work = Rect.fromLTWH(0, 28, 1920, 1012);
    final bounds = boundedDesktopWindowBounds(
      const Rect.fromLTWH(50, 50, 2500, 1500),
      [work],
    );
    expect(bounds.width, 1920);
    expect(bounds.height, 1012);
    expect(work.contains(bounds.topLeft), isTrue);
    expect(bounds.bottom, work.bottom);
    expect(bounds.right, work.right);
  });
  for (final scale in [1.0, 1.25, 1.5, 2.0, 3.0]) {
    test('physical cap survives $scale DPI scaling', () {
      final work = Rect.fromLTWH(0, 0, 3840 / scale, 2120 / scale);
      final bounds = boundedDesktopWindowBounds(
        const Rect.fromLTWH(20, 40, 3000, 2000),
        [work],
        pixelRatio: scale,
      );
      expect(bounds.width * scale, lessThanOrEqualTo(1920));
      expect(bounds.height * scale, lessThanOrEqualTo(1280));
      expect(bounds.right, lessThanOrEqualTo(work.right));
      expect(bounds.bottom, lessThanOrEqualTo(work.bottom));
    });
  }
  test('minimum shrinks on very small work areas without forcing overflow', () {
    const work = Rect.fromLTWH(0, 0, 640, 400);
    expect(
      boundedDesktopWindowBounds(const Rect.fromLTWH(30, 40, 1000, 650), [
        work,
      ]),
      work,
    );
  });
  test('negative monitor remains selected', () {
    const left = Rect.fromLTWH(-1600, 0, 1600, 860);
    final bounds = boundedDesktopWindowBounds(
      const Rect.fromLTWH(-1400, 100, 2000, 1400),
      [const Rect.fromLTWH(0, 0, 1920, 1040), left],
    );
    expect(bounds.left, left.left);
    expect(bounds.size, left.size);
  });
  test('unplugged monitor restores onto nearest available screen', () {
    const work = Rect.fromLTWH(0, 24, 1366, 704);
    final bounds = boundedDesktopWindowBounds(
      const Rect.fromLTWH(-3000, -2000, 1200, 800),
      [work],
    );
    expect(bounds.left, 0);
    expect(bounds.top, 24);
    expect(bounds.height, 704);
  });
  test('normal valid geometry remains unchanged', () {
    const bounds = Rect.fromLTWH(100, 80, 1000, 650);
    expect(
      boundedDesktopWindowBounds(bounds, [
        const Rect.fromLTWH(0, 0, 1920, 1040),
      ]),
      bounds,
    );
  });
  test(
    'screen API failure still enforces cap and preserves desktop coordinates',
    () {
      final bounds = boundedDesktopWindowBounds(
        const Rect.fromLTWH(-2000, 80, 4000, 3000),
        [],
      );
      expect(bounds, const Rect.fromLTWH(-2000, 80, 1920, 1280));
    },
  );
  test('nonfinite native geometry falls back to a usable frame', () {
    final bounds = boundedDesktopWindowBounds(
      Rect.fromLTWH(double.nan, 0, 0, 0),
      [const Rect.fromLTWH(0, 0, 1920, 1040)],
    );
    expect(bounds.size, const Size(1000, 650));
  });
}
