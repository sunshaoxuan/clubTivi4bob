/// Programme facts are discovery hints. They never establish a subtitle offset.
typedef SubtitleProgrammeLookup =
    Future<Map<String, Object?>?> Function(String source);

class SubtitleProgrammeContext {
  static SubtitleProgrammeLookup? lookup;
}
