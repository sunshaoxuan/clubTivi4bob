import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/services/desktop_update_state.dart';

/// Live feedback stays in the settings page while the user checks or downloads.
class DesktopUpdateCheckTile extends StatelessWidget {
  const DesktopUpdateCheckTile({
    super.key,
    required this.state,
    required this.onCheck,
  });
  final ValueListenable<WindowsUpdateState> state;
  final Future<void> Function() onCheck;

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<WindowsUpdateState>(
        valueListenable: state,
        builder: (context, update, _) => ListTile(
          leading: update.busy
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.system_update_rounded),
          title: Text(update.visible ? update.label : '检查更新'),
          subtitle: Text(
            update.visible ? update.description : '连接 BobTV 更新服务，检查适用于当前平台的版本',
          ),
          trailing: update.phase == WindowsUpdatePhase.manualRequired
              ? TextButton(
                  onPressed: () => launchUrl(
                    Uri.parse('https://bobtv.briconbric.com/downloads'),
                  ),
                  child: const Text('下载安装包'),
                )
              : null,
          onTap: update.canCheck
              ? () async {
                  await onCheck();
                }
              : null,
        ),
      );
}
