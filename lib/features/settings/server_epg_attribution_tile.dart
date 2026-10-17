import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/services/server_epg_runtime.dart';
import '../../data/services/server_epg_sync_service.dart';
import 'settings_design.dart';

class ServerEpgCreditsSettings extends ConsumerWidget {
  const ServerEpgCreditsSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => ServerEpgAttributionTile(
    state: ref.watch(serverEpgRuntimeProvider).service.state,
  );
}

/// Credits remain available for the cached guide, including while offline.
/// URLs are selectable text only; this view makes no upstream requests.
class ServerEpgAttributionTile extends StatelessWidget {
  const ServerEpgAttributionTile({super.key, required this.state});
  final ValueListenable<ServerEpgSyncStatus> state;

  @override
  Widget build(
    BuildContext context,
  ) => ValueListenableBuilder<ServerEpgSyncStatus>(
    valueListenable: state,
    builder: (context, status, _) => ListTile(
      leading: const Icon(Icons.copyright_rounded),
      title: const Text('服务器节目表署名与许可'),
      subtitle: Text(
        status.attributions.isEmpty
            ? '尚无需要署名的服务器节目表'
            : status.attributions.map((credit) => credit.sourceLabel).join('、'),
      ),
      trailing: const Icon(Icons.chevron_right),
      enabled: status.attributions.isNotEmpty,
      onTap: status.attributions.isEmpty
          ? null
          : () => showSettingsDialog<void>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('节目表数据来源与许可'),
                content: SizedBox(
                  width: 520,
                  child: SingleChildScrollView(
                    child: ValueListenableBuilder<ServerEpgSyncStatus>(
                      valueListenable: state,
                      builder: (context, current, _) => Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (current.attributions.isEmpty)
                            const Text('当前版本没有需要署名的来源。'),
                          for (final credit in current.attributions) ...[
                            Text(
                              credit.sourceLabel,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            SelectableText('来源：${credit.attributionUrl}'),
                            const SizedBox(height: 8),
                            Text('节目数据许可：${credit.dataLicense}'),
                            SelectableText(credit.licenseUrl),
                            Text(
                              credit.shareAlikeRequired
                                  ? '改编数据须按相同许可共享。'
                                  : '使用数据及衍生资料须保留来源署名与许可声明。',
                            ),
                            const SizedBox(height: 8),
                            Text('转换说明：${credit.modificationNotice}'),
                            const SizedBox(height: 24),
                          ],
                          const Text('以上为当前本地节目表的署名信息，离线时仍可查看和复制。'),
                        ],
                      ),
                    ),
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('关闭'),
                  ),
                ],
              ),
            ),
    ),
  );
}
