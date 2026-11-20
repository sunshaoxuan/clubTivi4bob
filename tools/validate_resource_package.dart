// dart run tools/validate_resource_package.dart INPUT [OUTPUT.bobtv]
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:clubtivi/data/resource_package/resource_package.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.length > 2) {
    stderr.writeln(
      'Usage: dart run tools/validate_resource_package.dart INPUT [OUTPUT.bobtv]',
    );
    exitCode = 64;
    return;
  }
  try {
    final file = File(args.first);
    if (await file.length() > ResourcePackage.maxBytes) {
      ResourcePackage.invalid('size');
    }
    final input = await file.readAsString();
    final package = ResourcePackage.parse(input);
    final canonical =
        '${const JsonEncoder.withIndent('  ').convert(jsonDecode(input))}\n';
    if (args.length == 2) await File(args[1]).writeAsString(canonical);
    stdout.writeln(
      '${package.categories.length} categories, ${package.channels.length} channels, ${package.routeCount} routes',
    );
    stdout.writeln('SHA-256 ${sha256.convert(utf8.encode(canonical))}');
  } catch (error) {
    stderr.writeln(
      error is FormatException ? error.message : 'Cannot read or write package',
    );
    exitCode = 1;
  }
}
