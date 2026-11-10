import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/services/server_epg_runtime.dart';
import '../../app/server_epg_runtime_host.dart';
import '../../data/services/server_epg_sync_service.dart';
import 'settings_design.dart';
import '../../core/i18n/app_language.dart';

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
  Widget build(BuildContext context) =>
      ValueListenableBuilder<ServerEpgSyncStatus>(
        valueListenable: state,
        builder: (context, status, _) => ListTile(
          leading: const Icon(Icons.copyright_rounded),
          title: Text(AppMessages.text(context, "服务器节目表状态与许可")),
          subtitle: Text(
            status.attributions.isEmpty
                ? AppMessages.text(context, "查看自动更新状态与节目数据许可")
                : status.attributions
                      .map((credit) => credit.sourceLabel)
                      .join('、'),
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => showSettingsDialog<void>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text(AppMessages.text(context, "节目表数据来源与许可")),
              content: SizedBox(
                width: 520,
                child: SingleChildScrollView(
                  child: ValueListenableBuilder<ServerEpgSyncStatus>(
                    valueListenable: state,
                    builder: (context, current, _) => Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ServerEpgCacheStatus(state: state, details: true),
                        const SizedBox(height: 16),
                        if (current.attributions.isEmpty)
                          Text(AppMessages.text(context, "当前版本没有需要署名的来源。")),
                        for (final credit in current.attributions) ...[
                          Text(
                            credit.sourceLabel,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          SelectableText(AppMessages.text(context, "来源：{0}", [credit.attributionUrl])),
                          const SizedBox(height: 8),
                          Text(AppMessages.text(context, "节目数据许可：{0}", [credit.dataLicense])),
                          SelectableText(credit.licenseUrl),
                          Text(
                            credit.shareAlikeRequired
                                ? AppMessages.text(context, "改编数据须按相同许可共享。")
                                : AppMessages.text(context, "使用数据及衍生资料须保留来源署名与许可声明。"),
                          ),
                          const SizedBox(height: 8),
                          Text(AppMessages.text(context, "转换说明：{0}", [credit.modificationNotice])),
                          const SizedBox(height: 24),
                        ],
                        Text(AppMessages.text(context, "以上为当前本地节目表的署名信息，离线时仍可查看和复制。")),
                      ],
                    ),
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(AppMessages.text(context, "关闭")),
                ),
              ],
            ),
          ),
        ),
      );
}
