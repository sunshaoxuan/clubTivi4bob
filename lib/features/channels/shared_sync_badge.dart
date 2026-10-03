import 'package:flutter/material.dart';
import '../../data/services/website_channel_catalog_service.dart';

/// Shared sync state stays beside the channel list, outside the video canvas.
class SharedSyncBadge extends StatelessWidget {
  const SharedSyncBadge({
    super.key,
    required this.catalog,
    required this.upload,
  });
  final ValueNotifier<WebsiteCatalogProgress> catalog;
  final ValueNotifier<WebsiteCatalogProgress> upload;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([catalog, upload]),
    builder: (context, _) {
      final states = [catalog.value, upload.value];
      final error = states.any((s) => s.error);
      final busy = states.any(
        (s) => !s.complete && !s.error && s.phase.startsWith('正在'),
      );
      final label = error
          ? '同步待重试'
          : busy
          ? '同步中'
          : '已同步';
      final detail = states
          .where((s) => s.phase.isNotEmpty)
          .map(
            (s) =>
                '${s.phase}${s.total > 0 ? ' ${s.imported}/${s.total}' : ''}',
          )
          .join('\n');
      return Tooltip(
        message: detail.isEmpty ? '频道与网站自动同步' : detail,
        child: Semantics(
          label: '共享频道$label',
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: const Color(0x142EC4B6),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (busy)
                  const SizedBox(
                    width: 11,
                    height: 11,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  )
                else
                  Icon(
                    error ? Icons.cloud_off_rounded : Icons.cloud_done_rounded,
                    size: 13,
                    color: error ? Colors.amber : const Color(0xFF82CDBF),
                  ),
                const SizedBox(width: 5),
                Text(
                  label,
                  style: const TextStyle(color: Colors.white70, fontSize: 11),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
