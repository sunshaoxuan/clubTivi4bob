import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clubtivi/features/channels/channel_logo_surface.dart';

Future<Uint8List> mark(Color color) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(const Rect.fromLTWH(2, 2, 4, 4), Paint()..color = color);
  final picture = recorder.endRecording();
  final image = await picture.toImage(8, 8);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}

void main() {
  for (final color in [Colors.white, Colors.black]) {
    testWidgets('transparent $color artwork receives a contrasting plate', (
      tester,
    ) async {
      final bytes = (await tester.runAsync(() => mark(color)))!;
      final provider = MemoryImage(bytes);
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: ChannelLogoSurface(
              image: provider,
              fallback: const Text('台'),
            ),
          ),
        ),
      );
      await tester.runAsync(() async {
        await precacheImage(
          provider,
          tester.element(find.byType(ChannelLogoSurface)),
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      final box = tester.widget<Container>(
        find
            .descendant(
              of: find.byType(ChannelLogoSurface),
              matching: find.byType(Container),
            )
            .first,
      );
      final plate = (box.decoration! as BoxDecoration).color!;
      if (color == Colors.white) {
        expect(plate.computeLuminance(), lessThan(.2));
      } else {
        expect(plate.computeLuminance(), greaterThan(.8));
      }
      expect(tester.takeException(), isNull);
    });
  }
}
