import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../data/services/desktop_update_state.dart';

class DesktopUpdateBadge extends StatelessWidget {
  const DesktopUpdateBadge({
    super.key,
    required this.state,
    required this.onRetry,
    this.showPostExitProgress = false,
  });
  final ValueListenable<WindowsUpdateState> state;
  final VoidCallback onRetry;
  final bool showPostExitProgress;

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<WindowsUpdateState>(
        valueListenable: state,
        builder: (context, update, _) {
          if (!update.visible) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Tooltip(
              message: update.description,
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: () => showDialog<void>(
                  context: context,
                  builder: (_) => _UpdateDetails(
                    state: state,
                    onRetry: onRetry,
                    showPostExitProgress: showPostExitProgress,
                  ),
                ),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color:
                        (update.phase == WindowsUpdatePhase.failed
                                ? const Color(0xFFA34944)
                                : const Color(0xFF7D88DC))
                            .withValues(alpha: .22),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: const Color(0xFF9DA8FF)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (update.busy)
                        const SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Color(0xFFCED5FF),
                          ),
                        )
                      else
                        Icon(
                          update.phase == WindowsUpdatePhase.failed
                              ? Icons.error_outline_rounded
                              : Icons.check_circle_outline_rounded,
                          color: const Color(0xFFCED5FF),
                          size: 17,
                        ),
                      const SizedBox(width: 8),
                      Text(
                        update.label,
                        style: const TextStyle(
                          color: Color(0xFFE2E6FF),
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      );
}

class _UpdateDetails extends StatelessWidget {
  const _UpdateDetails({
    required this.state,
    required this.onRetry,
    required this.showPostExitProgress,
  });
  final ValueListenable<WindowsUpdateState> state;
  final VoidCallback onRetry;
  final bool showPostExitProgress;
  @override
  Widget build(
    BuildContext context,
  ) => ValueListenableBuilder<WindowsUpdateState>(
    valueListenable: state,
    builder: (context, update, _) => AlertDialog(
      backgroundColor: const Color(0xFF172136),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      title: Text(
        'BobTV ${update.version ?? ''}',
        style: const TextStyle(color: Colors.white),
      ),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              update.label,
              style: const TextStyle(color: Color(0xFFCED5FF), fontSize: 18),
            ),
            const SizedBox(height: 18),
            if (update.busy) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  minHeight: 7,
                  value:
                      update.phase == WindowsUpdatePhase.downloading &&
                          update.percent != null
                      ? update.percent! / 100
                      : null,
                ),
              ),
              const SizedBox(height: 12),
            ],
            if (update.totalBytes != null && update.receivedBytes != null)
              Text(
                '${(update.receivedBytes! / 1048576).toStringAsFixed(1)} / '
                '${(update.totalBytes! / 1048576).toStringAsFixed(1)} MB',
                style: const TextStyle(color: Colors.white70),
              ),
            const SizedBox(height: 12),
            Text(
              update.description,
              style: const TextStyle(color: Colors.white70, height: 1.6),
            ),
            const SizedBox(height: 12),
            if (showPostExitProgress)
              const Text(
                '关闭应用后，将显示独立更新窗口。关闭状态窗口不会中止更新。',
                style: TextStyle(
                  color: Colors.white54,
                  fontSize: 12,
                  height: 1.6,
                ),
              ),
          ],
        ),
      ),
      actions: [
        if (update.phase == WindowsUpdatePhase.manualRequired)
          FilledButton(
            onPressed: () =>
                launchUrl(Uri.parse('https://bobtv.briconbric.com/downloads')),
            child: const Text('下载安装包'),
          ),
        if (update.phase == WindowsUpdatePhase.failed)
          FilledButton(onPressed: onRetry, child: const Text('重试更新')),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}
