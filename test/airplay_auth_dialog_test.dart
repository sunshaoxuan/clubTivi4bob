import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clubtivi/features/casting/airplay_pair_dialog.dart';
import 'package:clubtivi/features/casting/cast_service.dart';

class PairingService extends CastService {
  final modes = <String?>[];
  final submitted = <String>[];
  @override
  Future<void> beginPairing(CastDevice device, {String? mode}) async {
    modes.add(mode);
    device.authenticationMode = mode;
  }

  @override
  Future<void> finishPairing(CastDevice device, String secret) async {
    submitted.add(secret);
  }

  @override
  Future<void> cancelPairing() async {}
}

void main() {
  for (final mode in ['password', 'pin']) {
    testWidgets(
      'Mac $mode can be selected even when password advertisement is false',
      (tester) async {
        final service = PairingService();
        addTearDown(service.dispose);
        final device = CastDevice(
          id: 'airplay_mac',
          name: 'Test Mac',
          type: 'airplay',
          nativeMac: true,
          passwordRequired: false,
          requiresPairing: true,
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => pairAirPlay(context, service, device),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(service.modes, isEmpty);
        await tester.tap(find.text(mode == 'password' ? '接收密码' : '屏幕验证码'));
        await tester.pumpAndSettle();
        expect(service.modes, [mode]);
        if (mode == 'password') {
          final field = tester.widget<TextField>(find.byType(TextField));
          expect(field.obscureText, true);
          expect(field.enableSuggestions, false);
          await tester.enterText(find.byType(TextField), 'Test password 9!');
        } else {
          for (final digit in ['0', '1', '2', '3']) {
            await tester.tap(find.widgetWithText(TextButton, digit));
            await tester.pump();
          }
        }
        await tester.pump();
        await tester.tap(find.byType(FilledButton));
        await tester.pumpAndSettle();
        expect(service.submitted, [
          mode == 'password' ? 'Test password 9!' : '0123',
        ]);
      },
    );
  }
}
