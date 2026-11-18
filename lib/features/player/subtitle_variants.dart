import 'package:flutter/foundation.dart';

import 'subtitle_policy.dart';

final _variantId = RegExp(r'^[0-9a-f]{64}$');

String? _validId(Object? value) =>
    value is String && _variantId.hasMatch(value) ? value : null;

@immutable
class SubtitleVariantCandidate {
  const SubtitleVariantCandidate({
    required this.id,
    required this.language,
    required this.provider,
    required this.label,
  });

  final String id, language, provider, label;

  static List<SubtitleVariantCandidate> parse(Object? rows) {
    if (rows is! List) return const [];
    final seen = <String>{};
    final counts = <String, int>{};
    final candidates = <SubtitleVariantCandidate>[];
    for (final row in rows.whereType<Map>()) {
      final candidate = _parse(row);
      if (candidate == null) continue;
      final count = counts[candidate.language] ?? 0;
      if (count >= 3 || !seen.add(candidate.id)) continue;
      counts[candidate.language] = count + 1;
      candidates.add(candidate);
    }
    return List.unmodifiable(candidates);
  }

  static SubtitleVariantCandidate? _parse(Map row) {
    final id = _validId(row['id']);
    final tag = row['language'];
    final language = tag is String ? subtitleLanguage(tag) : null;
    final provider = row['provider'];
    final label = row['label'];
    if (id == null ||
        language == null ||
        provider is! String ||
        provider.trim().isEmpty ||
        label is! String ||
        label.trim().isEmpty) {
      return null;
    }
    return SubtitleVariantCandidate(
      id: id,
      language: language,
      provider: provider.trim(),
      label: label.trim(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SubtitleVariantCandidate &&
      other.id == id &&
      other.language == language &&
      other.provider == provider &&
      other.label == label;

  @override
  int get hashCode => Object.hash(id, language, provider, label);
}

@immutable
class SubtitleVariantOptions {
  const SubtitleVariantOptions({
    this.scope = 0,
    this.candidates = const [],
    this.selectedId,
    this.activeId,
  });

  final int scope;
  final List<SubtitleVariantCandidate> candidates;
  final String? selectedId, activeId;

  List<SubtitleVariantCandidate> forLanguage(String requested) {
    final pinned = candidates
        .where((candidate) => candidate.id == selectedId)
        .firstOrNull;
    final language =
        pinned?.language ??
        selectSubtitle(
          candidates,
          requested,
          language: (candidate) => candidate.language,
        )?.language;
    return candidates
        .where((candidate) => candidate.language == language)
        .toList();
  }

  @override
  bool operator ==(Object other) =>
      other is SubtitleVariantOptions &&
      other.scope == scope &&
      other.selectedId == selectedId &&
      other.activeId == activeId &&
      listEquals(other.candidates, candidates);

  @override
  int get hashCode =>
      Object.hash(scope, selectedId, activeId, Object.hashAll(candidates));
}

typedef SubtitleVariantRequest = ({int revision, Map<String, String> query});

/// Owns the ephemeral choice for a single playback route and programme.
/// A new choice clears the display until the server confirms the active track.
class SubtitleVariantSelection {
  SubtitleVariantSelection(this.options, this._language);

  final ValueNotifier<SubtitleVariantOptions> options;
  String _language;
  String? _programmeKey;
  String? _pin;
  int _revision = 0;
  bool _awaitingRefresh = false;

  bool get hasPin => _pin != null;
  String? get pinnedId => _pin;
  bool get awaitingRefresh => _awaitingRefresh;
  bool get pending =>
      _awaitingRefresh || (_pin != null && options.value.activeId != _pin);

  SubtitleVariantRequest get request =>
      (revision: _revision, query: {'language': _language, 'variant': ?_pin});

  bool setLanguage(String language) {
    if (_language == language) return false;
    _language = language;
    _change(null);
    return true;
  }

  bool select(String? id, int scope) {
    if (scope != options.value.scope || id == _pin) return false;
    if (id != null &&
        !options.value
            .forLanguage(_language)
            .any((candidate) => candidate.id == id)) {
      return false;
    }
    _change(id);
    return true;
  }

  void _change(String? id) {
    _pin = id;
    _revision++;
    _awaitingRefresh = true;
    options.value = SubtitleVariantOptions(
      scope: options.value.scope,
      candidates: options.value.candidates,
      selectedId: id,
    );
  }

  bool isCurrent(SubtitleVariantRequest request) =>
      request.revision == _revision;

  /// Recreating a server session must acquire its own acknowledgement even if
  /// the current programme and chosen version carry over.
  void renewSession() {
    if (_pin != null) _change(_pin);
  }

  ({bool render, bool refresh}) accept(
    Object? programmeKey,
    Map? status, {
    required bool acknowledgesRequest,
  }) {
    final key = programmeKey is String && programmeKey.isNotEmpty
        ? programmeKey
        : null;
    var scope = options.value.scope;
    final programmeChanged = _programmeKey != key;
    if (programmeChanged) {
      _programmeKey = key;
      scope++;
      _revision++;
      _pin = null;
      _awaitingRefresh = false;
    }
    final candidates = key == null
        ? const <SubtitleVariantCandidate>[]
        : SubtitleVariantCandidate.parse(status?['variantCandidates']);
    final acknowledged = _validId(status?['selectedVariantId']);
    final active = _validId(status?['activeVariantId']);
    if (acknowledgesRequest && acknowledged == _pin) {
      _awaitingRefresh = false;
    }
    if (acknowledgesRequest &&
        _pin != null &&
        acknowledged == null &&
        status?['phase'] != 'searching' &&
        !candidates.any((candidate) => candidate.id == _pin)) {
      // The server no longer offers this release. Let automatic selection
      // resume instead of repeatedly requesting a vanished resource.
      _pin = null;
      _revision++;
      _awaitingRefresh = false;
    }
    final canRender =
        !_awaitingRefresh &&
        acknowledged == _pin &&
        (_pin == null || active == _pin);
    options.value = SubtitleVariantOptions(
      scope: scope,
      candidates: candidates,
      selectedId: _pin,
      activeId: canRender ? active : null,
    );
    return (
      render: canRender,
      refresh: programmeChanged && acknowledged != null,
    );
  }
}
