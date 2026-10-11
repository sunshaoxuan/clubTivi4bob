import 'package:flutter/material.dart';

/// The playing channel owns this count, independently of the browser category.
String playingRouteCountLabel(int candidateCount) => candidateCount > 0
    ? '候选 $candidateCount 路'
    : '正在准备线路';

/// Only the selected category belongs in its empty-state canvas. Whole-catalog
/// transfer counts remain in SharedSyncBadge, independent of channel playback.
class ChannelCatalogStatus extends StatelessWidget {
  const ChannelCatalogStatus({
    super.key,
    required this.category,
    required this.loading,
    this.checking = false,
    required this.onRetry,
  });
  final String category;
  final bool loading;
  final bool checking;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (loading || checking) ...[
        const SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(height: 14),
      ],
      Text(
        loading
            ? '正在载入$category频道…'
            : checking
            ? '正在检查$category的候选线路…'
            : category == '我的收藏'
            ? '还没有收藏的频道'
            : '$category暂时没有可显示的频道',
        textAlign: TextAlign.center,
        style: const TextStyle(color: Colors.white70, fontSize: 14),
      ),
      if (!loading && !checking) ...[
        const SizedBox(height: 12),
        TextButton.icon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('重新读取分类'),
        ),
      ],
    ],
  );
}
