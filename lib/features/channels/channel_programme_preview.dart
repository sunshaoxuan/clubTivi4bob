import 'package:flutter/foundation.dart';

import '../../data/datasources/local/database.dart' as db;

typedef ChannelProgrammeLoader =
    Future<List<db.EpgProgramme>> Function(
      String epgChannelId,
      DateTime at,
      int limit,
    );

/// Owns the small programme strip for the selected channel, independent of
/// playback and list position. Late database results cannot replace a new choice.
class ChannelProgrammePreview extends ChangeNotifier {
  ChannelProgrammePreview({
    required ChannelProgrammeLoader load,
    DateTime Function()? clock,
    void Function(Object error, StackTrace stackTrace)? onError,
  }) : _load = load,
       _clock = clock ?? DateTime.now,
       _onError = onError;

  static const _cacheDuration = Duration(seconds: 60);
  final ChannelProgrammeLoader _load;
  final DateTime Function() _clock;
  final void Function(Object, StackTrace)? _onError;
  String? _selectedChannelId;
  String? _epgChannelId;
  int _timeshiftHours = 0;
  List<db.EpgProgramme> _programmes = const [];
  bool _loading = false;
  bool _disposed = false;
  int _generation = 0;
  DateTime? _loadedAt;
  Future<void>? _pendingLoad;

  String? get selectedChannelId => _selectedChannelId;
  List<db.EpgProgramme> get programmes => _programmes;
  int get timeshiftHours => _timeshiftHours;
  bool get loading => _loading;

  Future<void> select({
    required String channelId,
    required String? epgChannelId,
    int timeshiftHours = 0,
    bool forceRefresh = false,
  }) {
    if (_disposed) return Future.value();
    final normalizedEpgId = epgChannelId?.trim();
    final usableEpgId = normalizedEpgId == null || normalizedEpgId.isEmpty
        ? null
        : normalizedEpgId;
    final now = _clock();
    final sameChoice =
        channelId == _selectedChannelId &&
        usableEpgId == _epgChannelId &&
        timeshiftHours == _timeshiftHours;
    if (sameChoice && !forceRefresh) {
      if (_loading && _pendingLoad != null) return _pendingLoad!;
      final cacheAge = _loadedAt == null ? null : now.difference(_loadedAt!);
      if (cacheAge != null &&
          !cacheAge.isNegative &&
          cacheAge < _cacheDuration) {
        return Future.value();
      }
    }

    final generation = ++_generation;
    _selectedChannelId = channelId;
    _epgChannelId = usableEpgId;
    _timeshiftHours = timeshiftHours;
    _loadedAt = null;
    _pendingLoad = null;
    if (!sameChoice) _programmes = const [];
    _loading = usableEpgId != null;
    notifyListeners();

    if (usableEpgId == null) {
      _programmes = const [];
      _loadedAt = now;
      return Future.value();
    }

    final request = _loadProgrammes(
      generation,
      usableEpgId,
      now.subtract(Duration(hours: timeshiftHours)),
    );
    _pendingLoad = request;
    return request;
  }

  Future<void> _loadProgrammes(
    int generation,
    String epgChannelId,
    DateTime at,
  ) async {
    try {
      final programmes = await _load(epgChannelId, at, 3);
      if (_disposed || generation != _generation) return;
      _programmes = List.unmodifiable(programmes);
    } catch (error, stackTrace) {
      if (_disposed || generation != _generation) return;
      _programmes = const [];
      try {
        _onError?.call(error, stackTrace);
      } catch (_) {
        // Diagnostics must not interrupt channel selection.
      }
    } finally {
      if (!_disposed && generation == _generation) {
        _loadedAt = _clock();
        _loading = false;
        _pendingLoad = null;
        notifyListeners();
      }
    }
  }

  void clear() {
    if (_disposed) return;
    ++_generation;
    _selectedChannelId = null;
    _epgChannelId = null;
    _timeshiftHours = 0;
    _programmes = const [];
    _loading = false;
    _loadedAt = null;
    _pendingLoad = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    _pendingLoad = null;
    super.dispose();
  }
}
