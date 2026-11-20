// Usage: dart run tools/diagnostics/mobile_driver_host.dart URI ACTION [VALUE]
import 'dart:convert';
import 'dart:io';
import 'package:flutter_driver/flutter_driver.dart';

Future<void> main(List<String> args) async {
  final driver = await FlutterDriver.connect(dartVmServiceUrl: args[0]);
  try {
    switch (args[1]) {
      case 'tooltip':
        await driver.tap(
          find.byTooltip(args[2]),
          timeout: const Duration(seconds: 15),
        );
      case 'wait':
        await driver.waitFor(
          find.byValueKey(args[2]),
          timeout: const Duration(seconds: 30),
        );
      case 'absent':
        await driver.waitForAbsent(
          find.byValueKey(args[2]),
          timeout: const Duration(seconds: 40),
        );
        stdout.writeln('absent: ${args[2]}');
      case 'tap':
        await driver.tap(
          find.byValueKey(args[2]),
          timeout: const Duration(seconds: 15),
        );
      case 'text':
        await driver.tap(
          find.text(args[2]),
          timeout: const Duration(seconds: 15),
        );
      case 'enter':
        await driver.tap(find.byValueKey('mobile-search-field'));
        await driver.enterText(args[2]);
      case 'tree':
        stdout.writeln((await driver.getRenderTree()).tree);
      case 'health':
        stdout.writeln(jsonEncode(await driver.checkHealth()));
      default:
        stdout.writeln(
          await driver.requestData(
            args[1],
            timeout: const Duration(seconds: 30),
          ),
        );
    }
  } finally {
    await driver.close();
  }
}
