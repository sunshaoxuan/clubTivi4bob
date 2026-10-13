import 'package:flutter/material.dart';

import '../../core/tablet_presentation.dart';

class SimpleHomeContent extends StatelessWidget {
  const SimpleHomeContent({
    super.key,
    required this.compact,
    required this.preview,
    required this.channels,
  });
  final bool compact;
  final Widget preview;
  final Widget channels;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final split = TabletPresentation.splitLayout(
        width: constraints.maxWidth,
        height: constraints.maxHeight,
      );
      return Padding(
        padding: compact
            ? const EdgeInsets.fromLTRB(10, 4, 10, 10)
            : const EdgeInsets.fromLTRB(30, 18, 30, 30),
        child: split
            ? Row(
                children: [
                  Expanded(
                    flex: compact ? 1 : 6,
                    child: KeyedSubtree(
                      key: const ValueKey('simple-main-pane'),
                      child: preview,
                    ),
                  ),
                  SizedBox(width: compact ? 10 : 22),
                  Expanded(
                    flex: compact ? 1 : 4,
                    child: KeyedSubtree(
                      key: const ValueKey('simple-channel-pane'),
                      child: channels,
                    ),
                  ),
                ],
              )
            : Column(
                children: [
                  SizedBox(
                    height: compact
                        ? (constraints.maxHeight * .25).clamp(90.0, 220.0)
                        : TabletPresentation.previewHeight(
                            constraints.maxHeight,
                          ),
                    child: preview,
                  ),
                  SizedBox(height: compact ? 8 : 16),
                  Expanded(child: channels),
                ],
              ),
      );
    },
  );
}
