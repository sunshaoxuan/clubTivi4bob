import 'package:flutter/material.dart';

import '../../core/i18n/app_language.dart';
import 'desktop_exit_button.dart';

/// Keeps navigation reachable while the transient playback controls are hidden.
class PlayerToolbarActions extends StatelessWidget {
  const PlayerToolbarActions({
    super.key,
    required this.onBack,
    required this.showExit,
    this.playbackActions,
  });

  final VoidCallback? onBack;
  final bool showExit;
  final List<Widget>? playbackActions;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final compact =
          bounds.maxWidth < 680 ||
          MediaQuery.textScalerOf(context).scale(1) > 1.2;
      final label = AppMessages.text(context, '返回频道');
      final actions = playbackActions;
      return Align(
        alignment: Alignment.centerLeft,
        heightFactor: 1,
        child: ColoredBox(
          color: Colors.black.withValues(alpha: 0.7),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 4 : 12,
              vertical: 4,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: actions == null
                  ? MainAxisSize.min
                  : MainAxisSize.max,
              children: [
                if (onBack != null)
                  if (compact)
                    IconButton(
                      tooltip: label,
                      onPressed: onBack,
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                    )
                  else
                    TextButton.icon(
                      onPressed: onBack,
                      icon: const Icon(Icons.arrow_back, size: 18),
                      label: Text(label),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white,
                      ),
                    ),
                if (showExit) DesktopExitButton(compact: compact),
                if (actions != null)
                  Expanded(
                    child: Wrap(
                      alignment: WrapAlignment.end,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: actions,
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
