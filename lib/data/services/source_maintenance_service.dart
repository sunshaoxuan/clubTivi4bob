import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart';

import '../../core/app_diagnostics.dart';
import '../datasources/local/database.dart' as db;

class StreamCheckDecision {
  final int consecutiveFailures;
  final DateTime? firstFailureAt;
  final DateTime? lastSuccessAt;
  final bool retired;

  const StreamCheckDecision({
    required this.consecutiveFailures,
    required this.firstFailureAt,
    required this.lastSuccessAt,
    required this.retired,
  });
}

class SourceMaintenancePolicy {
  static const failureThreshold = 5;
  static const minimumFailureAge = Duration(hours: 24);

  static StreamCheckDecision evaluate({
    required bool success,
    required int previousFailures,
    required DateTime? previousFirstFailureAt,
    required DateTime? previousLastSuccessAt,
    required DateTime now,
  }) {
    if (success) {
      return StreamCheckDecision(
        consecutiveFailures: 0,
        firstFailureAt: null,
        lastSuccessAt: now,
        retired: false,
      );
    }
    final firstFailureAt = previousFirstFailureAt ?? now;
    final failures = previousFailures + 1;
    return StreamCheckDecision(
      consecutiveFailures: failures,
      firstFailureAt: firstFailureAt,
      lastSuccessAt: previousLastSuccessAt,
      retired:
          failures >= failureThreshold &&
          now.difference(firstFailureAt) >= minimumFailureAge,
    );
  }
}

class SourceMaintenanceService {
  static const checkInterval = Duration(hours: 6);
  static const _maximumChecksPerPass = 240;
  static const _parallelChecks = 8;

  final db.AppDatabase database;
  final Dio _dio;
  final bool _ownsDio;

  SourceMaintenanceService({required this.database, Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 6),
              receiveTimeout: const Duration(seconds: 6),
              followRedirects: true,
              maxRedirects: 4,
              responseType: ResponseType.stream,
              headers: const {'User-Agent': 'HotelTV/0.5'},
            ),
          ),
      _ownsDio = dio == null;

  Future<void> run() async {
    final now = DateTime.now();
    final checkBefore = now.subtract(checkInterval);
    final channels = await database.getAllChannels();
    final checks = await database.getAllStreamChecks();
    final checksByKey = {
      for (final check in checks)
        '${check.providerId}\u0000${check.streamUrl}': check,
    };
    final channelsByKey = <String, List<db.Channel>>{};
    for (final channel in channels) {
      final uri = Uri.tryParse(channel.streamUrl);
      if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
        continue;
      }
      final key = '${channel.providerId}\u0000${channel.streamUrl}';
      (channelsByKey[key] ??= []).add(channel);
    }

    final previouslyRetiredIds = <String>{};
    for (final check in checks.where((item) => item.retired)) {
      final key = '${check.providerId}\u0000${check.streamUrl}';
      previouslyRetiredIds.addAll(
        channelsByKey[key]?.map((channel) => channel.id) ??
            const Iterable.empty(),
      );
    }
    final previouslyDeleted = await database.deleteChannelsByIds(
      previouslyRetiredIds,
    );

    final candidates =
        channelsByKey.entries.where((entry) {
          final saved = checksByKey[entry.key];
          return !(saved?.retired ?? false) &&
              !(saved?.lastCheckedAt?.isAfter(checkBefore) ?? false);
        }).toList()..sort((left, right) {
          final leftFailures = checksByKey[left.key]?.consecutiveFailures ?? 0;
          final rightFailures =
              checksByKey[right.key]?.consecutiveFailures ?? 0;
          if ((leftFailures > 0) != (rightFailures > 0)) {
            return leftFailures > 0 ? -1 : 1;
          }
          final a = checksByKey[left.key]?.lastCheckedAt;
          final b = checksByKey[right.key]?.lastCheckedAt;
          if (a == null && b == null) return 0;
          if (a == null) return -1;
          if (b == null) return 1;
          return a.compareTo(b);
        });

    final selected = candidates.take(_maximumChecksPerPass).toList();
    final results = <String, bool>{};
    for (var offset = 0; offset < selected.length; offset += _parallelChecks) {
      final end = (offset + _parallelChecks).clamp(0, selected.length);
      final batch = selected.sublist(offset, end);
      final batchResults = await Future.wait(
        batch.map((entry) async {
          final success = await _probe(entry.value.first.streamUrl);
          return MapEntry(entry.key, success);
        }),
      );
      results.addEntries(batchResults);
    }

    final successes = results.values.where((value) => value).length;
    if (results.length >= 8 && successes == 0) {
      AppDiagnostics.instance.log('source_maintenance_network_guard', {
        'attempted': results.length,
        'successes': successes,
      });
      return;
    }

    final updates = <db.StreamChecksCompanion>[];
    final retiredChannelIds = <String>{};
    var retiredRoutes = 0;
    for (final entry in selected) {
      final success = results[entry.key];
      if (success == null) continue;
      final channel = entry.value.first;
      final saved = checksByKey[entry.key];
      final decision = SourceMaintenancePolicy.evaluate(
        success: success,
        previousFailures: saved?.consecutiveFailures ?? 0,
        previousFirstFailureAt: saved?.firstFailureAt,
        previousLastSuccessAt: saved?.lastSuccessAt,
        now: now,
      );
      updates.add(
        db.StreamChecksCompanion.insert(
          streamUrl: channel.streamUrl,
          providerId: channel.providerId,
          channelId: channel.id,
          consecutiveFailures: Value(decision.consecutiveFailures),
          firstFailureAt: Value(decision.firstFailureAt),
          lastCheckedAt: Value(now),
          lastSuccessAt: Value(decision.lastSuccessAt),
          retired: Value(decision.retired),
        ),
      );
      if (decision.retired && !(saved?.retired ?? false)) {
        retiredRoutes++;
        retiredChannelIds.addAll(entry.value.map((item) => item.id));
      }
    }

    await database.upsertStreamChecks(updates);
    final deletedChannels = await database.deleteChannelsByIds(
      retiredChannelIds,
    );
    AppDiagnostics.instance.log('source_maintenance_completed', {
      'attempted': results.length,
      'successes': successes,
      'failures': results.length - successes,
      'retiredRoutes': retiredRoutes,
      'deletedChannels': deletedChannels + previouslyDeleted,
      'remainingCandidates': candidates.length - selected.length,
    });
  }

  Future<bool> _probe(String url) async {
    try {
      final response = await _dio.get<ResponseBody>(
        url,
        options: Options(headers: const {'Range': 'bytes=0-32767'}),
      );
      final status = response.statusCode ?? 0;
      if (status < 200 || status >= 400) return false;
      final body = response.data;
      if (body == null) return false;
      final first = await body.stream.first.timeout(const Duration(seconds: 6));
      return first.isNotEmpty;
    } on DioException catch (error) {
      if (error.response?.statusCode == 416) {
        try {
          final response = await _dio.get<ResponseBody>(url);
          final status = response.statusCode ?? 0;
          final body = response.data;
          if (status < 200 || status >= 400 || body == null) return false;
          final first = await body.stream.first.timeout(
            const Duration(seconds: 6),
          );
          return first.isNotEmpty;
        } catch (_) {
          return false;
        }
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  void dispose() {
    if (_ownsDio) _dio.close(force: true);
  }
}
