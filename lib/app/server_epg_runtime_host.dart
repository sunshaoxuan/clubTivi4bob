import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/services/server_epg_runtime.dart';
import '../data/services/server_epg_sync_service.dart';
import '../data/models/server_epg_snapshot.dart';
import '../core/i18n/app_language.dart';

/// Mounted once around the app, independent of screen navigation or playback.
class ServerEpgRuntimeHost extends ConsumerWidget {
  const ServerEpgRuntimeHost({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(serverEpgRuntimeProvider);
    // Keep the sync runtime alive without placing guide diagnostics over every
    // screen, including unrelated channels and private programme sources.
    return child;
  }
}

/// A guide view observes the existing app runtime; displaying a private guide
/// must never start another background receiver or show server expiry status.
class ServerEpgChannelStatus extends ConsumerWidget {
  const ServerEpgChannelStatus({
    super.key,
    this.epgChannelId,
    this.fallback = const SizedBox.shrink(),
  });
  final String? epgChannelId;
  final Widget fallback;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!(epgChannelId?.startsWith('${serverEpgSourceId}_') ?? false) ||
        !ref.exists(serverEpgRuntimeProvider))
      return fallback;
    return ServerEpgCacheStatus(
      state: ref.read(serverEpgRuntimeProvider).service.state,
      epgChannelId: epgChannelId,
      fallback: fallback,
    );
  }
}

class ServerEpgCacheStatus extends StatefulWidget {
  const ServerEpgCacheStatus({
    super.key,
    required this.state,
    this.now,
    this.epgChannelId,
    this.details = false,
    this.fallback = const SizedBox.shrink(),
  });
  final ValueListenable<ServerEpgSyncStatus> state;
  final DateTime Function()? now;
  final String? epgChannelId;
  final bool details;
  final Widget fallback;
  @override
  State<ServerEpgCacheStatus> createState() => _ServerEpgCacheStatusState();
}

class _ServerEpgCacheStatusState extends State<ServerEpgCacheStatus> {
  Timer? _clock;
  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  @override
  Widget build(
    BuildContext context,
  ) => ValueListenableBuilder<ServerEpgSyncStatus>(
    valueListenable: widget.state,
    builder: (context, state, _) {
      if (!widget.details &&
          !(widget.epgChannelId?.startsWith('${serverEpgSourceId}_') ??
              false)) {
        return widget.fallback;
      }
      if (state.phase == 'disabled') {
        return widget.details ? Text(AppMessages.text(context, "服务器节目表自动更新已关闭")) : widget.fallback;
      }
      final expired =
          state.version != null &&
          state.expiredAt(widget.now?.call() ?? DateTime.now());
      final usingCache = state.version != null && state.phase == 'failed';
      if (!widget.details && !expired && !usingCache) return widget.fallback;
      String time(DateTime? value) =>
          value == null ? '暂无记录' : value.toLocal().toString().split('.').first;
      final detail = widget.details
          ? '覆盖截至：${time(state.coverageEnd)}\n'
                '最近检查：${time(state.checkedAt)}\n'
                '下次检查：${time(state.nextCheckAt)}'
                '${state.error == null ? '' : '\n状态码：${state.error}'}'
          : '后台会自动检查更新，播放不受影响';
      return DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black87,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Text(
            '${expired || state.version == null
                ? '暂无最新节目表'
                : usingCache
                ? '节目表暂用缓存'
                : '节目表已更新'}\n$detail',
            textDirection: TextDirection.ltr,
            style: const TextStyle(
              color: Colors.amber,
              fontSize: 12,
              decoration: TextDecoration.none,
            ),
          ),
        ),
      );
    },
  );
}
