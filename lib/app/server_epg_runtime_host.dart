import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/services/server_epg_runtime.dart';
import '../data/services/server_epg_sync_service.dart';

/// Mounted once around the app, independent of screen navigation or playback.
class ServerEpgRuntimeHost extends ConsumerWidget {
  const ServerEpgRuntimeHost({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final runtime = ref.watch(serverEpgRuntimeProvider);
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Stack(
        children: [
          child,
          Positioned(
            right: 12,
            bottom: 12,
            child: IgnorePointer(
              child: ServerEpgCacheStatus(state: runtime.service.state),
            ),
          ),
        ],
      ),
    );
  }
}

class ServerEpgCacheStatus extends StatefulWidget {
  const ServerEpgCacheStatus({super.key, required this.state, this.now});
  final ValueListenable<ServerEpgSyncStatus> state;
  final DateTime Function()? now;
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
  Widget build(BuildContext context) =>
      ValueListenableBuilder<ServerEpgSyncStatus>(
        valueListenable: widget.state,
        builder: (context, state, _) {
          if (state.phase == 'disabled') return const SizedBox.shrink();
          final expired =
              state.version != null &&
              state.expiredAt(widget.now?.call() ?? DateTime.now());
          final usingCache = state.version != null && state.phase == 'failed';
          if (!expired && !usingCache) return const SizedBox.shrink();
          return DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black87,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Text(
                expired ? '节目表缓存已过期' : '节目表暂用缓存',
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
