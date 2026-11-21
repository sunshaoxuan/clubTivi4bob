import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/i18n/app_language.dart';
import 'subtitle_status.dart';

/// Keeps the two top-right player labels in one layout instead of layering them.
class PlaybackStatusLabels extends StatelessWidget {
  const PlaybackStatusLabels({
    super.key,
    required this.routeLabel,
    required this.routeBusy,
    this.subtitleStatus,
  });

  final String routeLabel;
  final bool routeBusy;
  final ValueListenable<SubtitlePhase>? subtitleStatus;

  @override
  Widget build(BuildContext context) {
    final status = subtitleStatus;
    if (status == null) return _buildLabels(context);
    return ValueListenableBuilder<SubtitlePhase>(
      valueListenable: status,
      builder: (context, phase, _) => _buildLabels(context, phase),
    );
  }

  Widget _buildLabels(BuildContext context, [SubtitlePhase? phase]) {
    final message = phase?.message;
    return LayoutBuilder(
      builder: (context, bounds) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (message != null) ...[
            Flexible(
              child: Semantics(
                liveRegion: true,
                child: _StatusLabel(
                  key: const ValueKey('player-subtitle-status-label'),
                  label: AppMessages.text(context, message),
                  busy: phase!.busy,
                ),
              ),
            ),
            const SizedBox(width: 6),
          ],
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: bounds.maxWidth * (message == null ? 1 : .5),
            ),
            child: _StatusLabel(
              key: const ValueKey('player-route-status-label'),
              label: routeLabel,
              busy: routeBusy,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusLabel extends StatelessWidget {
  const _StatusLabel({super.key, required this.label, required this.busy});

  final String label;
  final bool busy;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: const Color(0xBD000000),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      child: LayoutBuilder(
        builder: (context, bounds) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy && bounds.maxWidth >= 32) ...[
              const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white70,
                ),
              ),
              const SizedBox(width: 7),
            ],
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
