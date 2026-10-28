import 'dart:convert';

/// Startup evidence is meaningful only for the installation that created it.
bool macUpdateCandidateBelongsToApp(String record, String appPath) {
  final lines = const LineSplitter().convert(record);
  return lines.length == 4 && lines[3] == appPath;
}
