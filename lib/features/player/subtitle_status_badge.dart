import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../core/i18n/app_language.dart';
import 'subtitle_status.dart';

/// Player-local feedback. It never consumes taps or occupies the caption line.
class SubtitleStatusBadge extends StatelessWidget {
  const SubtitleStatusBadge({super.key, required this.phase});
  final SubtitlePhase phase;

  @override
  Widget build(BuildContext context) {
    final key = phase.message;
    if (key == null) return const SizedBox.shrink();
    final message = AppMessages.text(context, key);
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, bounds) {
          if (bounds.maxWidth < 80 || bounds.maxHeight < 48) {
            return const SizedBox.shrink();
          }
          return Align(
            alignment: Alignment.topRight,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Semantics(
                liveRegion: true,
                label: message,
                child: Container(
                  key: const ValueKey('subtitle-status-badge'),
                  constraints: BoxConstraints(
                    maxWidth: math.min(300, bounds.maxWidth - 16),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xb31b2028),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (phase.busy)
                        const SizedBox(
                          width: 11,
                          height: 11,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.5,
                            color: Colors.white70,
                          ),
                        )
                      else
                        Icon(
                          phase == SubtitlePhase.englishFallback
                              ? Icons.closed_caption_outlined
                              : Icons.info_outline,
                          size: 13,
                          color: Colors.white70,
                        ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          message,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textScaler: TextScaler.noScaling,
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: (bounds.maxWidth / 28).clamp(9, 12),
                            height: 1.25,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
