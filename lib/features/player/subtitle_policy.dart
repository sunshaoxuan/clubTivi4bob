/// Language identity is deliberately independent from channel market or audio.
String? subtitleLanguage(String? value) {
  final tag = value?.trim().toLowerCase().replaceAll('_', '-');
  if (tag == null || tag.isEmpty) return null;
  if (const {'zh', 'zho', 'chi'}.contains(tag)) return null;
  if (tag.startsWith('zh-')) {
    if (tag.contains('hant') || RegExp(r'-(tw|hk|mo)($|-)').hasMatch(tag)) {
      return 'zh-TW';
    }
    if (tag.contains('hans') || RegExp(r'-(cn|sg)($|-)').hasMatch(tag)) {
      return 'zh-CN';
    }
    return null;
  }
  final base = tag.split('-').first;
  return const {
    'en': 'en',
    'eng': 'en',
    'ja': 'ja',
    'jpn': 'ja',
    'fr': 'fr',
    'fra': 'fr',
    'fre': 'fr',
    'es': 'es',
    'spa': 'es',
    'ko': 'ko',
    'kor': 'ko',
  }[base];
}

/// Unknown languages and unavailable/empty resources never become a fallback.
T? selectSubtitle<T>(
  Iterable<T> candidates,
  String requested, {
  required String? Function(T) language,
  bool Function(T)? usable,
}) {
  final available = candidates.where((c) => usable?.call(c) ?? true).toList();
  final preferred = subtitleLanguage(requested);
  final otherChinese = switch (preferred) {
    'zh-CN' => 'zh-TW',
    'zh-TW' => 'zh-CN',
    _ => null,
  };
  for (final wanted in {preferred, otherChinese, 'en'}..remove(null)) {
    for (final candidate in available) {
      if (subtitleLanguage(language(candidate)) == wanted) return candidate;
    }
  }
  return null;
}
