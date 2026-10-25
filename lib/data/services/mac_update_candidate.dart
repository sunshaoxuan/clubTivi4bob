import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// The executable supplies its canonical app path, so distinct installations
/// cannot share pending updates, health receipts or rollback decisions.
String macUpdateInstallationDirectory(String supportPath, String appPath) =>
    p.join(
      supportPath,
      'Update',
      'Installations',
      sha256.convert(utf8.encode(appPath)).toString(),
    );

bool macUpdateCandidateBelongsToApp(
  String record,
  String appPath, {
  String? version,
}) {
  final lines = const LineSplitter().convert(record);
  return lines.length == 4 &&
      lines[3] == appPath &&
      (version == null || lines[0] == version);
}
